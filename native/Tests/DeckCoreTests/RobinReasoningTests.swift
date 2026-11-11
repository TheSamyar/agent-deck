import XCTest
@testable import DeckCore
final class RobinReasoningTests: XCTestCase {
  func testCredentialShapedContextStaysLocal() {
    for text in ["password: hello", "Authorization: Basic abc", "AWS_SECRET_ACCESS_KEY=value", "api key: value", "gsk_key", "-----BEGIN PRIVATE KEY-----"] { XCTAssertFalse(RobinReasoningPolicy.permitsCloud(text: text)) }
    XCTAssertTrue(RobinReasoningPolicy.permitsCloud(text: "Fix the dashboard and run its checks."))
  }
}
