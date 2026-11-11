import Foundation
import DeckCore

/// Exercises production routing and cancellation with injected responses; never calls a provider or opens audio.
@MainActor enum AlfredRuntimeDiagnostic {
  static func run() async throws {
    func require(_ value: Bool, _ message: String) throws {
      if !value { throw RobinProviderError(message) }
    }
    var config = SupervisorConfiguration()
    config.robinProviderID = "chatgpt"; config.robinHybridEnabled = true
    let network = SupervisorNetwork()
    let usageID = UUID()
    var records: [RobinReasoningReceipt] = []
    var invoked = 0
    let provider: ([[String:String]], [String:Any], String) async throws -> RobinProviderReply = { messages, _, selected in
      invoked += 1
      try require(selected == "chatgpt" && messages.last?["content"] == "fixture", "Wrong request reached subscription provider")
      return .init(text: "fixture reply", usage: .init(), usageRecordID: usageID, durationMilliseconds: 1)
    }
    let reply = try await network.reason(configuration: config, key: "", messages: [], cloudMessages: [["role":"user","content":"fixture"]], schema: [:], preferCloud: true, cloudAllowed: true, onRouting: { _ in }, onReceipt: { records.append($0) }, subscriptionComplete: provider)
    try require(reply == "fixture reply" && invoked == 1 && records.count == 1, "Selected provider was not invoked exactly once")
    try require(records[0].outcome == .success && records[0].actualModelID == "chatgpt" && records[0].usageRecordID == usageID, "Codex success receipt lost actual provider/usage identity")
    records = []
    do {
      _ = try await network.reason(configuration: config, key: "", messages: [], cloudMessages: [], schema: [:], preferCloud: true, cloudAllowed: false, onRouting: { _ in }, onReceipt: { records.append($0) }, subscriptionComplete: provider)
      throw RobinProviderError("Blocked Codex request returned an answer")
    } catch {
      try require(invoked == 1 && records.count == 1 && records[0].outcome == .blocked && records[0].actualModelID == nil, "Blocked context reached provider or substituted a model")
    }
    records = []
    do {
      _ = try await network.reason(configuration: config, key: "", messages: [], cloudMessages: [], schema: [:], preferCloud: true, cloudAllowed: true, onRouting: { _ in }, onReceipt: { records.append($0) }, subscriptionComplete: { _, _, _ in throw RobinProviderError("Injected provider failure") })
      throw RobinProviderError("Failed Codex request returned an answer")
    } catch {
      try require(records.count == 1 && records[0].outcome == .failed && records[0].actualModelID == nil, "Failed Codex request silently substituted a model")
    }
    records = []
    do {
      _ = try await network.reason(configuration: config, key: "", messages: [], cloudMessages: [], schema: [:], preferCloud: true, cloudAllowed: true, onRouting: { _ in }, onReceipt: { records.append($0) }, subscriptionComplete: { _, _, _ in throw CancellationError() })
      throw RobinProviderError("Cancelled Codex request returned an answer")
    } catch is CancellationError {
      try require(records.count == 1 && records[0].outcome == .cancelled && records[0].actualModelID == nil, "Cancellation was misreported as a provider failure")
    }
    print("PASS: production reasoning route records actual Codex identity; blocked, failed, and cancelled requests never substitute a local answer. Injected provider responses; no account request made.")
    try await cancellation(parentTask: false)
    try await cancellation(parentTask: true)
    try audioCleanup()
    try await stalePersonalRead()
  }

