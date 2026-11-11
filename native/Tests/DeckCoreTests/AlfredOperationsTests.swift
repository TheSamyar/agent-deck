import XCTest
@testable import DeckCore
final class AlfredOperationsTests: XCTestCase {
  func testServerCasesAndSourcesDecodeWithoutInventingEvidence() throws {
    let json = #"{"success":true,"data":{"cases":[{"id":"16a2d58a-71f0-4ad2-8ee4-9d1bc39337a6","title":"GHL check","summary":"Diagnosis pending","status":"waiting","revision":3,"business_id":4,"linked_task_id":6261,"source_refs":[{"provider":"slack","sourceId":"x","threadId":null,"sourceUrl":"https://brandrap.slack.com/archives/C1/p1"}],"updated_at":"2026-11-04T12:00:00Z"}]}}"#
    let values = try AlfredOperationsCase.decodeList(Data(json.utf8))
    XCTAssertEqual(values.count, 1); XCTAssertEqual(values[0].revision, 3)
    XCTAssertEqual(values[0].displayStatus, "Waiting"); XCTAssertNotNil(values[0].caseURL(origin: URL(string:"https://alfred.example")!))
    XCTAssertNotNil(values[0].sourceRefs.first?.url)
  }
  func testOwnServerOriginsDoNotAcceptSecretsPathsOrRemotePlaintext() throws {
    XCTAssertEqual(try AlfredOperationsEndpoint.origin("http://localhost:8080/").absoluteString, "http://localhost:8080")
    XCTAssertEqual(try AlfredOperationsEndpoint.origin("https://alfred.example").host, "alfred.example")
    for value in ["http://remote.example", "https://user:password@alfred.example", "https://alfred.example/path", "https://alfred.example?token=secret", "file:///tmp/server"] {
      XCTAssertThrowsError(try AlfredOperationsEndpoint.origin(value))
    }
  }
  func testActualMcpResponseWrapperAndForbiddenAreHandled() throws {
    let data = Data(#"{"status":200,"data":{"success":true,"data":{"cases":[]}}}"#.utf8)
    XCTAssertEqual(try AlfredOperationsCase.decodeList(data), [])
    XCTAssertThrowsError(try AlfredOperationsCase.decodeList(Data(#"{"status":403,"data":{"cases":[]}}"#.utf8)))
    XCTAssertThrowsError(try AlfredOperationsCase.decodeList(Data(#"{"success":false,"data":{"cases":[]}}"#.utf8)))
  }
  func testUnsafeSourceURLsNeverBecomeClickable() {
    for value in ["javascript:alert(1)", "file:///tmp/private", "https://user:secret@example.com/x", "http://example.com"] {
      XCTAssertNil(AlfredOperationSource.safeURL(value))
    }
    XCTAssertNotNil(AlfredOperationSource.safeURL("https://hub.brandrap.com/operations"))
  }
  func testMalformedQueueIsNotSilentlyShownAsEmpty() {
    XCTAssertThrowsError(try AlfredOperationsCase.decodeList(Data(#"{"success":false,"error":"Forbidden"}"#.utf8)))
  }
}
