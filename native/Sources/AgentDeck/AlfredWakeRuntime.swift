import Foundation
import CryptoKit
import Darwin

/// One bounded writer shared by the real-time tap and the worker. Audio stays in memory.
final class AlfredWakePCMTransport: @unchecked Sendable {
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "com.aiagentdeck.alfred-wake-pcm")
  private var handle: FileHandle?
  private var epoch = UUID()
  private var queuedBytes = 0
  private var ring = Data()
  private var onOverflow: (@Sendable () -> Void)?
  func attach(_ handle: FileHandle?, onOverflow: (@Sendable () -> Void)? = nil) {
    lock.lock(); defer { lock.unlock() }
    self.handle = handle; self.onOverflow = onOverflow; epoch = UUID(); queuedBytes = 0; ring.removeAll()
    if let handle { _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) }
  }
  func preroll() -> Data { lock.lock(); defer { lock.unlock() }; return ring }
  func submit(_ data: Data) {
    lock.lock()
    guard let handle, !data.isEmpty else { lock.unlock(); return }
    guard data.count <= 16384, queuedBytes + data.count <= 32768 else {
      let failure = onOverflow; onOverflow = nil; lock.unlock(); failure?(); return
    }
    ring.append(data); if ring.count > 64000 { ring = Data(ring.suffix(64000)) }
    let id = epoch; queuedBytes += data.count; lock.unlock()
    queue.async { [weak self] in
      guard let self else { return }
      self.lock.lock(); let valid = self.epoch == id; self.lock.unlock()
      if valid { try? handle.write(contentsOf: data) }
      self.lock.lock(); if self.epoch == id { self.queuedBytes -= data.count }; self.lock.unlock()
    }
  }
}

@MainActor final class AlfredWakeRuntime {
  enum Failure: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let text) = self { return text }; return nil }
  }
  nonisolated let transport = AlfredWakePCMTransport()
  var onDetection: (Data) -> Void = { _ in }
  var onError: (String) -> Void = { _ in }
  private var process: Process?
  private var input: FileHandle?
  private var output: FileHandle?
  private var generation = UUID()
  private var lines = Data()
  private var ready: CheckedContinuation<Void, Error>?
  private var timeout: Task<Void, Never>?
  static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Deck/AlfredWake")
  static var resourceDirectory: URL {
    let bundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AlfredWake")
    return FileManager.default.fileExists(atPath: bundle.path) ? bundle : URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/AlfredWake")
  }
  static func checkAssets(directory override: URL? = nil) throws {
    let directory = override ?? Self.directory
    let manifest = directory.appendingPathComponent("model-manifest.json")
    guard let data = try? Data(contentsOf: manifest), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      json["version"] as? Int == 1, json["verification_phrase"] as? String == "Hey Alfred",
      let files = json["files"] as? [[String: String]], files.count == 4,
      Set(files.compactMap { $0["name"] }) == Set(["alfred.onnx", "melspectrogram.onnx", "embedding_model.onnx", "silero_vad.onnx"]),
      let threshold = json["threshold"] as? Double, threshold.isFinite, (0.5...0.95).contains(threshold) else {
      throw Failure.unavailable("Dedicated Alfred wake model is not installed. Install the wake runtime in Settings; the Listen button still works.")
    }
    for file in files {
      guard let name = file["name"], URL(fileURLWithPath: name).lastPathComponent == name,
        let expected = file["sha256"], let bytes = try? Data(contentsOf: directory.appendingPathComponent(name)),
        SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expected else {
        throw Failure.unavailable("Alfred wake model checksum verification failed. Reinstall the wake runtime; no microphone was opened.")
      }
    }
    guard FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("venv/bin/python").path) else {
      throw Failure.unavailable("Alfred wake runtime is missing. Install it before enabling hands-free listening.")
    }
  }
  func start() async throws {
    stop()
    try Self.checkAssets()
    let id = generation
    let child = Process(), stdin = Pipe(), stdout = Pipe()
    child.executableURL = Self.directory.appendingPathComponent("venv/bin/python")
    child.arguments = [Self.resourceDirectory.appendingPathComponent("worker.py").path, "--manifest", Self.directory.appendingPathComponent("model-manifest.json").path]
    child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
    var env = ProcessInfo.processInfo.environment; env["PYTHONUNBUFFERED"] = "1"; child.environment = env
    input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; process = child
    output?.readabilityHandler = { [weak self] handle in
      let bytes = handle.availableData
      Task { @MainActor in self?.receive(bytes, id: id) }
    }
    child.terminationHandler = { [weak self] _ in
      Task { @MainActor in
        guard let self, self.generation == id else { return }
        self.fail("Alfred wake runtime stopped. Press Resume to retry; manual Listen still works.")
      }
    }
    do { try child.run() } catch { stop(); throw error }
    transport.attach(stdin.fileHandleForWriting) { [weak self] in
      Task { @MainActor in
        guard let self, self.generation == id else { return }
        self.fail("Alfred wake runtime could not keep up. Microphone stopped; press Resume to retry.")
      }
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        ready = continuation
        timeout = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(20)) } catch { return }
          guard let self, self.generation == id else { return }
          self.fail("Alfred wake runtime did not become ready. Manual Listen still works.")
        }
      }
    } onCancel: { Task { @MainActor [weak self] in guard let self, self.generation == id else { return }; self.stop() } }
  }
  private func receive(_ bytes: Data, id: UUID) {
    guard generation == id, !bytes.isEmpty else { return }
    guard lines.count + bytes.count <= 16384 else { fail("Invalid Alfred wake runtime response."); return }
    lines.append(bytes)
    while let end = lines.firstIndex(of: 10) {
      let line = lines[..<end]; lines.removeSubrange(...end)
      guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = event["type"] as? String else { continue }
      switch type {
      case "ready":
        guard event["protocol"] as? Int == 1, event["sampleRate"] as? Int == 16000, event["verificationPhrase"] as? String == "Hey Alfred" else { fail("Incompatible Alfred wake protocol."); return }
        timeout?.cancel(); timeout = nil; let completion = ready; ready = nil; completion?.resume()
      case "wakeDetected":
        guard ready == nil else { continue }
        onDetection(transport.preroll())
      case "error": fail(event["message"] as? String ?? "Alfred wake model failed."); return
      default: break
      }
    }
  }
  private func fail(_ message: String) {
    let completion = ready; ready = nil; stop()
    completion?.resume(throwing: Failure.unavailable(message)); onError(message)
  }
  func stop() {
    generation = UUID(); timeout?.cancel(); timeout = nil
    let completion = ready; ready = nil; completion?.resume(throwing: CancellationError())
    transport.attach(nil)
    output?.readabilityHandler = nil
    if let process, process.isRunning { process.terminate() }
    process = nil; try? input?.close(); input = nil; try? output?.close(); output = nil; lines.removeAll()
  }
}
