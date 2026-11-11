import SwiftUI
import DeckCore

struct RobinHeader: View {
  @EnvironmentObject private var deck: DeckModel
  @ObservedObject var store: SupervisorStore
  @ObservedObject private var voice: SupervisorVoice
  @ObservedObject private var realtime: SupervisorRealtime
  @ObservedObject private var speech: SupervisorKokoro
  @ObservedObject private var attention: RobinAttentionExchange
  @ObservedObject private var runtime: JarvisRuntime
  @ObservedObject private var conversation: RobinConversationExchange
  @ObservedObject private var wake: RobinWakeListener
  @ObservedObject private var audio = SupervisorAudio.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  init(store: SupervisorStore) {
    self.store = store; voice = store.voice; realtime = store.realtime; speech = store.kokoro; runtime = store.jarvis; attention = store.attention; wake = store.wake; conversation = store.conversationExchange
  }
  private var voiceOn: Bool {
    audio.capture || audio.playback || attention.active || conversation.sessionActive || conversation.active || realtime.active || realtime.connecting || store.localConversation || store.speaking || speech.speaking || store.busy
  }
  private var state: String {
    if !store.error.isEmpty { return "Blocked" }
    if audio.capture { return wake.listening ? "Listening for Hey Alfred" : "Listening" }
    if voice.listening || conversation.listening { return "Listening" }
    if store.speaking || speech.speaking || realtime.speaking || audio.playback { return "Speaking" }
    if realtime.connecting { return "Connecting" }
    if store.busy { return "Thinking" }
    if runtime.pending != nil { return "Needs your decision" }
    if conversation.active { return conversation.phase }
    if attention.active { return attention.phase }
    if store.memory.conversationQuestion != nil { return "Waiting for your answer" }
    if realtime.active { return "Live conversation" }
    if conversation.sessionActive || store.localConversation { return "Conversation paused" }
    return "Ready"
  }
  private var microphoneStatus: String {
    if realtime.active { return "Cloud microphone on" }
    return audio.status
  }
  private var motionOff: Bool { reduceMotion || deck.preferences.reduceMotion || deck.masterhubConfiguration.motion == false || scenePhase != .active }
  var body: some View {
    HStack(spacing: 18) {
      TimelineView(.animation(minimumInterval: 1.0 / 15, paused: motionOff)) { context in
        if let image = RobinArtwork.image(state: state, phase: motionOff ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3) {
          Image(nsImage: image).resizable().frame(width: 96,height: 96).accessibilityHidden(true)
        }
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("Alfred").font(.system(size: 32, weight: .bold, design: .rounded)).foregroundStyle(.white)
        if CommandLine.arguments.contains("--robin-acceptance-candidate") {Text("Test build · release checks pending").font(.caption.bold()).foregroundStyle(.orange)}
        Text("Your workspace. Your voice. Your sidekick.").font(.callout).foregroundStyle(.white.opacity(0.65))
        Text(state).font(.system(size: 11,weight:.semibold,design:.monospaced))
          .foregroundStyle(state == "Blocked" ? .red : .yellow)
        Button(voiceOn ? "Stop" : "Listen", systemImage: voiceOn ? "stop.fill" : "mic.fill") {
          if voiceOn { store.stopAllAudio() }
          else { Task { await store.toggleVoice() } }
        }.buttonStyle(.borderedProminent)
          .help(voiceOn ? "Stop Alfred audio and the current request" : "Start a spoken conversation")
        if store.busy || audio.playback || store.speaking || speech.speaking {
          Button("Interrupt and listen", systemImage: "mic.badge.plus") { store.interruptAndListen() }
            .help("Stop the current response and open a fresh listening turn")
        }
        if conversation.listening { Button("Done speaking") { conversation.finishSpeaking() } }
        Text(microphoneStatus).font(.caption).foregroundStyle(audio.capture ? .cyan : .white.opacity(0.65))
        Text(store.reasoningStatus).font(.caption).foregroundStyle(.white.opacity(0.65)).textSelection(.enabled)
        if audio.capture {
          ProgressView(value: Double(audio.inputLevel)).frame(maxWidth: 180)
            .accessibilityLabel("Microphone level \(Int(audio.inputLevel * 100)) percent")
        }
        if conversation.sessionActive {
          if !conversation.transcript.isEmpty {Text(conversation.transcript).font(.callout).lineLimit(2)}
        }
        if store.configuration.voiceWakeEnabled == true && !wake.listening {
          Text(wake.status).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
        }
      }
      Spacer(minLength: 0)
    }.padding(18)
      .background(LinearGradient(colors: [Color(red:0.17,green:0.06,blue:0.09),Color(white:0.06)],startPoint:.leading,endPoint:.trailing),in:RoundedRectangle(cornerRadius:20))
      .overlay { RoundedRectangle(cornerRadius:20).strokeBorder(.yellow.opacity(0.2)) }
      .accessibilityElement(children:.contain)

  }
}

struct RobinIdentityPreview: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion || scenePhase != .active)) { context in
      VStack(alignment: .leading, spacing: 20) {
        Text("Alfred / animated identity").font(.largeTitle.bold())
        LazyVGrid(columns: [GridItem(.flexible()),GridItem(.flexible()),GridItem(.flexible())],spacing:24) {
          ForEach(["Ready","Listening","Thinking","Speaking","Needs your decision","Error","Complete"],id:\.self) { state in
            VStack {
              if let image = RobinArtwork.image(state:state,phase:reduceMotion || scenePhase != .active ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy:3)/3) {
                Image(nsImage:image).resizable().frame(width:160,height:160)
              }
              Text(state).font(.headline)
            }.padding().background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:20))
          }
        }
        Text("Synthetic states · microphone off · no actions").font(.caption)
      }.padding(24)
    }
  }
}

struct RobinAttentionStatus: View {
  @ObservedObject var exchange: RobinAttentionExchange
  var body: some View {
    HStack {
      Image(systemName:exchange.phase == "Listening" ? "mic.fill" : "waveform")
      Text(exchange.phase).font(.callout)
      Spacer()
      if !exchange.active { Button("Retry question") { exchange.retry() } }
    }.padding(12).background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:10))
  }
}
