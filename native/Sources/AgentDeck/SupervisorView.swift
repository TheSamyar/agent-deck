import AppKit
import SwiftUI
import DeckCore

struct SupervisorView: View {
  @EnvironmentObject var deck: DeckModel
  @State private var legacy = false
  @State private var launchError = ""
  var body: some View {
    if legacy {
      VStack {
        Button("Back to separate Alfred app") { if deck.supervisor.deactivateCompatibility() { legacy = false } }
        SupervisorWorkspace(store: deck.supervisor)
      }
    } else {
      VStack(alignment: .leading, spacing: 16) {
        Label("Alfred has its own app", systemImage: "waveform.circle.fill").font(.title.bold())
        Text("Conversation, voice, skills and Operations live in Alfred. Agent Deck keeps your hardware and agent controls.")
        Button("Open Alfred") {
          guard let url = AlfredCompanion.applicationURL else { launchError = "Install Alfred from the Alfred repository first."; return }
          guard deck.supervisor.deactivateCompatibility() else { launchError = deck.supervisor.error; return }
          NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if let error { Task { @MainActor in launchError = error.localizedDescription } }
          }
        }.buttonStyle(.borderedProminent).disabled(AlfredCompanion.applicationURL == nil)
        if AlfredCompanion.applicationURL == nil {
          Text("The separate Alfred app is not installed in Applications yet.").foregroundStyle(.secondary)
        }
        if !launchError.isEmpty { Text(launchError).foregroundStyle(.red) }
        Divider()
        Text("Your previous assistant data is preserved. Request-specific voice approvals still use the legacy client until separate pairing is available.").font(.caption).foregroundStyle(.secondary)
        Button("Open legacy assistant") {
          if deck.supervisor.activateCompatibility() { legacy = true }
          else { launchError = deck.supervisor.error }
        }.buttonStyle(.borderless)
      }.padding(24).frame(maxWidth: 700, alignment: .leading)
    }
  }
}

enum AlfredCompanion {
  static var applicationURL: URL? {
    let candidates = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Alfred.app"), URL(fileURLWithPath: "/Applications/Alfred.app")]
    return candidates.first { Bundle(url: $0)?.bundleIdentifier == "com.thesamyar.alfred.desktop" }
  }
}

private struct SupervisorWorkspace: View {
  @ObservedObject var store: SupervisorStore
  @State private var tab = CommandLine.arguments.contains("--robin-acceptance-candidate") ? 2 : 0
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      RobinHeader(store: store)
      RobinMissionStatus(journal: store.missions)
      RobinConversationQuestionStatus(store:store, exchange:store.conversationExchange)
      if store.configuration.voiceAttentionEnabled == true { RobinAttentionStatus(exchange:store.attention) }
      HStack {
        Label("Alfred", systemImage: "waveform.circle.fill").font(.title2.bold())
        Spacer()
        Picker("Speech capture", selection: $store.configuration.backend) {
          Text("On-device speech").tag(SupervisorConfiguration.Backend.local)
          Text("Cloud (unavailable)").tag(SupervisorConfiguration.Backend.cloud).disabled(true)
        }.frame(width: 150)
      }
      Text(store.serviceStatus).font(.caption).foregroundStyle(.secondary)
      TabView(selection: $tab) {
        SupervisorConversation(store: store).tabItem { Label("Talk", systemImage: "bubble.left.and.bubble.right") }.tag(0)
        SupervisorTasks(store: store).tabItem { Label("Tasks", systemImage: "checklist") }.tag(1)
        SupervisorSetup(store: store).tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(2)
        AlfredSkillsView(store: store).tabItem { Label("Skills", systemImage: "sparkles") }.tag(3)
        AlfredOperationsView().tabItem { Label("Operations", systemImage: "tray.full") }.tag(4)
      }
      if !store.notice.isEmpty { Text(store.notice).font(.caption).textSelection(.enabled) }
      if !store.error.isEmpty {
        HStack(alignment: .top) {
          Text(store.error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
          Spacer(); Button("Dismiss") { store.error = "" }
        }
      }
    }.padding()
      .onChange(of: store.configuration) { _, _ in store.saveConfiguration() }
  }
}

