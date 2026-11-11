import XCTest
@testable import DeckCore
final class RobinConversationVoiceTests: XCTestCase {
  func testOrdinaryAnswersCarryNoApprovalAuthority() {
    for text in ["yes", "allow once", "approve", "the second one", "same project"] {
      XCTAssertEqual(RobinConversationVoiceReply.parseFinal(text), .answer(text))
    }
  }
  func testControlsAreExactNotEmbeddedInAnAnswer() {
    XCTAssertEqual(RobinConversationVoiceReply.parseFinal("Later."),.later)
    XCTAssertEqual(RobinConversationVoiceReply.parseFinal("stop listening"),.cancel)
    XCTAssertEqual(RobinConversationVoiceReply.parseFinal("  "),.empty)
    XCTAssertEqual(RobinConversationVoiceReply.parseFinal("do it later today"),.answer("do it later today"))
  }
}
