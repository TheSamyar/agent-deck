import XCTest
@testable import DeckCore

final class NativeGUIBrokerTests: XCTestCase {
  func testLeaseAndPermissionsRequiredAndOnlyOneAppOwnsControls() throws {
    var broker = NativeGUIBroker()
    let command = NativeGUIControlRequest(kind: .focus)
    XCTAssertFalse(broker.enqueue(command))
    XCTAssertNotNil(broker.poll(.init(clientID: "app-one", accessibilityGranted: false, replies: [])))
    XCTAssertFalse(broker.enqueue(command))
    XCTAssertNotNil(broker.poll(.init(clientID: "app-one", accessibilityGranted: true, replies: [])))
    XCTAssertTrue(broker.enqueue(command))
    XCTAssertNil(broker.poll(.init(clientID: "app-two", accessibilityGranted: true, replies: [])))
    XCTAssertEqual(broker.poll(.init(clientID: "app-one", accessibilityGranted: true, replies: []))?.requests.first?.id, command.id)
  }
  func testRepliesAreScopedOneTimeAndCancelledOrExpiredRepliesAreIgnored() throws {
    var broker = NativeGUIBroker()
    _ = broker.poll(.init(clientID: "app", accessibilityGranted: true, replies: []))
    let command = NativeGUIControlRequest(kind: .focus)
    XCTAssertTrue(broker.enqueue(command))
    _ = broker.poll(.init(clientID: "app", accessibilityGranted: true,
      replies: [.init(id: "unknown", result: .failure("Wrong command"))]))
    XCTAssertNil(broker.take(command.id))
    let success = ActionResult(ok: true, state: "acknowledged", message: "Focused")
    let reply = NativeGUIControlReply(id: command.id, result: success)
    let delivery = try XCTUnwrap(broker.poll(.init(clientID: "app", accessibilityGranted: true, replies: [reply])))
    XCTAssertTrue(delivery.requests.isEmpty)
    XCTAssertEqual(broker.take(command.id)?.result, success)
    XCTAssertNil(broker.take(command.id))
    XCTAssertTrue(broker.enqueue(command)); broker.cancel(command.id)
    _ = broker.poll(.init(clientID: "app", accessibilityGranted: true, replies: [reply]))
    XCTAssertNil(broker.take(command.id))
    var expired = NativeGUIControlRequest(kind: .focus); expired.expiresAt = 0
    _ = broker.enqueue(expired)
    XCTAssertTrue(broker.poll(.init(clientID: "app", accessibilityGranted: true, replies: []))!.requests.isEmpty)
  }
  func testOnlyExpectedReplyTypeAndBoundedWindowResultsAreAccepted() {
    var broker = NativeGUIBroker()
    _ = broker.poll(.init(clientID: "app", accessibilityGranted: true, replies: []))
    let scan = NativeGUIControlRequest(kind: .scanWindows)
    XCTAssertTrue(broker.enqueue(scan))
    _ = broker.poll(.init(clientID: "app", accessibilityGranted: true,
      replies: [.init(id: scan.id, windowTitles: Array(repeating: "Window", count: 513))]))
    XCTAssertNil(broker.take(scan.id))
    let focus = NativeGUIControlRequest(kind: .focus); XCTAssertTrue(broker.enqueue(focus))
    _ = broker.poll(.init(clientID: "app", accessibilityGranted: true, replies: [.init(id: focus.id, windowTitles: ["Wrong type"])]))
    XCTAssertNil(broker.take(focus.id))
  }
}