private struct SupervisorConversation: View {
  @ObservedObject var store: SupervisorStore
  @ObservedObject private var realtime: SupervisorRealtime
  @ObservedObject private var voice: SupervisorVoice
  @ObservedObject private var kokoro: SupervisorKokoro
  @ObservedObject private var jarvis: JarvisRuntime
  @ObservedObject private var conversation: RobinConversationExchange
  @State private var search = ""
  init(store: SupervisorStore) { self.store = store; realtime = store.realtime; voice = store.voice; kokoro = store.kokoro;jarvis=store.jarvis; conversation=store.conversationExchange }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(store.configuration.backend == .local ? "Speak when the header says Listening. Alfred takes turns: its microphone is off while thinking or speaking. Use Stop at any time." : SupervisorRealtime.compatibilityBlocker)
        .font(.caption).foregroundStyle(.secondary)
      if kokoro.speaking { Text(kokoro.status).font(.caption).foregroundStyle(.secondary) }
      if store.configuration.jarvisEnabled == true {Text(jarvis.phase.rawValue).font(.caption.bold())}
      if let pending=jarvis.pending {
        GroupBox("Action needs your decision") {
          VStack(alignment:.leading) {
            Text(pending.action?.rawValue ?? "Action").bold()
            if let path=pending.arguments.path {Text(path).textSelection(.enabled)}
            if let text=pending.arguments.text {Text(text).textSelection(.enabled)}
            if pending.action == .deleteFile {Button("Confirm: move this item to Trash",role:.destructive) {Task {await jarvis.confirmPending()}}}
            else {Text("Complete this action manually. Alfred has not executed it.").font(.caption)}
            Button("Dismiss") {jarvis.cancel()}
          }.frame(maxWidth:.infinity,alignment:.leading)
        }
      }
      AlfredActionTimeline(runtime: jarvis, stop: store.stopAllAudio)
      TextField("Search transcripts", text: $search)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(store.memory.messages.filter { search.isEmpty || $0.content.localizedCaseInsensitiveContains(search) }) { message in
              VStack(alignment: .leading, spacing: 4) {
                Text(message.role == "user" ? "You" : "Alfred").font(.caption.bold()).foregroundStyle(.secondary)
                Text(message.content).textSelection(.enabled)
                if message.role == "assistant" {
                  Text(message.reasoningReceipts?.last?.summary ?? "Provider not recorded")
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
              }.frame(maxWidth: .infinity, alignment: .leading).id(message.id)
            }
          }.padding(8)
        }.background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 8))
          .onChange(of: store.memory.messages.count) { _, _ in if let id = store.memory.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
      }
      HStack {
        TextField("Teach it a preference or discuss a task…", text: $store.input).onSubmit { Task { await store.send() } }
        Button(store.busy ? "Thinking…" : "Send") { Task { await store.send() } }.disabled(store.busy || realtime.active || realtime.connecting)
      }
      if let pending = store.memory.pendingLesson {
        GroupBox("Remember this?") {
          VStack(alignment: .leading) {
            Text(pending).textSelection(.enabled)
            HStack {
              Button("Approve & save") { store.approveLesson() }
              Button("Edit") { store.lesson = pending; store.memory.pendingLesson = nil; store.save() }
              Button("Discard") { store.rejectLesson() }
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      DisclosureGroup("Lessons (\(store.memory.lessons.count))") {
        ScrollView {
          VStack(alignment: .leading) {
            ForEach(store.memory.lessons) { lesson in
              HStack {
                Text(lesson.text).font(.caption).textSelection(.enabled)
                Spacer()
                Button("Remove") { store.memory.lessons.removeAll { $0.id == lesson.id }; store.save(); store.realtime.updateInstructions(store.instructions) }
              }
            }
          }
        }.frame(maxHeight: 100)
        HStack {
          TextField("Write a lesson", text: $store.lesson)
          Button("Approve & save") { store.memory.pendingLesson = nil; store.approveLesson() }.disabled(store.lesson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      if !realtime.error.isEmpty { Text(realtime.error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
    }.padding(.top, 10)
  }
}

private struct SupervisorTasks: View {
  @ObservedObject var store: SupervisorStore
  @State private var provider = SupervisedProvider.codex
  @State private var cwd = ""
  @State private var goal = ""
  @State private var criteria = ""
  @State private var starting = false
  @State private var stopTask: SupervisedTask?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        GroupBox("Start a supervised task") {
          VStack(alignment: .leading, spacing: 8) {
            Picker("Agent", selection: $provider) {
              ForEach(SupervisedProvider.allCases, id: \.self) { provider in Text(provider.title + (store.available[provider.rawValue] == false ? " · CLI missing" : "")).tag(provider) }
            }
            HStack {
              TextField("Project folder", text: $cwd)
              Button("Choose…") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                if panel.runModal() == .OK { cwd = panel.url?.path ?? "" }
              }
            }
            TextField("What should it finish?", text: $goal, axis: .vertical).lineLimit(2...4)
            TextField("What must work before it stops?", text: $criteria, axis: .vertical).lineLimit(2...4)
            Button(starting ? "Starting…" : "Start task") {
              starting = true
              Task { await store.startTask(provider: provider, cwd: cwd, goal: goal, criteria: criteria); starting = false }
            }.disabled(starting || cwd.isEmpty || goal.isEmpty || criteria.isEmpty)
            Text("Uses your signed-in agent CLI. Existing editor chats are not taken over. Agent tool permissions still apply.").font(.caption).foregroundStyle(.secondary)
          }.padding(4)
        }
        ForEach(store.tasks.reversed()) { task in
          GroupBox {
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text(task.provider.title).bold(); Text(task.state.rawValue.capitalized).foregroundStyle(task.state == .blocked ? .orange : .secondary)
                Spacer(); Text("Turn \(task.turns)").font(.caption)
              }
              Text(task.goal).textSelection(.enabled)
              Text(task.cwd).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
              Toggle("Autopilot for this project", isOn: Binding(
                get: { store.memory.automaticProjects.contains(task.cwd) },
                set: { store.setAutomatic($0, project: task.cwd) }))
              if task.automaticTurns >= 5 { Text("Five automatic follow-ups used. Review and continue manually.").font(.caption).foregroundStyle(.orange) }
              if !task.result.isEmpty {
                DisclosureGroup("Agent result") { Text(task.result).font(.callout).textSelection(.enabled) }
              }
              if let draft = store.drafts[task.id] {
                Text(draft.reason).font(.callout)
                if draft.action == .followUp {
                  TextEditor(text: Binding(get: { store.drafts[task.id]?.prompt ?? "" }, set: { store.drafts[task.id]?.prompt = $0 }))
                    .font(.callout).frame(height: 100)
                  Button("Send follow-up") { Task { await store.sendDraft(task: task) } }
                } else { Text(draft.action == .done ? "Suggested: mark complete after reviewing evidence." : "Your decision is needed.").font(.caption) }
              }
              HStack {
                if task.state == .review || task.state == .blocked || task.state == .stopped {
                  Button("Review next step") { Task { await store.review(task) } }
                  Button("Write follow-up") { store.manualDraft(task) }.disabled(task.session == nil)
                  Button("Mark complete") { Task { await store.changeTask(task, done: true) } }
                }
                if task.state == .working || task.state == .blocked { Button("Stop", role: .destructive) { stopTask = task } }
              }
              DisclosureGroup("Prompt history") {
                ForEach((store.memory.audit ?? []).filter { $0.task == task.id }.reversed()) { entry in
                  Text(entry.text).font(.caption).textSelection(.enabled)
                }
              }
            }.padding(4)
          }
        }
        if store.tasks.isEmpty { Text("Start one task. Review its first follow-up before enabling autopilot.").foregroundStyle(.secondary) }
      }
    }.padding(.top, 10)
      .confirmationDialog("Stop this agent process?", isPresented: Binding(get: { stopTask != nil }, set: { if !$0 { stopTask = nil } })) {
        Button("Stop agent", role: .destructive) { if let task = stopTask { Task { await store.changeTask(task, done: false) } }; stopTask = nil }
      } message: { Text("Autopilot for this project will pause. External background work may need a separate check.") }
  }
}

