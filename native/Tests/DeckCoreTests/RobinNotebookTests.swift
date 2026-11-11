import XCTest
@testable import DeckCore
final class RobinNotebookTests: XCTestCase {
  func testNotebookKeepsProjectsAndApprovalSeparateAndRejectsUnverifiedSuccess() throws {
    var book = RobinNotebook()
    book.record(.init(project: "/a", kind: .preference, text: "Prefer short replies"))
    book.record(.init(project: "/b", kind: .preference, text: "Private other project", approved: true))
    book.record(.init(project: "/a", kind: .verifiedResult, text: "Tests passed"))
    XCTAssertEqual(book.notes.count, 2)
    let text = book.relevant(project: "/a", query: "reply")
    XCTAssertTrue(text.contains("inferred")); XCTAssertFalse(text.contains("Private other")); XCTAssertFalse(text.contains("Tests passed"))
    let decoded = try JSONDecoder().decode(RobinNotebook.self, from: JSONEncoder().encode(book))
    XCTAssertEqual(decoded.notes, book.notes)
    XCTAssertLessThanOrEqual(book.relevant(project: "/a", query: "", limit: 200).count, 200)
  }
  func testContextualReferenceUsesSelectionAndAsksWhenAmbiguous() async throws {
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"))
    let a = await engine.ingest(agent: "claude", event: "UserPromptSubmit", body: ["data": ["session_id": "a", "cwd": "/a"]])
    _ = await engine.ingest(agent: "claude", event: "UserPromptSubmit", body: ["data": ["session_id": "b", "cwd": "/b"]])
    let snapshot = await engine.snapshot()
    XCTAssertEqual(RobinReferenceResolver.resolve(text: "fix it", snapshot: snapshot, selectedSessionID: a.sessionId, conversationSessionID: nil, missionSessionID: nil), .session(a.sessionId))
    if case .ambiguous(let ids) = RobinReferenceResolver.resolve(text: "continue this", snapshot: snapshot, selectedSessionID: nil, conversationSessionID: nil, missionSessionID: nil) { XCTAssertEqual(ids.count, 2) } else { XCTFail("Must ask rather than guess") }
    XCTAssertEqual(RobinReferenceResolver.resolve(text: "hello", snapshot: snapshot, selectedSessionID: a.sessionId, conversationSessionID: nil, missionSessionID: nil), .none)
  }
}
