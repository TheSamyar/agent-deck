import XCTest
import Darwin
@testable import DeckCore

final class SessionLifecycleTests: XCTestCase {
  private func body(_ id: String, extra: [String: Any] = [:]) -> [String: Any] {
    ["data": ["session_id": id, "cwd": "/work/fixture"].merging(extra) { _, new in new },
     "env": ["ppid": 123, "bundleId": "com.apple.Terminal", "processBirth": "10:20"]]
  }
  func testChildEventsNeverCreateOrFinishParentOrOwnApprovals() async throws {
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"))
    let parent = await engine.ingest(agent: "claude", event: "UserPromptSubmit", body: body("parent"))
    for event in ["SubagentStart", "Stop", "SessionEnd"] {
      _ = await engine.ingest(agent: "claude", event: event, body: body("parent", extra: ["agent_id": "child"]), decisionChannel: true)
    }
    let snapshot = await engine.snapshot()
    XCTAssertEqual(snapshot.sessions.count, 1)
    XCTAssertEqual(snapshot.sessions[parent.sessionId]?.status, .working)
    XCTAssertTrue(snapshot.requests.isEmpty)
  }
  func testNamedRootAgentIsNotConfusedWithChild() async throws {
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"))
    _ = await engine.ingest(agent: "claude", event: "SessionStart", body: body("root", extra: ["agent_type": "reviewer"]))
    let snapshot = await engine.snapshot()
    XCTAssertEqual(snapshot.sessions.count, 1)
  }
  func testEditorWindowsNeverBecomeAgentsAndCursorConversationsStayDistinct() async throws {
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"))
    await engine.synchronizeCursorWindows(["Project A", "Project B"])
    let empty = await engine.snapshot(); XCTAssertTrue(empty.sessions.isEmpty)
    for id in ["conversation-a", "conversation-b"] {
      _ = await engine.ingest(agent: "cursor", event: "beforeSubmitPrompt", body: ["data": ["conversation_id": id, "cwd": "/work/shared"]])
    }
    await engine.synchronizeCursorWindows([])
    let snapshot = await engine.snapshot(); XCTAssertEqual(snapshot.sessions.count, 2)
  }
  func testCodexEndOfTurnKeepsOwnerAndUnverifiedNeverAppearsOnDeck() async throws {
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"))
    let receipt = await engine.ingest(agent: "codex", event: "turn-ended", body: body("codex-root"))
    let before = await engine.snapshot()
    XCTAssertEqual(before.sessions[receipt.sessionId]?.pid, 123)
    XCTAssertEqual(before.sessions[receipt.sessionId]?.processBirth, "10:20")
    await engine.markUnverified(receipt.sessionId)
    let after = await engine.snapshot()
    XCTAssertEqual(after.sessions[receipt.sessionId]?.status, .unknown)
    XCTAssertTrue(MasterHUBSurface.orderedSessions(after).isEmpty)
  }
  func testCodexProvenanceSeparatesChildrenAndArchivedRoots() {
    XCTAssertEqual(CodexThreadEvidence.classify(source: "cli", archived: false), .root)
    XCTAssertEqual(CodexThreadEvidence.classify(source: "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"root\"}}}", archived: false), .child)
    XCTAssertEqual(CodexThreadEvidence.classify(source: "{\"subagent\":{\"other\":\"guardian\"}}", archived: false), .child)
    XCTAssertEqual(CodexThreadEvidence.classify(source: "vscode", archived: true), .archived)
    XCTAssertEqual(CodexThreadEvidence.classify(source: "new-unknown-format", archived: false), .unknown)
  }
  func testProcessWitnessHasStableBirthAndRejectsInvalidPIDs() throws {
    let witness = try XCTUnwrap(ProcessWitness.read(Int(getpid())))
    XCTAssertEqual(ProcessWitness.read(Int(getpid()))?.birth, witness.birth)
    XCTAssertFalse(witness.birth.isEmpty)
    XCTAssertNil(ProcessWitness.read(0)); XCTAssertNil(ProcessWitness.read(Int.max))
    XCTAssertNil(ProcessWitness.agentOwner(startingAt: Int(getpid()), agent: "claude"))
  }
  func testHookStatusDropsPromptsAndToolOutputsButKeepsRequiredIdentity() {
    let input: [String: Any] = ["session_id": "root", "prompt": "private prompt", "last_assistant_message": "private answer",
      "tool_response": "private output", "transcript_path": "/private/transcript.jsonl",
      "tool_input": ["command": "printf harmless", "content": "private file contents"]]
    let status = HookMetadata.filtered(input, permissionContext: false)
    XCTAssertEqual(status["session_id"] as? String, "root")
    XCTAssertNil(status["prompt"]); XCTAssertNil(status["tool_response"]); XCTAssertNil(status["last_assistant_message"])
    XCTAssertNil(status["tool_input"]); XCTAssertNil(status["transcript_path"])
    let permission = HookMetadata.filtered(input, permissionContext: true)
    XCTAssertEqual((permission["tool_input"] as? [String: String])?["command"], "printf harmless")
    XCTAssertNil((permission["tool_input"] as? [String: Any])?["content"])
  }

}