  private static func cancellation(parentTask: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("alfred-runtime-cancel-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"))
    let deck = DeckModel(previewSnapshot: await engine.snapshot())
    let runner = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Jarvis/project-command.py")
    var calls = 0
    let runtime = JarvisRuntime(deck: deck, persist: false, commandRunnerURL: runner, reasoningFixture: { _ in
      calls += 1
      let step = calls == 1 ? JarvisStep(kind: .act, action: .projectCommand, arguments: .init(project: root.path, commandID: "slow")) : JarvisStep(kind: .respond, reply: "Replacement conversation")
      return String(decoding: try JSONEncoder().encode(step), as: UTF8.self)
    })
    runtime.grants.projects = [root.path]; runtime.grants.commandIDs = ["slow"]
    runtime.commands = [.init(id: "slow", project: root.path, executable: "/usr/bin/python3", arguments: ["-c", "from pathlib import Path; import time; Path('ready').write_text('1'); time.sleep(1); Path('completed').write_text('unexpected')"])]
    let running = Task { try await runtime.run("Execute the approved slow diagnostic", context: "", lessons: "") }
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) {
      guard Date() < deadline else { runtime.cancel(); throw RobinProviderError("Slow command did not start") }
      try await Task.sleep(for: .milliseconds(10))
    }
    if parentTask { running.cancel() } else { runtime.cancel() }
    if parentTask {
      // Wait before starting a replacement: superseding work must not hide a failed parent cancellation.
      _ = try? await running.value
      try await Task.sleep(for: .milliseconds(1100))
      guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("completed").path) else {
        throw RobinProviderError("Parent Task.cancel left the approved child command running")
      }
    }
    let replacement = try await runtime.run("Report cancellation without running another command", context: "", lessons: "")
    _ = try? await running.value
    try await Task.sleep(for: .milliseconds(1100))
    guard replacement == "Replacement conversation", runtime.receipts.isEmpty,
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("completed").path) else {
      throw RobinProviderError("Cancelled command survived, replayed, or appended a stale receipt")
    }
    print("PASS: actual runtime \(parentTask ? "parent Task cancellation" : "explicit cancellation") terminates its in-flight child, accepts a replacement turn, and rejects stale receipts.")
  }
  private static func audioCleanup() throws {
    let audio = SupervisorAudio.shared
    guard !audio.capture, !audio.playback, !audio.engine.isRunning else {
      throw RobinProviderError("Fixture audio unexpectedly started capture/playback")
    }
    audio.inputLevel = 0.8
    audio.endCapture(); audio.endPlayback(); audio.endCapture(); audio.endPlayback()
    guard !audio.capture, !audio.playback, !audio.engine.isRunning, audio.inputLevel == 0, audio.status == "Microphone off" else {
      throw RobinProviderError("Idempotent audio stop left stale activity or level")
    }
    print("PASS: idle audio cleanup is idempotent and resets status/meter without capture, playback or permission requests. Physical audio remains untested.")
  }

  private static func stalePersonalRead() async throws {
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"))
    let deck = DeckModel(previewSnapshot: await engine.snapshot())
    var calls = 0
    var waiting: CheckedContinuation<(String, Bool), Never>?
    let runtime = JarvisRuntime(deck: deck, persist: false, reasoningFixture: { _ in
      calls += 1
      let step = calls == 1 ? JarvisStep(kind: .act, action: .observe, arguments: .init(text: "fixture", target: "fixture-account", provider: "personal:calendar")) : JarvisStep(kind: .respond, reply: "Fresh replacement")
      return String(decoding: try JSONEncoder().encode(step), as: UTF8.self)
    })
    runtime.personalRead = { _, _, _, _ in
      await withCheckedContinuation { waiting = $0 }
    }
    let old = Task { try await runtime.run("Read the fixture account", context: "", lessons: "") }
    let deadline = Date().addingTimeInterval(3)
    while waiting == nil {
      guard Date() < deadline else { runtime.cancel(); throw RobinProviderError("Personal read fixture never reached suspension") }
      try await Task.sleep(for: .milliseconds(10))
    }
    let replacement = try await runtime.run("Start a fresh unrelated conversation", context: "", lessons: "")
    waiting?.resume(returning: ("Stale private account data", false)); waiting = nil
    _ = try? await old.value
    guard replacement == "Fresh replacement", !runtime.personalDataWithheld, runtime.receipts.isEmpty else {
      throw RobinProviderError("Stale personal read mutated a replacement conversation")
    }
    print("PASS: asynchronous personal read resolving after a replacement cannot mutate its privacy state or receipts.")
  }

}
