import XCTest
@testable import DeckCore

final class SessionWorkTests: XCTestCase {
  private func engine() throws -> DeckEngine { try .init(database: DeckDatabase(path: ":memory:"), codexEvidenceLookup: { _ in .root }) }
  private func body(_ extra: [String: Any] = [:]) -> [String: Any] {
    ["data": ["session_id": "root-work", "cwd": "/work/project"].merging(extra) { _, new in new }, "env": ["bundleId": "com.apple.Terminal", "ppid": 123]]
  }
  func testRootStopWaitsForChildAndChildCompletionDoesNotFinishRoot() async throws {
    let engine = try engine()
    let root = await engine.ingest(agent: "claude", event: "UserPromptSubmit", body: body())
    _ = await engine.ingest(agent: "claude", event: "SubagentStart", body: body(["agent_id": "child-a"]))
    _ = await engine.ingest(agent: "claude", event: "Stop", body: body())
    var state = await engine.snapshot()
    XCTAssertEqual(state.sessions.count, 1); XCTAssertEqual(state.sessions[root.sessionId]?.status, .working)
    XCTAssertEqual(state.sessions[root.sessionId]?.work?.subagents, 1)
    _ = await engine.ingest(agent: "claude", event: "SubagentStop", body: body(["agent_id": "child-a"]))
    state = await engine.snapshot(); XCTAssertEqual(state.sessions[root.sessionId]?.status, .working)
    XCTAssertEqual(state.sessions[root.sessionId]?.detail, "Processing results")
    _ = await engine.ingest(agent: "claude", event: "Stop", body: body(["background_tasks": []]))
    state = await engine.snapshot(); XCTAssertEqual(state.sessions[root.sessionId]?.status, .done)
  }
  func testRunningShellRegistryPreventsDoneAndDoesNotExposeCommand() async throws {
    let engine = try engine()
    let root = await engine.ingest(agent: "claude", event: "UserPromptSubmit", body: body())
    let payload: [String: Any] = ["background_tasks": [["id": "shell-1", "type": "shell", "status": "running", "command": "private command", "description": "private context"]]]
    let filtered = HookMetadata.filtered(payload, permissionContext: false)
    XCTAssertNil((filtered["background_tasks"] as? [[String: Any]])?.first?["command"])
    _ = await engine.ingest(agent: "claude", event: "Stop", body: body(filtered))
    var state = await engine.snapshot(); XCTAssertEqual(state.sessions[root.sessionId]?.status, .working)
    XCTAssertEqual(state.sessions[root.sessionId]?.work?.shellJobs, 1)
    _ = await engine.ingest(agent: "claude", event: "Stop", body: body(["background_tasks": []]))
    state = await engine.snapshot(); XCTAssertEqual(state.sessions[root.sessionId]?.status, .done)
  }
  func testForegroundShellIsNotDoneUntilItsCompletionAndFinalRootStop() async throws {
    let engine = try engine()
    let root = await engine.ingest(agent: "codex", event: "UserPromptSubmit", body: body(["turn_id": "current"]))
    let tool: [String: Any] = ["tool_name": "exec_command", "tool_use_id": "exec-1"]
    _ = await engine.ingest(agent: "codex", event: "PreToolUse", body: body(tool))
    _ = await engine.ingest(agent: "codex", event: "Stop", body: body(["turn_id": "current"]))
    var state = await engine.snapshot(); XCTAssertEqual(state.sessions[root.sessionId]?.status, .working)
    XCTAssertEqual(state.sessions[root.sessionId]?.work?.shellJobs, 1)
    _ = await engine.ingest(agent: "codex", event: "PostToolUse", body: body(tool))
    state = await engine.snapshot(); XCTAssertEqual(state.sessions[root.sessionId]?.status, .working)
    _ = await engine.ingest(agent: "codex", event: "Stop", body: body(["turn_id": "old"]))
    state = await engine.snapshot(); XCTAssertEqual(state.sessions[root.sessionId]?.status, .working)
    _ = await engine.ingest(agent: "codex", event: "Stop", body: body(["turn_id": "current"]))
    state = await engine.snapshot(); XCTAssertEqual(state.sessions[root.sessionId]?.status, .done)
    _ = await engine.ingest(agent: "codex", event: "PostToolUse", body: body(tool))
    state = await engine.snapshot(); XCTAssertEqual(state.sessions[root.sessionId]?.status, .done)
  }
  func testLateInternalChildDoesNotReviveFinishedRootAndOrphansCreateNoAgents() async throws {
    let engine = try engine()
    _ = await engine.ingest(agent: "claude", event: "SubagentStart", body: body(["agent_id": "orphan"]))
    var state = await engine.snapshot(); XCTAssertTrue(state.sessions.isEmpty)
    let root = await engine.ingest(agent: "claude", event: "UserPromptSubmit", body: body())
    _ = await engine.ingest(agent: "claude", event: "Stop", body: body())
    for event in ["SubagentStart", "SubagentStop"] { _ = await engine.ingest(agent: "claude", event: event, body: body(["agent_id": "internal"])) }
    state = await engine.snapshot(); XCTAssertEqual(state.sessions[root.sessionId]?.status, .done)
  }
  func testBlockedChildMeansUserInputAndCompletionResumesParentWithoutApproving() async throws {
    let engine = try engine()
    let root = await engine.ingest(agent: "claude", event: "UserPromptSubmit", body: body())
    _ = await engine.ingest(agent: "claude", event: "SubagentStart", body: body(["agent_id": "child"]))
    _ = await engine.ingest(agent: "claude", event: "PermissionRequest", body: body(["agent_id": "child"]), decisionChannel: true)
    var state = await engine.snapshot(); XCTAssertEqual(state.sessions.count, 1)
    XCTAssertEqual(state.sessions[root.sessionId]?.status, .waiting); XCTAssertTrue(state.requests.isEmpty)
    _ = await engine.ingest(agent: "claude", event: "Stop", body: body())
    state = await engine.snapshot(); XCTAssertEqual(state.sessions[root.sessionId]?.status, .waiting)
    _ = await engine.ingest(agent: "claude", event: "SubagentStop", body: body(["agent_id": "child"]))
    state = await engine.snapshot(); XCTAssertEqual(state.sessions[root.sessionId]?.status, .working)
    _ = await engine.ingest(agent: "claude", event: "Stop", body: body())
    state = await engine.snapshot(); XCTAssertEqual(state.sessions[root.sessionId]?.status, .done)
  }
  func testTruncatedBackgroundRegistryCannotFalselyProveCompletion() {
    let payload: [String: Any] = ["background_tasks": (0..<300).map { ["id": "job-\($0)", "type": "shell", "status": $0 == 299 ? "running" : "completed"] }]
    let filtered = HookMetadata.filtered(payload, permissionContext: false)
    var ledger = SessionWorkLedger(); _ = ledger.observe("Stop", data: filtered)
    XCTAssertTrue(ledger.summary.hasOutstanding)
  }

}