private struct SupervisorSetup: View {
  @EnvironmentObject private var deck: DeckModel
  @ObservedObject var store: SupervisorStore
  @ObservedObject private var kokoro: SupervisorKokoro
  init(store: SupervisorStore) { self.store = store; kokoro = store.kokoro }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Toggle("Enable Alfred actions", isOn: Binding(get: { store.configuration.jarvisEnabled == true }, set: { store.configuration.jarvisEnabled = $0 }))
        JarvisSettings(runtime: store.jarvis)
        GroupBox("Local voice") {
          VStack(alignment: .leading, spacing: 8) {
            Picker("Speech", selection: Binding(get: { store.configuration.localSpeechEngine ?? "kokoro" }, set: { store.configuration.localSpeechEngine = $0 })) {
              Text("Kokoro · recommended").tag("kokoro")
              Text("Mac voice · basic").tag("system")
            }
            Picker("Voice", selection: Binding(get: { store.configuration.localSpeechVoice ?? "af_heart" }, set: { store.configuration.localSpeechVoice = $0 })) {
              Text("Heart · warm · recommended").tag("af_heart")
              Text("Bella · bright").tag("af_bella")
              Text("Michael · lower voice").tag("am_michael")
              Text("Emma · British").tag("bf_emma")
            }
            HStack {
              Text("Speed")
              Slider(value: Binding(get: { store.configuration.localSpeechSpeed ?? 1 }, set: { store.configuration.localSpeechSpeed = $0 }), in: 0.8...1.2, step: 0.05)
              Text(String(format: "%.2f×", store.configuration.localSpeechSpeed ?? 1)).monospacedDigit()
            }
            HStack {
              Button(kokoro.installing ? "Installing…" : "Install voice") { store.installLocalVoice() }.disabled(kokoro.installing)
              Button("Preview voice") { store.previewLocalVoice() }.disabled(kokoro.installing)
              if kokoro.speaking { Button("Stop preview") { store.stopVoice() } }
            }
            Text(kokoro.status).font(.caption).textSelection(.enabled)
            Text("A dedicated voice model runs on this Mac. First setup downloads about 355 MB of model files plus an isolated runtime. Speech never leaves your Mac. The basic Mac voice is used only if you choose it.").font(.caption).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox("Local · guided setup") {
          VStack(alignment: .leading, spacing: 8) {
            Text("1. Install or open Ollama. 2. Download a model. 3. Check Local.")
            Text("This Mac has \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB of memory. The default 4B model downloads about 2.5 GB; 8 GB or more RAM is recommended.").font(.caption)
            TextField("Local model", text: $store.configuration.localModel)
            HStack {
              Button("Install / open Ollama") { store.openLocalRuntime() }
              Button("Download model") { store.downloadModel() }.disabled(store.installing)
              Button("Check Local") { Task { await store.checkLocal() } }
              if store.installing { Button("Cancel") { store.cancelDownload() } }
            }
            Text(store.localStatus).font(.caption).textSelection(.enabled)
            Text("Local speech uses macOS on-device recognition. If it is unavailable for your language, the app reports that instead of uploading audio.").font(.caption).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        RobinAcousticTestPanel(stopOtherAudio:{store.beginAcousticTest()},configuration:store.configuration,onFinished:{store.endAcousticTest()})
        RobinSubscriptionConnectionsPanel(store: store)
        RobinAwarenessPanel(awareness:store.awareness)
        GroupBox("Personal memory") {RobinNotebookBrowser(store:store.personalNotebook,suggestedProject:"personal")}
        RobinPersonalConnectionsPanel()
        GroupBox("Alfred brains · all providers") {
          VStack(alignment: .leading, spacing: 10) {
            Toggle("Use reasoning and project tools", isOn: Binding(get: { store.configuration.jarvisEnabled == true }, set: { store.configuration.jarvisEnabled = $0 }))
            Picker("Brain", selection: Binding(get: { store.selectedReasoningModelID }, set: { store.configuration.robinProviderID = $0; store.providerKeyInput = ""; store.providerSetupStatus = "" })) {
              ForEach(RobinModelCatalog.all.filter { !["cursor-subscription", "gemini-subscription"].contains($0.providerID) && (store.configuration.robinSubscriptionOnly != true || $0.providerID == "local" || RobinSubscriptionConnection.contains($0.providerID)) }, id: \.id) { model in Text(model.name + " · " + model.providerID).tag(model.id) }
            }
            if let model = RobinModelCatalog.model(store.selectedReasoningModelID), model.providerID != "local" {
              Toggle("Enable this cloud brain", isOn: Binding(get: { store.configuration.robinHybridEnabled == true }, set: { store.configuration.robinHybridEnabled = $0 }))
              if RobinSubscriptionConnection.contains(model.providerID) {
                Text("Uses the official CLI sign-in shown above. No API key is needed. Plan limits and existing account extra-usage settings apply.").font(.callout)
              } else {
              SecureField("API key for " + model.providerID, text: $store.providerKeyInput)
              HStack {
                Button("Save key in Keychain") { store.saveSelectedProviderKey() }.disabled(store.providerKeyInput.isEmpty)
                Button("Check credential") { store.checkSelectedProviderKey() }
              }
              }
              if model.providerID == "cloudflare" {
                TextField("Cloudflare account ID", text: Binding(get: { store.configuration.robinCloudflareAccountID ?? "" }, set: { store.configuration.robinCloudflareAccountID = $0 }))
                Toggle("My Cloudflare account uses Workers Free", isOn: Binding(get: { store.configuration.robinCloudflareFreePlanConfirmed == true }, set: { store.configuration.robinCloudflareFreePlanConfirmed = $0 }))
              }
              if !RobinSubscriptionConnection.contains(model.providerID) {
              Toggle("I authorize paid API usage on " + model.providerID, isOn: Binding(get: { store.configuration.robinPaidProvidersConfirmed?.contains(model.providerID) == true }, set: { enabled in
                var values = store.configuration.robinPaidProvidersConfirmed ?? []; values.removeAll { $0 == model.providerID }; if enabled { values.append(model.providerID) }; store.configuration.robinPaidProvidersConfirmed = values
              }))
              }
              if model.providerID == "groq" {
                Toggle("My Groq account is on the free plan", isOn: Binding(get: { store.configuration.robinFreePlanConfirmed == true }, set: { store.configuration.robinFreePlanConfirmed = $0 }))
              }
              if let snapshot = deck.snapshot, let session = snapshot.sessions[snapshot.selectedSessionId] {
                Toggle("Allow this project’s context on " + model.providerID + ": " + session.workspace, isOn: Binding(get: { store.configuration.robinProviderCloudProjects?[model.providerID]?.contains(session.projectKey) ?? (model.providerID == "groq" && store.configuration.robinCloudProjects?.contains(session.projectKey) == true) }, set: { enabled in
                  var map = store.configuration.robinProviderCloudProjects ?? [:]; var values = map[model.providerID] ?? (model.providerID == "groq" ? store.configuration.robinCloudProjects ?? [] : []); values.removeAll { $0 == session.projectKey }; if enabled { values.append(session.projectKey) }; map[model.providerID] = values; store.configuration.robinProviderCloudProjects = map
                }))
              }
              Text("Provider billing is controlled by your account. No account upgrade or purchase happens here. Benchmarks have a separate run budget. Unavailable providers fall back locally in conversations; benchmarks never substitute another model.").font(.caption).foregroundStyle(.secondary)
            }
            if !store.providerSetupStatus.isEmpty { Text(store.providerSetupStatus).font(.caption) }
            Button("Retry local reasoning") { SupervisorNetwork.shared.retryLocalReasoning(); store.notice = "Local reasoning will be retried on the next request." }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        RobinComparisonPanel(store: store.modelComparison)
        RobinBenchmarkControls(store: store)
        RobinNotebookBrowser(store: store.notebook, suggestedProject: deck.snapshot.flatMap { $0.sessions[$0.selectedSessionId]?.projectKey } ?? store.missions.current?.project ?? "")
        if store.configuration.robinSubscriptionOnly != true {
        GroupBox("Cloud · API voice") {
          VStack(alignment: .leading, spacing: 8) {
            SecureField("OpenAI API key", text: $store.key)
            Button("Save key in Keychain") { store.saveKey() }.disabled(store.key.isEmpty)
            Text("Cloud voice uses OpenAI Realtime. Task reviews use your configured chat model. API usage is billed separately by your provider.").font(.caption)
            TextField("Voice model", text: $store.configuration.realtimeModel)
            TextField("Chat model", text: $store.configuration.cloudModel)
          }
        }
        }
        GroupBox("Hey Alfred · hands-free") {
          VStack(alignment: .leading, spacing: 8) {
            AlfredWakeSetupView()
            Toggle("Listen for Hey Alfred", isOn: Binding(get: { store.configuration.voiceWakeEnabled == true }, set: { store.setWakeEnabled($0) }))
            Text("Hands-free is optional. While enabled, this Mac keeps its microphone on for on-device wake recognition. Only finalized requests beginning with Hey Alfred reach the assistant. Cloud mode may send the request text to your selected provider; wake audio stays on this Mac.").font(.caption).foregroundStyle(.secondary)
            Text("Try: Hey Alfred, what is happening? · Hey Alfred, open Codex · Hey Alfred, draft a task add dark mode").font(.caption)
            Text("Task dictation creates a draft for review. Say Hey Alfred, send my draft after reviewing it. Permission approvals stay in Alfred's exact-question reply flow.").font(.caption).foregroundStyle(.secondary)
            Button("Resume wake listening") { store.resumeWakeListening() }.disabled(store.configuration.voiceWakeEnabled != true)
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox("Briefing and completion") {
          VStack(alignment: .leading, spacing: 8) {
            Toggle("Read my morning briefing", isOn: Binding(get: { store.configuration.robinBriefingEnabled == true }, set: { store.configuration.robinBriefingEnabled = $0 }))
            Picker("Briefing hour", selection: Binding(get: { store.configuration.robinBriefingHour ?? 9 }, set: { store.configuration.robinBriefingHour = $0 })) {
              ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
            }
            Text("Once per day after this hour while Agent Deck is running and your session is awake. Conversations and agent questions take priority.").font(.caption).foregroundStyle(.secondary)
            Button("Read briefing now") { store.readBriefing() }
            Toggle("Speak fresh mission completions", isOn: Binding(get: { store.configuration.robinCompletionVoiceEnabled != false }, set: { store.configuration.robinCompletionVoiceEnabled = $0 }))
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        Toggle("Ask and listen for permission requests",isOn:Binding(get:{store.configuration.voiceAttentionEnabled == true},set:{store.configuration.voiceAttentionEnabled = $0}))
        Picker("Reply window",selection:Binding(get:{store.configuration.voiceReplyTimeout ?? 20},set:{store.configuration.voiceReplyTimeout = $0})) { ForEach([10,20,30,60],id:\.self) { Text("\($0) seconds").tag($0) } }
        Slider(value:Binding(get:{store.configuration.voiceSilenceSeconds ?? 1},set:{store.configuration.voiceSilenceSeconds = $0}),in:0.6...2,step:0.1) { Text("Pause before reply ends") }
        Picker("Remind me later",selection:Binding(get:{store.configuration.voiceLaterMinutes ?? 5},set:{store.configuration.voiceLaterMinutes = $0})) { ForEach([1,5,15],id:\.self) { Text("\($0) minutes").tag($0) } }
        Text("Attention replies use on-device speech recognition. Alfred asks once, then opens the microphone for your reply.").font(.caption)
        Toggle("Speak agent alerts even outside a conversation", isOn: $store.configuration.speakAlerts)
        Toggle("Speak text-chat replies", isOn: $store.configuration.speakReplies)
        GroupBox("Compare one at a time") {
          VStack(alignment: .leading, spacing: 8) {
            Text("Run a sample, switch Local / Cloud, run the same sample again. Samples never send agent prompts.").font(.caption)
            TextField("Sample", text: $store.comparisonPrompt, axis: .vertical)
            Button(store.busy ? "Running…" : "Run with \(store.configuration.backend.rawValue.capitalized)") { Task { await store.compare() } }.disabled(store.busy)
            ForEach(store.comparisons.reversed()) { sample in
              DisclosureGroup("\(sample.backend.capitalized) · \(sample.model) · \(String(format: "%.1f", sample.seconds))s · \(sample.tokens.map { "\($0) tokens" } ?? "usage unavailable")") {
                Text(sample.prompt).font(.caption).foregroundStyle(.secondary)
                Text(sample.reply).textSelection(.enabled)
              }
            }
            Text("Latency measures text response time. Dollar cost and voice latency are not estimated; compare actual charges in your provider account.").font(.caption).foregroundStyle(.secondary)
          }
        }
        DisclosureGroup("Advanced endpoints") {
          TextField("Local chat endpoint (loopback only)", text: $store.configuration.localEndpoint)
          TextField("Cloud chat endpoint (HTTPS)", text: $store.configuration.cloudEndpoint)
          Text("The cloud key is sent only to the Cloud chat endpoint you configure. Voice always connects to api.openai.com.").font(.caption)
        }
      }
    }.padding(.top, 10)
  }
}

private struct RobinConversationQuestionStatus: View {
  @ObservedObject var store: SupervisorStore
  @ObservedObject var exchange: RobinConversationExchange
  var body: some View {
    if let question=exchange.waitingQuestion {
      GroupBox("Waiting for your answer") {
        VStack(alignment:.leading,spacing:8) {
          Text(question).textSelection(.enabled)
          HStack {
            Label(exchange.phase,systemImage:exchange.listening ? "mic.fill" : "bubble.left.and.bubble.right")
              .font(.caption).foregroundStyle(exchange.listening ? Color.green : Color.secondary)
            Spacer()
            Button("Resume conversation") { store.resumeQuestionConversation() }
              .disabled(exchange.active || store.busy)
          }
          Text("Reply in chat or resume the microphone. Silence leaves this question here without repeating it.")
            .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,alignment:.leading)
      }
    }
  }
}
