import AppKit
import DeckCore
import SwiftUI
import UniformTypeIdentifiers

private enum HUBSelection: Hashable {
  case key(Int), rotary(Int), screen
}

struct MasterHUBWorkspace: View {
  @EnvironmentObject private var model: DeckModel
  @Environment(\.openWindow) private var openWindow
  @State private var hardwareExpanded = false
  @State private var editing = false
  @State private var draft = MasterHUBConfigurationStore.load()
  @State private var previewPage: MasterHUBPage = .mac
  @State private var selection: HUBSelection = .key(0)
  @State private var showingChecks = false
  @State private var localMessage = ""

  init(previewEditing: Bool = false) {
    _editing = State(initialValue: previewEditing)
  }

  private var layout: MasterHUBSurfaceSnapshot? {
    guard editing else { return model.masterhubLayout }
    var preview = MasterHUBSurface(); preview.navigate(previewPage)
    return preview.layout(snapshot: model.connected ? model.snapshot : nil, configuration: draft)
  }
  private var selectedSession: SessionSnapshot? {
    guard let id = model.masterhubLayout?.selectedSessionID else { return nil }
    return model.snapshot?.sessions[id]
  }
  private var agentCount: Int { model.snapshot.map { MasterHUBSurface.orderedSessions($0).count } ?? 0 }
  private var connectedModules: Int {
    model.masterhubModules.values.filter { !$0.hasPrefix("Not detected") && !$0.hasPrefix("Checking") }.count
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if !editing { MissionControlView() }
        if editing {
          header
          pageBar
          hardware
        } else {
          DisclosureGroup("Hardware controls", isExpanded: $hardwareExpanded) {
            VStack(alignment: .leading, spacing: 20) {
              header
              pageBar
              hardware
              if layout?.page == .media { mediaCard }
              footer
            }.padding(.top, 16)
          }.font(.callout.weight(.medium))
        }
      }.padding(24).frame(maxWidth: 1000).frame(maxWidth: .infinity)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .inspector(isPresented: $editing) {
      assignmentInspector.inspectorColumnWidth(min: 280, ideal: 310, max: 360)
    }
    .sheet(isPresented: $showingChecks) {
      MasterHUBControlChecks().environmentObject(model)
    }
    .onChange(of: model.identifiedControl) { _, name in
      guard editing else { return }
      if name.hasPrefix("Key "), let number = Int(name.dropFirst(4)),
        let wire = model.masterhubConfiguration.wireIndex(for: number - 1),
        let logical = draft.logicalIndex(forWire: wire) { selection = .key(logical) }
      else if name.hasPrefix("Roller "), let number = Int(name.dropFirst(7)) { selection = .rotary(number - 1) }
      else if name.hasPrefix("Dial "), let number = Int(name.dropFirst(5)) { selection = .rotary(number + 1) }
      else if name == "Screen dial" { selection = .screen }
    }
    .onChange(of: editing) { _, value in
      model.identifyingMasterHUB = value
      if !value { draft = model.masterhubConfiguration }
    }
    .onDisappear { model.identifyingMasterHUB = false; editing = false; draft = model.masterhubConfiguration }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("MasterHUB").font(.largeTitle.weight(.semibold))
        HStack(spacing: 14) {
          Label("\(connectedModules) of 4 modules", systemImage: "cable.connector")
          Label("Profile: \(model.activeMasterHUBProfileName)", systemImage: "rectangle.stack")
          Label("\(agentCount) \(model.preferences.showIdleSessions == true ? "open sessions" : "active roots")", systemImage: "terminal")
        }.font(.callout).foregroundStyle(.secondary)
      }
      Spacer()
      if editing {
        Button("Cancel") { cancelEditing() }.keyboardShortcut(.cancelAction)
        Button("Apply to \(model.activeMasterHUBProfileName)") {
          model.applyMasterHUBConfiguration(draft); editing = false
        }.buttonStyle(.borderedProminent).disabled(!draft.valid)
      } else {
        Button { showingChecks = true } label: { Label("Check controls", systemImage: "checkmark.shield") }
        Button { beginEditing() } label: { Label("Customize", systemImage: "slider.horizontal.3") }
          .buttonStyle(.borderedProminent)
      }
    }
  }
  private var pageBar: some View {
    HStack(spacing: 16) {
      Picker("Page", selection: Binding(
        get: { editing ? previewPage : (model.masterhubLayout?.page == .handoffs ? .handoffs : model.masterhubLayout?.page == .tools ? .tools : model.masterhubLayout?.page == .media ? .media : model.masterhubLayout?.page == .mac ? .mac : .agents) },
        set: { page in if editing { previewPage = page } else { model.navigateMasterHUB(page) } })) {
        Text("Agents").tag(MasterHUBPage.agents)
        Text("Mac").tag(MasterHUBPage.mac)
        if !editing { Text("Media").tag(MasterHUBPage.media); Text("Tools").tag(MasterHUBPage.tools); Text("Handoffs").tag(MasterHUBPage.handoffs) }
      }.pickerStyle(.segmented).frame(width: 260)
      if editing {
        Label("Safe editing · physical controls only identify themselves", systemImage: "hand.raised")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Text(model.masterhubLayout?.page == .agents ? "Live sessions" : model.masterhubLayout?.page == .mac ? "Your Mac shortcuts" : model.masterhubLayout?.page.title ?? "Connecting")
          .font(.callout.weight(.medium))
        Spacer()
        if let layout, layout.pageCount > 1 {
          Button { model.moveMasterHUBPage(-1) } label: { Image(systemName: "chevron.left") }
            .disabled(layout.pageIndex == 0).help("Previous page")
          Text("\(layout.pageIndex + 1) / \(layout.pageCount)").monospacedDigit().foregroundStyle(.secondary)
          Button { model.moveMasterHUBPage(1) } label: { Image(systemName: "chevron.right") }
            .disabled(layout.pageIndex + 1 >= layout.pageCount).help("Next page")
        }
      }
    }
  }
  private var hardware: some View {
    VStack(spacing: 18) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 20) {
          VStack(spacing: 16) { keypad; rollers }
          VStack(spacing: 16) { screenDial; knobs }
        }
        VStack(spacing: 20) { keypad; rollers; HStack(spacing: 20) { screenDial; knobs } }
      }
    }
    .padding(22)
    .background(Color(red: 0.07, green: 0.08, blue: 0.10), in: RoundedRectangle(cornerRadius: 26))
    .overlay { RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.10)) }
    .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    .frame(maxWidth: 800).frame(maxWidth: .infinity)
  }
  private var keypad: some View {
    let shown = layout
    let columns = shown?.columns ?? 5
    return LazyVGrid(columns: Array(repeating: GridItem(.fixed(68), spacing: 7), count: columns), spacing: 7) {
      ForEach(Array((shown?.tiles ?? []).enumerated()), id: \.offset) { index, item in
        Button {
          if editing { selection = .key(index) }
          else if let shown { model.activateMasterHUBKey(index, displayed: shown) }
        } label: {
          MasterHUBKeyFace(clock: model.displayClock, item: item, selected: editing && selection == .key(index),
            identified: (model.identifyingMasterHUB && identifiedLogicalKey == index) || model.activeMasterHUBControl == "Key \(index + 1)",
            ordinal: editing ? index + 1 : nil)
        }.buttonStyle(.plain).id("\(shown?.revision ?? 0)-\(index)")
          .disabled(!editing && (!item.tile.enabled || item.tile.action == "none"))
          .accessibilityLabel("Key \(index + 1), \(item.tile.label), \(item.tile.sublabel)")
          .accessibilityHint(editing ? "Edit this key" : item.tile.requiresHold ? "Opens confirmation" : "Activate this control")
          .help(item.tile.enabled ? item.tile.label : item.tile.detail.isEmpty ? "This control is unavailable" : item.tile.detail)
          .contextMenu {
            if index < 10 && item.binding != nil && shown?.page == .mac {
              Button("Customize this key") { beginEditing(); previewPage = .mac; selection = .key(index) }
            }
            if item.tile.action == "focus", let session = model.snapshot?.sessions[item.tile.target] {
              let pinned = model.preferences.pinnedSessionIds.contains(session.id)
              Button(pinned ? "Unpin agent" : "Pin agent to front") {
                model.savePreferences { preferences in
                  preferences.pinnedSessionIds.removeAll { $0 == session.id }
                  if !pinned { preferences.pinnedSessionIds.append(session.id) }
                }
              }
            }
          }
      }
    }.frame(width: CGFloat(columns) * 68 + CGFloat(columns - 1) * 7)
  }
  private var identifiedLogicalKey: Int? {
    guard model.identifiedControl.hasPrefix("Key "), let number = Int(model.identifiedControl.dropFirst(4)),
      let wire = model.masterhubConfiguration.wireIndex(for: number - 1) else { return nil }
    return (editing ? draft : model.masterhubConfiguration).logicalIndex(forWire: wire)
  }
  private var dialPreviewSnapshot: DeckSnapshot? {
    var snapshot = model.snapshot
    snapshot?.selectedSessionId = model.masterhubLayout?.selectedSessionID ?? ""
    return snapshot
  }
  private var screenDial: some View {
    Button {
      if editing { selection = .screen }
      else { model.activateMasterHUBScreen() }
    } label: {
      VStack(spacing: 10) {
        ZStack {
          Circle().fill(Color(white: 0.15))
          Circle().strokeBorder(.white.opacity(0.12), lineWidth: 8)
          MasterHUBDialFace(snapshot: dialPreviewSnapshot, media: model.nowPlaying,
            handoffsMode: model.masterhubLayout?.page == .handoffs, mediaMode: model.masterhubLayout?.page == .media, clock: model.displayClock)

        }.frame(width: 158, height: 158)
          .overlay { Circle().strokeBorder(selection == .screen && editing ? Color.accentColor : .clear, lineWidth: 2) }
        Text(model.masterhubLayout?.page == .media ? "Turn for volume · press to play" : "Turn to select · press to focus").font(.caption2).foregroundStyle(.white.opacity(0.6))
      }.foregroundStyle(.white)
    }.buttonStyle(.plain).accessibilityLabel(model.masterhubLayout?.page == .media ? "Now Playing, press to toggle playback" : "Screen dial, \(selectedSession?.workspace ?? "no selected agent")")
  }
  private var rollers: some View {
    HStack(spacing: 12) {
      ForEach(0..<2, id: \.self) { index in
        Button { beginEditingIfNeeded(); selection = .rotary(index) } label: {
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
              ForEach(0..<18, id: \.self) { _ in Capsule().fill(.white.opacity(0.15)).frame(width: 2, height: 18) }
            }.frame(maxWidth: .infinity).padding(.vertical, 3)
              .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
            HStack {
              Text("Roller \(index + 1)").font(.system(size: 9, weight: .medium))
              Spacer(minLength: 0)
              Text((editing ? draft : model.masterhubConfiguration).rotaries.bindings[index].turn.rawValue)
                .font(.system(size: 8)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
          }.padding(9).frame(width: 152)
            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(rotaryHighlight(index) ? Color.accentColor : .white.opacity(0.08), lineWidth: 1.5) }
        }.buttonStyle(.plain).foregroundStyle(.white)
      }
    }.frame(width: 368)
  }
  private var knobs: some View {
    VStack(spacing: 3) {
      knob(4)
      HStack(spacing: 9) { knob(2); knob(3) }
    }.frame(width: 158, height: 156)
  }
  private func knob(_ index: Int) -> some View {
    Button { beginEditingIfNeeded(); selection = .rotary(index) } label: {
      VStack(spacing: 3) {
        ZStack {
          Circle().fill(Color(white: 0.16)).frame(width: 43, height: 43)
          Circle().strokeBorder(rotaryHighlight(index) ? Color.accentColor : .white.opacity(0.12), lineWidth: 2).frame(width: 43, height: 43)
          Capsule().fill(.white.opacity(0.8)).frame(width: 2, height: 10).offset(y: -12)
        }
        Text("Dial \(index - 1)").font(.system(size: 9, weight: .medium))
        Text((editing ? draft : model.masterhubConfiguration).rotaries.bindings[index].turn.rawValue)
          .font(.system(size: 8)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
      }.frame(width: 70, height: 72)
    }.buttonStyle(.plain).foregroundStyle(.white)
  }
  private func rotaryHighlight(_ index: Int) -> Bool {
    (editing && selection == .rotary(index)) || (model.identifyingMasterHUB && model.identifiedControl == controlName(index)) || model.activeMasterHUBControl == controlName(index)
  }
  private func controlName(_ index: Int) -> String { index < 2 ? "Roller \(index + 1)" : "Dial \(index - 1)" }
  private var mediaCard: some View {
    HStack(spacing: 14) {
      Image(systemName: model.nowPlaying.playing ? "waveform" : "music.note").font(.title).foregroundStyle(.pink)
      VStack(alignment: .leading, spacing: 4) {
        Text(model.nowPlaying.title).font(.headline).lineLimit(1)
        Text(model.nowPlaying.message.isEmpty ? model.nowPlaying.artist : model.nowPlaying.message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer()
      Button(model.nowPlaying.playing ? "Pause" : "Play") { model.activateMasterHUBScreen() }
    }.padding(16).background(.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
  }
  private var selectedAgent: some View {
    Group {
      if let selectedSession {
        HStack(spacing: 14) {
          Image(systemName: "terminal").font(.title2).foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 4) {
            Text(selectedSession.workspace).font(.headline)
            Text("\(selectedSession.agentName) · \(selectedSession.status.label)").font(.callout).foregroundStyle(.secondary)
            if selectedSession.work?.hasOutstanding == true || selectedSession.work?.awaitingResults == true { Text(selectedSession.detail).font(.caption).foregroundStyle(.secondary) }
          }
          Spacer()
          Button("Open session") { model.perform(.init(action: "focus", sessionId: selectedSession.id)) }
            .disabled(!selectedSession.capabilities.focus || !model.connected)
          Button("Agent actions") { model.navigateMasterHUB(.actions) }.disabled(!model.connected)
        }.padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        if model.masterhubLayout?.page == .actions {
          if let request = model.requests.first(where: { $0.id == model.masterhubLayout?.selectedRequestID && $0.state == "pending" }) {
            VStack(alignment: .leading, spacing: 8) {
              Label(request.title, systemImage: "hand.raised").font(.headline)
              Text(request.context).font(.callout).textSelection(.enabled)
              Text("Confirm in the app, or hold the matching hardware key for 0.7 seconds.").font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
          } else {
            Text("No pending request in this view. Open Attention to review other requests.").font(.caption).foregroundStyle(.secondary)
          }
        }
      } else {
        ContentUnavailableView("No active work", systemImage: "checkmark.circle",
          description: Text("Working root agents and requests appear here. Idle, finished, and unverified records stay in Sessions."))
      }
    }
  }
  private var footer: some View {
    VStack(alignment: .leading, spacing: 14) {
      if !localMessage.isEmpty { Text(localMessage).font(.callout).foregroundStyle(.secondary) }
      if !model.masterhubFeedback.isEmpty { Text(model.masterhubFeedback).font(.callout).textSelection(.enabled) }
      HStack {
        Label(model.connected ? "Agent service connected" : "Mac controls available · agents reconnecting",
          systemImage: model.connected ? "checkmark.circle" : "arrow.triangle.2.circlepath")
        Spacer()
        Button("Mac permissions") { openWindow(id: "permissions") }
        Menu {
          Button("Import settings…") { importConfiguration() }
          Button("Export settings…") { exportConfiguration() }
          if model.canUndoMasterHUBConfiguration { Button("Undo last Apply") { model.undoMasterHUBConfiguration() } }
          Divider()
          Button("Preview Coding Desk preset") { beginEditing(); draft = .init(); previewPage = .mac }
        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
      }.font(.caption).foregroundStyle(.secondary)
    }
  }
  @ViewBuilder private var assignmentInspector: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Customize").font(.headline)
        Spacer()
        Button { cancelEditing() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Cancel changes")
      }.padding()
      Divider()
      Form {
        Section("Display") {
          Toggle("Motion", isOn: Binding(get: { draft.motion != false }, set: { draft.motion = $0 }))
          Text("Follows macOS Reduce Motion. Animation pauses during safe identification.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Keypad orientation") {
          Picker("Rotation", selection: $draft.keypadRotation) {
            Text("Landscape").tag(0); Text("90° clockwise").tag(1)
            Text("Upside down").tag(2); Text("90° counterclockwise").tag(3)
          }
        }
        switch selection {
        case .key(let index):
          if previewPage == .mac && index < 10 {
            MasterHUBKeyAssignment(binding: $draft.macKeys[index], title: "Mac key \(index + 1)")
          } else {
            Section("\(index < 10 ? "Live agent slot" : "Navigation key")") {
              Text(index < 10 ? "Agents fill these slots automatically. Pin an agent from its key’s context menu to keep it at the front." : "These five keys keep navigation and agent actions available on every page.")
                .font(.callout).foregroundStyle(.secondary)
              Button("Edit Mac shortcuts") { previewPage = .mac; selection = .key(min(index, 9)) }
            }
          }
        case .rotary(let index):
          Section(controlName(index)) {
            Picker("Turn", selection: $draft.rotaries.bindings[index].turn) {
              ForEach(MasterHUBRotaryControls.Turn.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if index >= 2 {
              Picker("Press", selection: $draft.rotaries.bindings[index].press) {
                ForEach(MasterHUBRotaryControls.Press.allCases, id: \.self) { Text($0.rawValue).tag($0) }
              }
            }
            Toggle("Reverse direction", isOn: $draft.rotaries.bindings[index].reversed)
          }
        case .screen:
          Section("Screen dial") {
            Label("Turn to choose an agent", systemImage: "arrow.triangle.2.circlepath")
            Label("Press to open its session", systemImage: "arrow.up.forward.app")
            Text("The display and action always refer to the same agent. It never approves or interrupts work.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }.formStyle(.grouped)
      Divider()
      VStack(alignment: .leading, spacing: 8) {
        Label(model.identifiedControl, systemImage: "hand.point.up.left").font(.caption)
        Text("Turn or press a physical control to select it here. Actions stay paused until Apply or Cancel.")
          .font(.caption).foregroundStyle(.secondary)
      }.padding()
    }
  }
  private func beginEditing() {
    draft = model.masterhubConfiguration; previewPage = .mac; editing = true
  }
  private func beginEditingIfNeeded() { if !editing { beginEditing() } }
  private func cancelEditing() { editing = false; draft = model.masterhubConfiguration; model.identifyingMasterHUB = false }
  private func exportConfiguration() {
    let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "MasterHUB Setup.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(model.masterhubConfiguration).write(to: url, options: .atomic)
      localMessage = "Your complete MasterHUB setup was exported."
    } catch { localMessage = error.localizedDescription }
  }
  private func importConfiguration() {
    let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 65536 {
        localMessage = "Choose a settings file smaller than 64 KB."; return
      }
      let imported = try MasterHUBConfigurationStore.decodeImport(Data(contentsOf: url))
      beginEditing(); draft = imported; localMessage = "Review the imported setup, then choose Apply."
    } catch { localMessage = error.localizedDescription }
  }
}

struct MasterHUBKeyFace: View {
  let clock: MasterHUBDisplayClock
  let item: MasterHUBSurfaceTile
  let selected: Bool
  let identified: Bool
  let ordinal: Int?
  var body: some View {
    Group {
      if ["WORKING","WAITING","CLEAR"].contains(item.tile.status) || (item.agentId != nil && ["IDLE","DONE"].contains(item.tile.status)) {
        MasterHUBAnimatedKeyFace(clock: clock.keys, item: item)
      } else { MasterHUBKeyBitmap(item: item, phase: 0) }
    }.frame(width: 68, height: 68).clipShape(RoundedRectangle(cornerRadius: 7))
      .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(selected || identified ? Color.accentColor : .white.opacity(0.12), lineWidth: selected || identified ? 2 : 1) }
      .overlay(alignment: .topLeading) { if let ordinal { Text("\(ordinal)").font(.system(size: 8)).padding(3).background(.black.opacity(0.7)) } }
  }
}
private struct MasterHUBAnimatedKeyFace: View {
  @ObservedObject var clock: MasterHUBKeyClock
  let item: MasterHUBSurfaceTile
  var body: some View { MasterHUBKeyBitmap(item: item, phase: clock.phase) }
}
private struct MasterHUBKeyBitmap: View {
  let item: MasterHUBSurfaceTile
  let phase: Double
  var body: some View {
    if let data = MasterHUBArtwork.jpeg(title: item.tile.label, subtitle: item.tile.sublabel,
      state: item.tile.status, size: 72, symbol: item.symbol, enabled: item.tile.enabled,
      appIcon: MasterHUBAppIcon.image(for: item.binding), phase: phase, work: item.work, characterProject: item.characterKey, agentId: item.agentId ?? ""), let image = MasterHUBPreviewImage.image(data) {
      Image(nsImage: image).resizable().scaledToFit()
    }
  }
}

private struct MasterHUBKeyAssignment: View {
  @Binding var binding: MasterHUBKeyBinding
  let title: String
  var body: some View {
    Section(title) {
      TextField("Name", text: $binding.label)
      Picker("Action", selection: $binding.kind) {
        ForEach(MasterHUBKeyBinding.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      if binding.kind == .application {
        Button("Choose application…") {
          let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]
          guard panel.runModal() == .OK, let url = panel.url else { return }
          binding.applicationPath = url.path; binding.bundleID = Bundle(url: url)?.bundleIdentifier ?? ""
          binding.label = url.deletingPathExtension().lastPathComponent
        }
        Text(binding.applicationPath.isEmpty ? "Choose an app to assign this key." : URL(fileURLWithPath: binding.applicationPath).deletingPathExtension().lastPathComponent)
          .font(.caption).foregroundStyle(.secondary)
      }
      if binding.kind == .shortcut { MasterHUBShortcutRecorder(binding: $binding) }
      if binding.kind == .lockScreen { Text("This key locks your Mac when pressed.").font(.caption).foregroundStyle(.secondary) }
    }
  }
}

private struct MasterHUBShortcutRecorder: View {
  @Binding var binding: MasterHUBKeyBinding
  @State private var monitor: Any?
  @State private var recording = false
  var body: some View {
    Button(recording ? "Press a shortcut · Esc to cancel" : "Record shortcut…") { start() }
      .onDisappear { stop() }
      .onChange(of: binding.id) { _, _ in stop() }
  }
  private func start() {
    stop(); recording = true
    let selectedID = binding.id
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      MainActor.assumeIsolated {
        defer { stop() }
        guard binding.id == selectedID, event.keyCode != 53 else { return }
        binding.keyCode = Int(event.keyCode)
        binding.modifiers = UInt64(event.modifierFlags.rawValue & 0x1e0000)
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let key = event.charactersIgnoringModifiers?.uppercased() ?? "Key"
        binding.label = symbols.filter { event.modifierFlags.contains($0.0) }.map(\.1).joined() + (key == " " ? "Space" : key)
      }
      return nil
    }
  }
  private func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil; recording = false
  }
}

struct MasterHUBControlChecks: View {
  @EnvironmentObject private var model: DeckModel
  @Environment(\.dismiss) private var dismiss
  @State private var liveTesting = false
  @State private var selectedModule = 0
  private var groups: [(String, [String])] { MasterHUBCheckEvidence.groups }
  private var group: (String, [String]) { groups[selectedModule] }
  private var completed: Set<String> { liveTesting ? model.confirmedMasterHUBControls : model.observedMasterHUBControls }
  private var nextControl: String? { group.1.first { !completed.contains($0) } }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("Check your controls").font(.title2.bold())
        Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
      Text("This check: \(MasterHUBCheckEvidence.controls.filter { model.observedMasterHUBControls.contains($0) }.count)/31 inputs · \(model.confirmedMasterHUBControls.count)/31 action outcomes confirmed")
        .font(.caption.bold())
      Picker("Mode", selection: $liveTesting) {
        Text("Identify safely").tag(false)
        Text("Test assigned actions").tag(true)
      }.pickerStyle(.segmented)
      Text(liveTesting ? "Controls run their assigned actions. Locking, approvals, and interruption stay disabled during checks. Confirm only actions you actually observe working."
        : "Press keys and turn dials or rollers. Nothing executes in this mode.").font(.callout).foregroundStyle(.secondary)
      Picker("Module", selection: $selectedModule) {
        ForEach(0..<groups.count, id: \.self) { Text(groups[$0].0).tag($0) }
      }.pickerStyle(.segmented)
      HStack(spacing: 14) {
        Image(systemName: nextControl == nil ? "checkmark.circle.fill" : "hand.point.up.left")
          .font(.title).foregroundStyle(nextControl == nil ? .green : .secondary)
        VStack(alignment: .leading, spacing: 4) {
          Text(nextControl.map { name in
            let parts = name.components(separatedBy: " · ")
            return parts.count == 2 ? "\(parts[1]): \(parts[0])" : "Press \(name)"
          } ?? (liveTesting ? "This module’s action outcomes confirmed" : "All inputs in this module detected")).font(.headline)
          Text(liveTesting ? "Run this control again, observe its assigned outcome, then tick Action worked. Disabled actions remain unverified."
            : "\(group.1.filter { model.observedMasterHUBControls.contains($0) }.count) of \(group.1.count) inputs received")
            .font(.caption).foregroundStyle(.secondary)
        }
      }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
      ScrollView {
        VStack(spacing: 12) {
          ForEach(group.1, id: \.self) { name in
            HStack {
              Image(systemName: model.observedMasterHUBControls.contains(name) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(model.observedMasterHUBControls.contains(name) ? .green : .secondary)
              Text(name)
              Spacer()
              if liveTesting {
                Toggle("Action worked", isOn: Binding(
                  get: { model.confirmedMasterHUBControls.contains(name) },
                  set: { model.confirmMasterHUBControl(name, confirmed: $0) }))
                  .toggleStyle(.checkbox).disabled(!model.actionObservedMasterHUBControls.contains(name))
              } else {
                Text(model.observedMasterHUBControls.contains(name) ? "Input detected" : "Waiting")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }.padding(.vertical, 2)
          }
        }
      }
      if !model.masterhubFeedback.isEmpty { Text(model.masterhubFeedback).font(.caption).foregroundStyle(.secondary) }
      Divider()
      HStack {
        Button("Export this check…") { model.exportMasterHUBCheck() }
        Spacer()
        if selectedModule < groups.count - 1 {
          Button("Next module →") { selectedModule += 1 }
        } else if !liveTesting {
          Button("Test assigned actions →") { liveTesting = true; selectedModule = 0 }
        }
      }
      Text("Export includes app version/build, current hardware IDs, observed inputs, and your action confirmations. Connection alone never passes a control.")
        .font(.caption).foregroundStyle(.secondary)
      ForEach(["15-key keypad", "2 rollers", "3 dials", "Screen dial"], id: \.self) { name in
        LabeledContent(name, value: model.masterhubModules[name] ?? "Checking…").font(.caption)
      }
      if selectedModule == 1 && !group.1.contains(where: { model.observedMasterHUBControls.contains($0) }) {
        Text("No roller input has arrived. Saved assignments remain available, but this module is not verified.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }.padding(24).frame(width: 560, height: 760)
      .background(Color(nsColor: .windowBackgroundColor))
      .onAppear { model.beginMasterHUBCheck() }
      .onChange(of: liveTesting) { _, value in model.identifyingMasterHUB = !value }
      .onDisappear { model.checkingMasterHUBControls = false; model.identifyingMasterHUB = false }
  }
}
