import XCTest
@testable import DeckCore

final class AlfredActionEventTests: XCTestCase {
  func testTimelineKeepsSafeTargetAndOmitsTypedContent() {
    let event = AlfredActionEvent(turnID: UUID(), step: .init(kind: .act, action: .typeText,
      arguments: .init(application: "com.example.Editor", text: "secret private content", target: "private control title")))
    XCTAssertEqual(event.target, "com.example.Editor")
    XCTAssertEqual(event.purpose, "Enter requested text")
    XCTAssertFalse(event.target.contains("private"))
    let file = AlfredActionEvent(turnID: UUID(), step: .init(kind: .act, action: .writeFile,
      arguments: .init(path: "/private/person/project/notes.txt", text: "private body")))
    XCTAssertEqual(file.target, "notes.txt")
    let website = AlfredActionEvent(turnID: UUID(), step: .init(kind: .act, action: .navigate,
      arguments: .init(origin: "https://example.com/private?token=secret")))
    XCTAssertEqual(website.target, "example.com")
  }
  func testAttemptDoesNotImplyVerificationAndCancellationIsTerminal() {
    var event = AlfredActionEvent(turnID: UUID(), step: .init(kind: .act, action: .click))
    event.finish(succeeded: true, verified: false)
    XCTAssertEqual(event.state, .attempted)
    var cancelled = AlfredActionEvent(turnID: UUID(), step: .init(kind: .act, action: .projectCommand))
    cancelled.cancel()
    cancelled.finish(succeeded: true, verified: true)
    XCTAssertEqual(cancelled.state, .cancelled)
    XCTAssertNotNil(cancelled.finishedAt)
  }
  func testWaitingCanBeCancelledAndFailureDoesNotVerify() {
    var waiting = AlfredActionEvent(turnID: UUID(), step: .init(kind: .act, action: .deleteFile), state: .waiting)
    waiting.cancel()
    XCTAssertEqual(waiting.state, .cancelled)
    var failure = AlfredActionEvent(turnID: UUID(), step: .init(kind: .act, action: .openApplication))
    failure.finish(succeeded: false, verified: true)
    XCTAssertEqual(failure.state, .failed)
  }
  func testOldReceiptsDecodeWithoutActionEventIdentifier() throws {
    let old = Data("{\"id\":\"00000000-0000-0000-0000-000000000000\",\"date\":0,\"action\":\"click\",\"succeeded\":true,\"verified\":false,\"detail\":\"acknowledged\"}".utf8)
    XCTAssertNil(try JSONDecoder().decode(JarvisReceipt.self, from: old).actionEventID)
    let id = UUID()
    let receipt = JarvisReceipt(action: .click, succeeded: true, verified: false, detail: "acknowledged", actionEventID: id)
    XCTAssertEqual(try JSONDecoder().decode(JarvisReceipt.self, from: JSONEncoder().encode(receipt)).actionEventID, id)
  }
}
