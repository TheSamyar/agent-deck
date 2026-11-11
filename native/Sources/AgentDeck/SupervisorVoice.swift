import AVFoundation
import Speech
import SwiftUI

@MainActor final class SupervisorVoice: ObservableObject {
  @Published private(set) var listening = false
  @Published private(set) var text = ""
  @Published private(set) var inputLevel:Float = 0
  @Published private(set) var error = ""
  private(set) var lastSpeechDetectedUptime:TimeInterval = 0
  var onFinalText: ((String) -> Void)?
  var onEnd: () -> Void = {}
  var onSpeechActivity: (Bool) -> Void = { _ in }
  var onSpeechDetected: () -> Void = {}
  private var engine: AVAudioEngine {SupervisorAudio.shared.engine}
  private var task: SFSpeechRecognitionTask?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private static weak var captureOwner: SupervisorVoice?
  private var captureActive = false
  private var preparedCapture = false
  private var engineObserver: NSObjectProtocol?
  private var tapped = false
  private var generation = UUID()
  private var authorizing = false

  func start(voiceProcessing: Bool = false, initialPCM: Data? = nil) async {
    guard !listening, !authorizing else { return }
    stop(); error = ""; text = ""; authorizing = true
    let current = generation
    let authorized = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
    }
    guard generation == current else { return }
    guard authorized else { authorizing = false; error = "Enable Speech Recognition for Agent Deck in System Settings."; return }
    let microphone = await AVCaptureDevice.requestAccess(for: .audio)
    guard generation == current else { return }
    authorizing = false
    guard microphone else { error = "Enable Microphone for Agent Deck in System Settings."; return }
    guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
      error = "On-device speech is unavailable for this Mac or language. Use Cloud voice or text."; return
    }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.contextualStrings = ["Hey Alfred", "Alfred"]
    request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
    self.request = request
    guard Self.captureOwner == nil || Self.captureOwner === self else {
      self.request = nil; error = "Another Alfred microphone flow is active. Finish it before listening."; return
    }
    Self.captureOwner = self
    do {
      preparedCapture = true
      try SupervisorAudio.shared.prepareCapture(voiceProcessing: voiceProcessing)
    }
    catch { self.error = error.localizedDescription; stop(); return }
    let node = engine.inputNode, format = engine.inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { error = "No microphone input is available."; stop(); return }
    if let initialPCM, !initialPCM.isEmpty,
      let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
      let seed = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(initialPCM.count / 2)),
      let converter = AVAudioConverter(from: sourceFormat, to: format),
      let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(initialPCM.count / 2) * format.sampleRate / 16000) + 32) {
      seed.frameLength = AVAudioFrameCount(initialPCM.count / 2)
      if let samples = seed.int16ChannelData?[0] {
        initialPCM.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples, count: Int(seed.frameLength) * 2))
        var consumed = false; var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
          guard !consumed else { status.pointee = .noDataNow; return nil }
          consumed = true; status.pointee = .haveData; return seed
        }
        if conversionError == nil, converted.frameLength > 0 { request.append(converted) }
      }
    }
    let detector=SupervisorSpeechDetector()
    node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      request.append(buffer)
      let detected=detector.process(buffer),level=detector.level
      let speechActive = detector.speechActive
      let detectedAt=ProcessInfo.processInfo.systemUptime
      Task { @MainActor in
        guard let self,self.generation == current else {return}
        self.onSpeechActivity(speechActive)
        self.inputLevel=level
        SupervisorAudio.shared.inputLevel=level
        if detected {self.lastSpeechDetectedUptime=detectedAt;self.onSpeechDetected()}
      }
    }
    tapped = true
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      let transcript = result?.bestTranscription.formattedString
      let final = result?.isFinal == true
      let detail = error?.localizedDescription
      Task { @MainActor in
        guard let self, self.generation == current else { return }
        if let transcript { self.text = transcript }
        if final || detail != nil {
          self.stop()
          if let detail { self.error = detail } else { self.onFinalText?(transcript ?? ""); self.onEnd() }
        }
      }
    }
    do {
      try SupervisorAudio.shared.beginCapture(); captureActive = true; listening = true
      engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
        Task { @MainActor in
          guard let self, self.generation == current, self.captureActive, !self.engine.isRunning else { return }
          self.stop()
          self.error = "Audio device changed. Microphone stopped; press Listen to reconnect."
        }
      }
    }
    catch { self.error = error.localizedDescription; stop() }
  }

  /// Ordinary audio capture for a local wake detector: no Speech authorization or recognition task.
  func startWakeCapture(onPCM: @escaping @Sendable (Data) -> Void) async {
    guard !listening, !authorizing else { return }
    stop(); error = ""; text = ""; authorizing = true
    let current = generation
    let microphone = await AVCaptureDevice.requestAccess(for: .audio)
    guard generation == current else { return }
    authorizing = false
    guard microphone else { error = "Enable Microphone for Agent Deck in System Settings."; return }
    guard Self.captureOwner == nil || Self.captureOwner === self else { error = "Another Alfred microphone flow is active."; return }
    Self.captureOwner = self
    do { preparedCapture = true; try SupervisorAudio.shared.prepareCapture(voiceProcessing: false) }
    catch { self.error = error.localizedDescription; stop(); return }
    let node = engine.inputNode, format = node.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0,
      let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: format, to: target) else {
      error = "No usable microphone format for wake listening."; stop(); return
    }
    let wakeLevel = SupervisorSpeechDetector()
    node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      _ = wakeLevel.process(buffer)
      let level = wakeLevel.level
      Task { @MainActor in
        guard let self, self.generation == current else { return }
        self.inputLevel = level; SupervisorAudio.shared.inputLevel = level
      }
      guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16000 / format.sampleRate) + 32) else { return }
      var consumed = false; var conversionError: NSError?
      converter.convert(to: converted, error: &conversionError) { _, status in
        guard !consumed else { status.pointee = .noDataNow; return nil }
        consumed = true; status.pointee = .haveData; return buffer
      }
      guard conversionError == nil, converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else { return }
      onPCM(Data(bytes: samples, count: Int(converted.frameLength) * 2))
    }
    tapped = true
    do {
      try SupervisorAudio.shared.beginCapture(); captureActive = true; listening = true
      engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
        Task { @MainActor in
          guard let self, self.generation == current, self.captureActive, !self.engine.isRunning else { return }
          self.stop(); self.error = "Audio device changed. Wake listening stopped; Resume to reconnect."
        }
      }
    } catch { self.error = error.localizedDescription; stop() }
  }

  func finishUtterance() {
    if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
    if let engineObserver { NotificationCenter.default.removeObserver(engineObserver); self.engineObserver = nil }
    if preparedCapture { SupervisorAudio.shared.endCapture(); preparedCapture = false; captureActive = false }
    if Self.captureOwner === self { Self.captureOwner = nil }
    listening = false; inputLevel=0; request?.endAudio()
  }
  func stop() {
    generation = UUID(); authorizing = false; listening = false; inputLevel=0
    if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
    if let engineObserver { NotificationCenter.default.removeObserver(engineObserver); self.engineObserver = nil }
    if preparedCapture { SupervisorAudio.shared.endCapture(); preparedCapture = false; captureActive = false }
    if Self.captureOwner === self { Self.captureOwner = nil }
    request?.endAudio(); task?.cancel(); task = nil; request = nil
  }
}
