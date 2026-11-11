import AVFoundation
import Combine
import DeckCore
import SwiftUI

/// Owns one ordinary question's playback/capture. Does not mint approval proofs.
@MainActor final class RobinConversationExchange: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
  @Published private(set) var phase = "Microphone off"
  @Published private(set) var waitingQuestion: String?
  @Published private(set) var listening = false
  @Published private(set) var sessionActive = false
  @Published private(set) var transcript = ""
  @Published private(set) var inputLevel:Float = 0
  @Published private(set) var bargeInCount=0
  @Published private(set) var detectedSpeechToStopRequestMilliseconds:Double?
  var onInterrupt: (() -> Void)?
  private var echoControlledSpeech = false
  private var ownsSystemPlayback=false
  private var speechID=UUID()
  private var pendingSystemBuffers=0
  private var systemRenderEnded=false
  private let speaker = AVSpeechSynthesizer()
  private let kokoro = SupervisorKokoro()
  private let voice = SupervisorVoice()
  private var configuration = SupervisorConfiguration()
  private var generation = UUID()
  private var utterance: AVSpeechUtterance?
  private var timer: Task<Void, Never>?
  private var silence: Task<Void, Never>?
  private var maximum: Task<Void, Never>?
  private var turnPolicy = AlfredTurnPolicy()
  private var heard = false
  private var subscriptions = Set<AnyCancellable>()
  private var answer: ((String) -> Void)?
  private var later: (() -> Void)?
  var active: Bool { listening || phase == "Speaking" || phase == "Opening microphone" || phase == "Processing reply" }
  override init() {
    super.init(); speaker.delegate = self
    kokoro.onFinished = { [weak self] in self?.playbackFinished() }
    kokoro.onError = { [weak self] _ in self?.pause(message:"Waiting for your answer · use text or Resume conversation") }
    voice.onSpeechActivity = { [weak self] active in
      self?.turnPolicy.speech(active: active, at: ProcessInfo.processInfo.systemUptime)
    }
    voice.onSpeechDetected = { [weak self] in
      guard let self else {return}
      if self.sessionActive && self.phase == "Working" {self.phase="Listening";self.onInterrupt?();return}
      guard RobinVoiceSession.shouldInterrupt(speaking:self.phase == "Speaking",echoControlled:self.echoControlledSpeech,sustainedSpeech:true) else { return }
      self.speechID=UUID(); self.utterance=nil; self.kokoro.stop(); self.speaker.stopSpeaking(at:.immediate); self.endSystemPlayback()
      self.detectedSpeechToStopRequestMilliseconds=max(0,(ProcessInfo.processInfo.systemUptime-self.voice.lastSpeechDetectedUptime)*1000)
      self.bargeInCount+=1
      self.phase="Listening"; self.onInterrupt?()
    }
    voice.onFinalText = { [weak self] text in self?.receiveFinal(text) }
    voice.$inputLevel.removeDuplicates().sink { [weak self] in self?.inputLevel=$0 }.store(in:&subscriptions)
    voice.$error.dropFirst().sink { [weak self] error in
      if !error.isEmpty { self?.pause(message:error) }
    }.store(in:&subscriptions)
    voice.$text.removeDuplicates().dropFirst().sink { [weak self] text in
      guard let self, self.listening, !text.isEmpty else { return }
      self.transcript=text
      self.turnPolicy.update(transcript: text, at: ProcessInfo.processInfo.systemUptime)
      if self.phase == "Speaking" { return }
      self.timer?.cancel()
      let id = self.generation
      if !self.heard {
        self.heard = true
        self.maximum = Task { [weak self] in
          do { try await Task.sleep(for:.seconds(60)) } catch { return }
          guard let self, self.generation == id else { return }; self.finishUtterance()
        }
      }
      if self.silence == nil {
        self.silence = Task { [weak self] in
          while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, self.generation == id, self.listening else { return }
            if self.turnPolicy.shouldFinish(at: ProcessInfo.processInfo.systemUptime) { self.finishUtterance(); return }
          }
        }
      }
    }.store(in:&subscriptions)
  }
  func startSession(configuration:SupervisorConfiguration,onAnswer:@escaping(String)->Void,onInterrupt:@escaping()->Void,onLater:@escaping()->Void) {
    stop(); sessionActive=true; self.configuration=configuration; answer=onAnswer; self.onInterrupt=onInterrupt; later=onLater
    waitingQuestion="Conversation open"; generation=UUID(); openMicrophone()
  }
  func working() {
    guard sessionActive else { return }
    pause(message: "Thinking · microphone off")
    phase="Working"
  }
  func respond(text:String,configuration:SupervisorConfiguration) {
    guard sessionActive else { return }
    self.configuration=configuration; waitingQuestion="Conversation open"; transcript=""
    if !configuration.speakReplies { openMicrophone(); return }
    // Take turns by default: ordinary capture never runs during playback.
    // This avoids system-wide voice processing and self-transcription.
    pause(message: "Speaking")
    echoControlledSpeech=false
    phase="Speaking"
    if configuration.localSpeechEngine != "system", kokoro.installed {
      kokoro.speak(text,voice:configuration.localSpeechVoice ?? "af_heart",speed:configuration.localSpeechSpeed ?? 1)
    } else { renderSystemSpeech(text) }
  }
  private func renderSystemSpeech(_ text:String) {
    let id=UUID(); speechID=id; pendingSystemBuffers=0;systemRenderEnded=false
    let next=AVSpeechUtterance(string:text)
    speaker.write(next) { [weak self] buffer in
      guard let pcm=buffer as? AVAudioPCMBuffer else {return}
      Task { @MainActor [weak self] in
        guard let self,self.speechID == id,self.sessionActive else {return}
        if pcm.frameLength == 0 {
          self.systemRenderEnded=true
          if self.pendingSystemBuffers == 0 { self.endSystemPlayback(); self.systemSpeechFinished() }
          return
        }
        self.pendingSystemBuffers+=1; self.ownsSystemPlayback=true
        do {try SupervisorAudio.shared.enqueueSpeech(pcm) { [weak self] in
          Task { @MainActor [weak self] in
            guard let self,self.speechID == id else {return}
            self.pendingSystemBuffers-=1
            if self.pendingSystemBuffers == 0 && self.systemRenderEnded {self.endSystemPlayback();self.systemSpeechFinished()}
          }
        }} catch {self.pause(message:"Audio playback failed · use text or Resume conversation")}
      }
    }
  }

  private func systemSpeechFinished() {
    guard phase == "Speaking",systemRenderEnded,pendingSystemBuffers == 0 else {return}
    if voice.listening {listening=true;phase="Listening"} else {openMicrophone()}
  }
  private func endSystemPlayback() {
    guard ownsSystemPlayback else {return}
    ownsSystemPlayback=false; SupervisorAudio.shared.endPlayback()
  }
  func ask(question:String, configuration:SupervisorConfiguration, onAnswer:@escaping (String)->Void, onLater:@escaping ()->Void) {
    stop(); waitingQuestion = question; self.configuration = configuration; answer = onAnswer; later = onLater
    guard configuration.speakReplies else { phase = "Waiting for your answer"; return }
    phase = "Speaking"
    if configuration.localSpeechEngine != "system", kokoro.installed {
      kokoro.speak(question,voice:configuration.localSpeechVoice ?? "af_heart",speed:configuration.localSpeechSpeed ?? 1)
    } else { let next=AVSpeechUtterance(string:question); utterance=next; speaker.speak(next) }
  }
  func resume(configuration:SupervisorConfiguration) {
    guard waitingQuestion != nil, !active else { return }
    self.configuration=configuration; generation=UUID(); openMicrophone()
  }
  /// Pausing preserves the question and callbacks; no automatic retry or repeat.
  func pause(message:String = "Waiting for your answer") {
    speechID=UUID(); endSystemPlayback()
    generation=UUID(); timer?.cancel(); silence?.cancel(); maximum?.cancel()
    utterance=nil; speaker.stopSpeaking(at:.immediate); kokoro.stop(); voice.stop(); listening=false; phase=message
  }
  func stop() { sessionActive=false; echoControlledSpeech=false; pause(message:"Microphone off"); waitingQuestion=nil; answer=nil; later=nil; onInterrupt=nil; transcript="" }
  private func playbackFinished() {
    guard phase == "Speaking", !speaker.isSpeaking, !kokoro.speaking else { return }
    utterance=nil
    if voice.listening { phase="Listening"; listening=true } else { openMicrophone() }
  }
  private func openMicrophone() {
    guard waitingQuestion != nil else { return }
    let id=generation; phase="Opening microphone"; heard=false; turnPolicy = AlfredTurnPolicy(); silence = nil
    Task { [weak self] in
      guard let self, self.generation == id else { return }
      await self.voice.start()
      guard self.generation == id else { return }
      guard self.voice.listening else { self.pause(); return }
      self.listening=true; if self.phase != "Speaking" && self.phase != "Working" { self.phase=self.sessionActive ? "Listening" : "Listening for your answer" }
      if self.sessionActive { return }
      self.timer=Task { [weak self] in
        do { try await Task.sleep(for:.seconds(20)) } catch { return }
        guard let self, self.generation == id else { return }; self.pause()
      }
    }
  }
  func finishSpeaking() { finishUtterance() }
  private func finishUtterance() {
    guard listening else { return }
    silence?.cancel(); maximum?.cancel(); listening=false; phase="Processing reply"; voice.finishUtterance()
    let id=generation
    timer=Task { [weak self] in
      do { try await Task.sleep(for:.seconds(5)) } catch { return }
      guard let self, self.generation == id else { return }; self.pause()
    }
  }
  private func receiveFinal(_ text:String) {
    guard listening || phase == "Processing reply" else { return }
    switch RobinConversationVoiceReply.parseFinal(text) {
    case .empty: pause()
    case .cancel: pause()
    case .later: let callback=later; pause(); callback?()
    case .answer(let value):
      let callback=answer
      if sessionActive { working(); transcript=value } else { stop() }
      callback?(value)
    }
  }
  nonisolated func speechSynthesizer(_ synthesizer:AVSpeechSynthesizer,didFinish utterance:AVSpeechUtterance) {
    Task { @MainActor [weak self] in
      guard let self, self.utterance === utterance else { return }; self.playbackFinished()
    }
  }
}
