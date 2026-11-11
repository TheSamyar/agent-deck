import XCTest
@testable import DeckCore

final class MasterHUBPresentationTests: XCTestCase {
  func testDuplicateSessionsRemainDistinctAndPositionMatchesStableOrder() async throws {
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"))
    for index in 0..<2 {
      _ = await engine.ingest(agent: "claude", event: "UserPromptSubmit", body: [
        "data": ["session_id": "face-\(index)", "cwd": "/work/project"],
        "env": ["bundleId": "com.apple.Terminal", "ppid": 100 + index]])
    }
    var snapshot = await engine.snapshot()
    let ordered = MasterHUBSurface.orderedSessions(snapshot)
    XCTAssertEqual(ordered.count, 2)
    snapshot.selectedSessionId = ordered[1].id
    let face = MasterHUBDialPresentation(snapshot: snapshot)
    XCTAssertEqual(face.sessionID, ordered[1].id)
    XCTAssertTrue(face.identity.hasSuffix("· 2"))
    XCTAssertEqual(face.position, "2 / 2 · Press to focus")
  }
  func testOfflineFaceDoesNotInviteFocusingMissingSession() {
    let face = MasterHUBDialPresentation(snapshot: nil)
    XCTAssertEqual(face.project, "Offline")
    XCTAssertEqual(face.sessionID, "")
    XCTAssertEqual(face.position, "")
  }
}
