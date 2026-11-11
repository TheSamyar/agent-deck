import AVFoundation
import DeckCore
import Foundation
import SwiftUI

/// A private stdio worker keeps the model warm. Text and audio never use a network socket.
@MainActor final class SupervisorKokoro: ObservableObject {
  @Published private(set) var status = "Install Kokoro to use the dedicated Local voice."
  @Published private(set) var speaking = false
  @Published private(set) var installing = false
  var onFinished: () -> Void = {}
  var onError: (String) -> Void = { _ in }
  private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Deck/Kokoro")
  private var worker: Process?
  private var input: FileHandle?
  private var installer: Process?
  private var generation = UUID()
  private var current: String?
  private var buffers = 0
  private var generated = false
  private var receivedAudio = false
  private var queued: [(String,String,Double)] = []
  private static weak var playbackOwner: SupervisorKokoro?
  private var ownsPlayback = false
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
  private var python: URL { root.appendingPathComponent("venv/bin/python") }
  private var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/KokoroVoice/kokoro_voice.py") }
  var installed: Bool {
    ["ready.json", "venv/bin/python", "kokoro-v1.0.onnx", "voices-v1.0.bin"].allSatisfy {
      FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
    }
  }

  init() {
    if installed { status = "Kokoro installed · Heart voice ready." }
  }
  func install() {
    guard !installing else { return }
    shutdown(); installing = true; status = "Installing the Local voice…"
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [helper.path, "--install", "--root", root.path]
    process.standardOutput = output; process.standardError = logHandle()
    do {
      try process.run(); installer = process
      Task.detached { [weak self] in
        var data = Data()
        while true {
          let chunk = output.fileHandleForReading.availableData
          if chunk.isEmpty { break }
          data.append(chunk)
          while let end = data.firstIndex(of: 10) {
            let line = Data(data[..<end]); data.removeSubrange(...end)
            await self?.installationEvent(line)
          }
        }
        process.waitUntilExit()
        await self?.installationEnded(process.terminationStatus)
      }
    } catch { installing = false; fail(error.localizedDescription) }
  }
  private func installationEvent(_ data: Data) {
    guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    if let message = event["message"] as? String { status = message }
    if event["type"] as? String == "error" { onError(status) }
  }
  private func installationEnded(_ code: Int32) {
    installing = false; installer = nil
    if code != 0 || !installed { onError(status.isEmpty ? "Kokoro installation failed. Retry Install voice." : status) }
  }
  private func logHandle() -> FileHandle {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AgentDeck-kokoro.log")
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
    guard let handle = try? FileHandle(forWritingTo: url) else { return .nullDevice }
    _ = try? handle.seekToEnd(); return handle
  }
  private func startWorker() throws {
    if worker?.isRunning == true { return }
    guard installed else { throw SupervisorNetwork.shared.problem("Install Kokoro in Setup & compare → Local voice first.") }
    let process = Process(), output = Pipe(), stdin = Pipe()
    process.executableURL = python; process.arguments = ["-u", helper.path, "--root", root.path]
    var env = ProcessInfo.processInfo.environment
    env["PYTHONNOUSERSITE"] = "1"; env["PYTHONDONTWRITEBYTECODE"] = "1"
    process.environment = env
    process.standardOutput = output; process.standardInput = stdin; process.standardError = logHandle()
    let currentGeneration = UUID(); generation = currentGeneration
    try process.run(); worker = process; input = stdin.fileHandleForWriting
    Task.detached { [weak self] in
      var data = Data()
      while true {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        data.append(chunk)
        while let end = data.firstIndex(of: 10) {
          let line = Data(data[..<end]); data.removeSubrange(...end)
          await self?.receive(line, generation: currentGeneration)
        }
        if data.count > 8_000_000 { if process.isRunning { process.terminate() }; break }
      }
      process.waitUntilExit()
      await self?.workerEnded(generation: currentGeneration)
    }
  }
  private func send(_ object: [String: Any]) throws {
    guard let input else { throw SupervisorNetwork.shared.problem("The Local voice runtime is unavailable.") }
    try input.write(contentsOf: JSONSerialization.data(withJSONObject: object) + Data([10]))
  }
  func speak(_ text: String, voice: String, speed: Double) {
    stop()
    let text = SupervisorSpeech.prepared(text)
    guard !text.isEmpty else { onFinished(); return }
    guard SupervisorSpeech.voices.contains(voice), (0.8...1.2).contains(speed) else { fail("Choose a supported Kokoro voice and speed."); return }
    do {
      try startWorker()
      guard Self.playbackOwner == nil || Self.playbackOwner === self else {
        throw SupervisorNetwork.shared.problem("Another Alfred voice is playing. Finish it before starting this reply.")
      }
      Self.playbackOwner = self
      let engine = SupervisorAudio.shared.engine, player = SupervisorAudio.shared.player
      self.engine = engine; self.player = player
      try SupervisorAudio.shared.beginPlayback(); ownsPlayback = true
      let id = UUID().uuidString
      current = id; buffers = 0; generated = false; receivedAudio = false; speaking = true; status = "Generating Kokoro speech…"
      try send(["id": id, "text": text, "voice": voice, "speed": speed])
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(45))
        guard let self, self.current == id, !self.receivedAudio else { return }
        self.fail("Kokoro did not produce audio within 45 seconds. Check the Local voice setup.")
      }
    } catch { fail(error.localizedDescription) }
  }
  func stop() {
    queued.removeAll()
    if let id = current { try? send(["type": "cancel", "id": id]) }
    current = nil; buffers = 0; generated = false; speaking = false
    if ownsPlayback { SupervisorAudio.shared.endPlayback(); ownsPlayback = false }
    if Self.playbackOwner === self { Self.playbackOwner = nil }
    player = nil; engine = nil
  }
  func enqueue(_ text: String, voice: String, speed: Double) {
    guard !SupervisorSpeech.prepared(text).isEmpty else {return}
    if speaking { if queued.count<20 {queued.append((text,voice,speed))} }
    else {speak(text,voice:voice,speed:speed)}
  }
  func shutdown() {
    stop(); generation = UUID()
    try? input?.close(); input = nil
    if let worker, worker.isRunning { worker.terminate() }; worker = nil
  }
  private func receive(_ data: Data, generation: UUID) {
    guard self.generation == generation,
      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    let type = event["type"] as? String ?? ""
    if type == "ready" { status = speaking ? "Generating Kokoro speech…" : "Kokoro ready."; return }
    guard let id = current else { return }
    if let incoming = event["id"] as? String, incoming != id { return }
    if type == "error" { fail(event["message"] as? String ?? "Local voice failed."); return }
    guard event["id"] as? String == id else { return }
    if type == "done" {
      generated = true
      if !receivedAudio { fail("Kokoro returned no audio for this reply.") } else { finishIfReady() }
    } else if type == "audio" {
      guard event["sampleRate"] as? Int == 24000, let encoded = event["pcm"] as? String,
        let pcm = Data(base64Encoded: encoded), !pcm.isEmpty, pcm.count % 2 == 0,
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count / 2)) else {
        fail("The Local voice returned an unsupported audio format."); return
      }
      buffer.frameLength = buffer.frameCapacity
      pcm.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
        guard let target = buffer.floatChannelData?[0] else { return }
        for index in 0..<(pcm.count / 2) {
          target[index] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index*2, as: Int16.self))) / 32768
        }
      }
      buffers += 1; receivedAudio = true; status = "Speaking with Kokoro…"
      player?.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: { [weak self] _ in
        Task { @MainActor in
          guard let self, self.current == id else { return }
          self.buffers -= 1; self.finishIfReady()
        }
      })
    }
  }
  private func finishIfReady() {
    guard current != nil, generated, buffers == 0 else { return }
    current = nil; speaking = false; status = "Kokoro ready."
    if ownsPlayback { SupervisorAudio.shared.endPlayback(); ownsPlayback = false }
    if Self.playbackOwner === self { Self.playbackOwner = nil }
    player = nil; engine = nil
    if !queued.isEmpty {
      let next=queued.removeFirst(), waiting=queued
      speak(next.0,voice:next.1,speed:next.2);queued=waiting
      return
    }
    onFinished()
  }
  private func workerEnded(generation: UUID) {
    guard self.generation == generation else { return }
    worker = nil; input = nil
    if current != nil { fail("The Kokoro runtime stopped. Try Preview voice in Setup & compare.") }
  }
  private func fail(_ message: String) {
    stop(); status = message; onError(message)
  }
}
