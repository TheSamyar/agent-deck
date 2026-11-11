import AVFoundation
import Foundation
import SwiftUI

/// Native 24 kHz PCM transport. Audio is never written to disk.
@MainActor final class SupervisorRealtime: ObservableObject {
  @Published private(set) var speaking = false
  @Published private(set) var active = false
  @Published private(set) var connecting = false
  @Published var error = ""
  var onTranscript: (String, String) -> Void = { _, _ in }
  var onTool: (String, [String: Any]) -> String = { _, _ in "No action available." }
  private var socket: URLSessionWebSocketTask?
  private var receiver: Task<Void, Never>?
  private var sender: Task<Void, Never>?
  private var audioContinuation: AsyncStream<Data>.Continuation?
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var outputItem: String?
  private var outputStarted: TimeInterval?
  private var outputSamples = 0
  private var scheduledBuffers = 0
  private var playbackGeneration = UUID()
  private var responseID = ""
  private var ignored = Set<String>()
  private var generation = UUID()
  private var pendingInstructions = ""
  private let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
  private let playback = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

  static let compatibilityBlocker = "Cloud Realtime voice is unavailable while music and Discord compatibility is validated. Choose Local voice for speech; Codex reasoning still works."

  func start(key: String, model: String, instructions: String) async {
    stop()
    error = Self.compatibilityBlocker
  }
  func stop() {
    generation = UUID(); playbackGeneration = UUID(); scheduledBuffers = 0; speaking = false; connecting = false; active = false
    receiver?.cancel(); receiver = nil; sender?.cancel(); sender = nil
    audioContinuation?.finish(); audioContinuation = nil
    socket?.cancel(with: .normalClosure, reason: nil); socket = nil
    if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
    player?.stop(); player = nil; engine = nil
    outputItem = nil; outputStarted = nil; outputSamples = 0; ignored.removeAll()
  }
  func updateInstructions(_ text: String) {
    pendingInstructions = text
    guard active else { return }
    Task { try? await send(["type": "session.update", "session": ["type": "realtime", "instructions": text]]) }
  }
  private func send(_ value: [String: Any]) async throws {
    guard let socket else { throw URLError(.notConnectedToInternet) }
    let data = try JSONSerialization.data(withJSONObject: value)
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
  }
  private func receive(_ event: [String: Any]) async throws {
    switch event["type"] as? String ?? "" {
    case "session.created":
      try await send(["type": "session.update", "session": ["type": "realtime", "instructions": pendingInstructions,
        "output_modalities": ["audio"], "audio": [
          "input": ["format": ["type": "audio/pcm", "rate": 24000],
            "transcription": ["model": "gpt-4o-mini-transcribe"],
            "turn_detection": ["type": "server_vad", "silence_duration_ms": 700, "create_response": true, "interrupt_response": true]],
          "output": ["format": ["type": "audio/pcm", "rate": 24000], "voice": "marin"]],
        "tools": [
          ["type": "function", "name": "propose_lesson", "description": "Propose a lesson for explicit user approval. Does not save it.",
            "parameters": ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]],
          ["type": "function", "name": "draft_followup", "description": "Draft a follow-up for a managed task. Does not send it.",
            "parameters": ["type": "object", "properties": ["taskId": ["type": "string"], "prompt": ["type": "string"]], "required": ["taskId", "prompt"]]],
          ["type": "function", "name": "inspect_tasks", "description": "Read the full live Agent Deck overview: observed agent sessions, attention requests, managed goals, and results.",
            "parameters": ["type": "object", "properties": [:]]]
        ] ]])
    case "session.updated":
      if !active { try startAudio(); active = true; connecting = false }
    case "response.created":
      responseID = (event["response"] as? [String: Any])?["id"] as? String ?? ""
    case "input_audio_buffer.speech_started":
      ignored.insert(responseID)
      playbackGeneration = UUID(); scheduledBuffers = 0; speaking = false
      player?.stop(); player?.play()
      if let outputItem, let outputStarted {
        let played = min(Int((ProcessInfo.processInfo.systemUptime - outputStarted) * 1000), outputSamples * 1000 / 24000)
        try await send(["type": "conversation.item.truncate", "item_id": outputItem, "content_index": 0, "audio_end_ms": max(0, played)])
      }
      outputItem = nil; outputStarted = nil; outputSamples = 0
    case "response.output_audio.delta":
      guard !ignored.contains(event["response_id"] as? String ?? responseID), let encoded = event["delta"] as? String,
        let data = Data(base64Encoded: encoded), data.count % 2 == 0, !data.isEmpty else { return }
      let item = event["item_id"] as? String
      if outputItem != item { outputItem = item; outputStarted = ProcessInfo.processInfo.systemUptime; outputSamples = 0 }
      outputSamples += data.count / 2
      guard let buffer = AVAudioPCMBuffer(pcmFormat: playback, frameCapacity: AVAudioFrameCount(data.count / 2)) else { return }
      buffer.frameLength = buffer.frameCapacity
      data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
        guard let target = buffer.floatChannelData?[0] else { return }
        for index in 0..<(data.count / 2) {
          target[index] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
        }
      }
      guard let player else { return }
      let session = generation, playbackID = playbackGeneration
      scheduledBuffers += 1; speaking = true
      player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
        Task { @MainActor in
          guard let self, self.generation == session, self.playbackGeneration == playbackID else { return }
          self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
          self.speaking = self.scheduledBuffers > 0
        }
      }
    case "conversation.item.input_audio_transcription.completed":
      if let text = event["transcript"] as? String, !text.isEmpty { onTranscript("user", text) }
    case "response.output_audio_transcript.done", "response.output_text.done":
      if let text = event["transcript"] as? String ?? event["text"] as? String, !text.isEmpty { onTranscript("assistant", text) }
    case "response.function_call_arguments.done":
      guard let name = event["name"] as? String, let call = event["call_id"] as? String,
        let arguments = event["arguments"] as? String, let data = arguments.data(using: .utf8),
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
      let result = onTool(name, body)
      try await send(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": call, "output": result]])
      try await send(["type": "response.create"])
    case "error":
      let detail = (event["error"] as? [String: Any])?["message"] as? String ?? "Cloud voice rejected a request."
      error = detail
      stop()
    default: break
    }
  }
  private func startAudio() throws {
    let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    try engine.inputNode.setVoiceProcessingEnabled(true)
    engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: playback)
    let format = engine.inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0, let converter = AVAudioConverter(from: format, to: pcm) else {
      throw SupervisorNetwork.shared.problem("The microphone format could not be converted for voice.")
    }
    let stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(32)) { self.audioContinuation = $0 }
    let continuation = audioContinuation, pcm = self.pcm
    engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
      let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 24000 / format.sampleRate) + 32
      guard let converted = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: capacity) else { return }
      var supplied = false
      var error: NSError?
      converter.convert(to: converted, error: &error) { _, status in
        if supplied { status.pointee = .noDataNow; return nil }
        supplied = true; status.pointee = .haveData; return buffer
      }
      if error == nil, let samples = converted.int16ChannelData?[0], converted.frameLength > 0 {
        continuation?.yield(Data(bytes: samples, count: Int(converted.frameLength) * 2))
      }
    }
    self.engine = engine; self.player = player
    try engine.start(); player.play()
    sender = Task { [weak self] in
      do {
        for await data in stream {
          guard !Task.isCancelled, let self else { return }
          try await self.send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
        }
      } catch { guard let self else { return }; self.error = error.localizedDescription; self.stop() }
    }
  }
}
