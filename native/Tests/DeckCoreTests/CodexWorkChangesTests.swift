import XCTest
@testable import DeckCore
final class CodexWorkChangesTests: XCTestCase {
  func testCollaborationCallCompletedDoesNotMeanChildCompleted() {
    let item: [String: Any] = ["id": "spawn", "type": "collabAgentToolCall", "tool": "spawnAgent", "status": "completed", "receiverThreadIds": ["child"], "agentsStates": ["child": ["status": "running", "message": "private response"]]]
    let changes = CodexWorkChanges.changes(item: item, started: false)
    XCTAssertTrue(changes.contains(.childCreated(id: "child")))
    XCTAssertTrue(changes.contains(.childState(id: "child", status: "running")))
    XCTAssertFalse(CodexWorkChanges.childTerminal("running"))
    XCTAssertEqual(changes.last, .toolCompleted(id: "spawn", kind: "collabAgentToolCall"))
  }
  func testCommandLifecycleHasStableIDAndMessageCompletionIsNotToolActivity() {
    let command: [String: Any] = ["id": "shell", "type": "commandExecution", "command": "private shell command"]
    XCTAssertEqual(CodexWorkChanges.changes(item: command, started: true), [.toolStarted(id: "shell", kind: "Bash")])
    XCTAssertEqual(CodexWorkChanges.changes(item: command, started: false), [.toolCompleted(id: "shell", kind: "Bash")])
    XCTAssertTrue(CodexWorkChanges.changes(item: ["id": "shell", "type": "commandExecution", "status": "inProgress"], started: false).isEmpty)
    XCTAssertTrue(CodexWorkChanges.changes(item: ["id": "message", "type": "agentMessage"], started: false).isEmpty)
  }
  func testDocumentedNewThreadShapeAndTerminalStates() {
    let changes = CodexWorkChanges.changes(item: ["id": "spawn", "type": "collabToolCall", "newThreadId": "child"], started: false)
    XCTAssertEqual(changes.first, .childCreated(id: "child"))
    for state in ["completed", "errored", "shutdown", "interrupted", "notFound"] { XCTAssertTrue(CodexWorkChanges.childTerminal(state)) }
    XCTAssertFalse(CodexWorkChanges.childTerminal("pendingInit")); XCTAssertFalse(CodexWorkChanges.childTerminal("unknown-future-state"))
  }
}
