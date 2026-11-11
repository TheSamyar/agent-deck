import AVFoundation
import Combine
import DeckCore
import SwiftUI

@MainActor final class RobinAttentionExchange: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
  @Published private(set) var phase = "Microphone off"
  private let speaker = AVSpeechSynthesizer()
  private let kokoro = SupervisorKokoro()
  private var speechConfiguration = SupervisorConfiguration()
  private let voice = SupervisorVoice()
  private weak var deck: DeckModel?
  private var subscriptions = Set<AnyCancellable>()
  private var question: PendingRequest?
  private var proof = ""
  private var spokenQuestion = ""
  private var canApprove = false
  private var generation = UUID()
  private var deadline: Task<Void, Never>?
  private var silence: Task<Void, Never>?
  private var maximum: Task<Void, Never>?
  private var heard = false
  private var clarify = false
  private var seen = Set<String>()
  private var deferred: [String: Date] = [:]
  private var timeout = 20
  private var laterMinutes = 5
  private var utterance: AVSpeechUtterance?
  private var silenceSeconds = 1.0
  private var afterSpeech: (() -> Void)?
  init(deck: DeckModel) {
    self.deck = deck
    super.init(); speaker.delegate = self
    kokoro.onFinished = { [weak self] in
      guard let self, self.phase == "Speaking" else { return }
      let next = self.afterSpeech; self.afterSpeech = nil; next?()
    }
    kokoro.onError = { [weak self] message in self?.stop(message: message) }
    voice.onFinalText = { [weak self] text in self?.answer(text) }
    voice.$text.dropFirst().sink { [weak self] text in
      guard let self, self.phase == "Listening", !text.isEmpty else { return }
      self.deadline?.cancel()
      if !self.heard {
        self.heard = true
        let id = self.generation
        self.maximum = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(60)) } catch { return }
          guard let self, self.generation == id else { return }; self.finish()
        }
      }
      self.silence?.cancel(); let id = self.generation
      self.silence = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(self?.silenceSeconds ?? 1)) } catch { return }
        guard let self, self.generation == id else { return }; self.finish()
      }
    }.store(in: &subscriptions)
    voice.$error.dropFirst().sink { [weak self] error in
      if !error.isEmpty { self?.stop(message: error) }
    }.store(in: &subscriptions)
  }
  func retry() { stop(); seen.removeAll() }
  var active: Bool { question != nil || speaker.isSpeaking || kokoro.speaking || voice.listening }
  func stop(message: String = "Microphone off") {
    generation = UUID(); deadline?.cancel(); silence?.cancel(); maximum?.cancel()
    afterSpeech = nil; utterance = nil; speaker.stopSpeaking(at: .immediate); kokoro.stop(); voice.stop(); question = nil; proof = ""; phase = message
  }
  func update(_ snapshot: DeckSnapshot, configuration: SupervisorConfiguration, available: Bool) {
    if let current = question, phase != "Submitting reply", !snapshot.requests.contains(where: { $0.id == current.id && $0.revision == current.revision && $0.state == "pending" && $0.expiresAt > DeckClock.now }) { stop() }
    guard configuration.voiceAttentionEnabled == true, available else { if active { stop() }; return }
    guard !active, let deck else { return }
    speechConfiguration = configuration
    silenceSeconds = min(2,max(0.6,configuration.voiceSilenceSeconds ?? 1))
    timeout = [10,20,30,60].contains(configuration.voiceReplyTimeout ?? 20) ? configuration.voiceReplyTimeout ?? 20 : 20
    laterMinutes = [1,5,15].contains(configuration.voiceLaterMinutes ?? 5) ? configuration.voiceLaterMinutes ?? 5 : 5
    let candidates = snapshot.requests.filter { r in
      let key = r.id + ":" + String(r.revision)
      return RobinVoiceReply.shouldAsk(r, in: snapshot) && !seen.contains(key) && (deferred[key] ?? .distantPast) <= Date()
    }.sorted { $0.createdAt < $1.createdAt }
    guard let r = candidates.first else { return }
    if seen.count > 2000 { seen.removeAll() }
    seen.insert(r.id + ":" + String(r.revision)); question = r; clarify = false; generation = UUID(); let id = generation
    phase = "Preparing question"
    Task { [weak self] in
      do {
        let data = try await deck.supervisorRequest("voice/prepare", body: ["clientID":deck.voiceClientID,"requestID":r.id])
        let token = (try JSONSerialization.jsonObject(with:data) as? [String:String])?["token"]
        guard let self, self.generation == id else { return }
        guard let token else { self.stop(message: "Could not prepare this question. Request remains pending."); return }
        self.proof = token
        let session = snapshot.sessions[r.sessionId]
        let title = String(r.title.prefix(180))
        let context = r.context.trimmingCharacters(in: .whitespacesAndNewlines)
        self.canApprove = RobinVoiceReply.canApprove(context: context)
        let instructions = self.canApprove ? "Say allow once, deny, repeat, or later." : "Review the full details on screen to approve. You can say deny, repeat, or later."
        self.spokenQuestion = "\(session?.agentName ?? "An agent") in \(session?.workspace ?? "your project") asks: \(title). Details: \(String(context.prefix(600))). \(instructions)"
        self.ask(self.spokenQuestion)
      } catch {
        guard let self, self.generation == id else { return }
        self.stop(message:error.localizedDescription)
      }
    }
  }
  private func say(_ text: String, then: @escaping () -> Void) {
    voice.stop(); phase = "Speaking"; afterSpeech = then
    if speechConfiguration.localSpeechEngine != "system", kokoro.installed {
      kokoro.speak(text, voice: speechConfiguration.localSpeechVoice ?? "af_heart", speed: speechConfiguration.localSpeechSpeed ?? 1)
    } else {
      let next = AVSpeechUtterance(string:text); utterance = next; speaker.speak(next)
    }
  }
  private func ask(_ text: String) {
    let id = generation
    say(text) { [weak self] in
      guard let self, self.generation == id else { return }
      self.phase = "Opening microphone"; self.heard = false
      Task { [weak self] in
        guard let self, self.generation == id else { return }
        await self.voice.start()
        guard self.generation == id, self.voice.listening else { return }
        self.phase = "Listening"
        self.deadline = Task { [weak self] in
          do { try await Task.sleep(for:.seconds(self?.timeout ?? 20)) } catch { return }
          guard let self, self.generation == id else { return }; self.stop(message:"No reply. Request remains pending.")
        }
      }
    }
  }
  private func finish() {
    silence?.cancel(); maximum?.cancel(); phase = "Processing reply"; voice.finishUtterance()
    let id = generation
    deadline = Task { [weak self] in
      do { try await Task.sleep(for:.seconds(5)) } catch { return }
      guard let self, self.generation == id else { return }; self.stop(message:"Could not finalize speech. Request remains pending.")
    }
  }
  private func answer(_ text: String) {
    guard let r = question, phase == "Processing reply" || phase == "Listening" else { return }
    deadline?.cancel(); silence?.cancel(); maximum?.cancel(); voice.stop()
    let reply = RobinVoiceReply.parse(text)
    if reply == .stop { stop(); return }
    if reply == .later {
      let key = r.id + ":" + String(r.revision); seen.remove(key); deferred[key] = Date().addingTimeInterval(Double(laterMinutes*60)); say("I will ask again later.") { [weak self] in self?.stop() }; return
    }
    if reply == .repeatQuestion { ask(spokenQuestion); return }
    let choice: String
    switch reply {
    case .allow:
      guard canApprove else { stop(message: "Review the full request on screen to approve."); return }
      choice = "allow"
    case .deny: choice = "deny"
    default:
      if clarify { stop(message:"Reply unclear. Request remains pending.") }
      else { clarify = true; ask("Please say allow once, deny, or later.") }; return
    }
    guard let deck else { stop(); return }; let id = generation; phase = "Submitting reply"
    Task { [weak self] in
      guard let self, self.generation == id else { return }
      do {
        var command = ActionCommand(action:"respond",sessionId:r.sessionId,requestId:r.id,choiceId:choice,revision:r.revision)
        command.voiceConfirmation = self.proof
        let data = try JSONEncoder().encode(command)
        let body = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let result = try JSONDecoder().decode(ActionResult.self,from:await deck.supervisorRequest("voice/respond",body:body))
        guard self.generation == id else { return }
        self.question = nil
        self.say(result.ok ? "Your reply was submitted. \(result.message)" : result.message) { [weak self] in self?.stop() }
      } catch {
        guard self.generation == id else { return }
        self.stop(message:error.localizedDescription)
      }
    }
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor [weak self] in
      guard let self, self.utterance === utterance, !self.speaker.isSpeaking else { return }
      self.utterance = nil
      let next = self.afterSpeech; self.afterSpeech = nil; next?()
    }
  }
}
