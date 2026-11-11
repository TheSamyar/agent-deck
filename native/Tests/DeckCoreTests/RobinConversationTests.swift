import XCTest
@testable import DeckCore
final class RobinConversationTests: XCTestCase {
  func testCloudHistoryCannotLeakOldUnscopedOrOtherProjectMessages() {
    let messages: [SupervisorMessage] = [.init(role:"user",content:"old unscoped"),.init(role:"user",content:"other project",project:"/b"),.init(role:"user",content:"use the second option",project:"/a")]
    XCTAssertEqual(RobinConversation.history(messages,project:"/a",cloud:true).map{$0["content"]},["use the second option"])
    XCTAssertEqual(RobinConversation.history(messages,project:"/a",cloud:false).count,2)
  }
  func testPendingReplyKeepsQuestionAndOriginalGoal() throws {
    let question=RobinConversationQuestion(project:"/a",goal:"Improve signup",question:"Faster or clearer?")
    let restored=try JSONDecoder().decode(RobinConversationQuestion.self,from:JSONEncoder().encode(question))
    let next=restored.continuing(with:"the second one")
    XCTAssertTrue(next.contains("Improve signup"));XCTAssertTrue(next.contains("Faster or clearer?"));XCTAssertTrue(next.contains("the second one"))
    let old=Data("{\"role\":\"user\",\"content\":\"old\",\"id\":\"00000000-0000-0000-0000-000000000000\"}".utf8)
    XCTAssertNil(try JSONDecoder().decode(SupervisorMessage.self,from:old).project)
  }
}
