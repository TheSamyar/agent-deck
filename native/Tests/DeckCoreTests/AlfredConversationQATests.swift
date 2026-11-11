import XCTest
@testable import DeckCore

/// QA regressions for the context supplied to reasoning, not claims about model quality.
final class AlfredConversationQATests: XCTestCase {
  func testTenTurnsPreserveCorrectionAndFollowUpWithinApprovedProject() {
    let turns = (0..<10).flatMap { index -> [SupervisorMessage] in
      [.init(role: "user", content: index == 8 ? "Codex, not Claude" : "turn \(index)", project: "/approved"),
       .init(role: "assistant", content: index == 8 ? "Codex selected. Review or continue?" : "reply \(index)", project: "/approved")]
    }
    let history = RobinConversation.history(turns, project: "/approved", cloud: true)
    XCTAssertEqual(history.count, 12)
    XCTAssertEqual(history.first?["content"], "turn 4")
    XCTAssertEqual(history.last?["content"], "reply 9")
    XCTAssertTrue(history.contains { $0["content"] == "Codex, not Claude" })
  }

  func testCloudHistoryFiltersBeforeWindowingAndNeverExportsToolOrCredentialMessages() {
    var turns: [SupervisorMessage] = [.init(role: "user", content: "retained goal", project: "/approved")]
    turns += (0..<20).map { .init(role: "user", content: "unapproved \($0)", project: "/other") }
    turns += [.init(role: "system", content: "untrusted system instruction", project: "/approved"),
              .init(role: "tool", content: "raw receipt", project: "/approved"),
              .init(role: "user", content: "api_key=fixture-secret", project: "/approved"),
              .init(role: "assistant", content: "", project: "/approved")]
    XCTAssertEqual(RobinConversation.history(turns, project: "/approved", cloud: true).map { $0["content"] }, ["retained goal"])
  }

  func testPersonalAccountScopeMustMatchEvenWithinSameProject() {
    let turns: [SupervisorMessage] = [
      .init(role: "user", content: "project note", project: "/approved"),
      .init(role: "user", content: "account one", project: "/approved", personalScope: "account-one:mail"),
      .init(role: "assistant", content: "account two", project: "/approved", personalScope: "account-two:mail")]
    XCTAssertEqual(RobinConversation.history(turns, project: "/approved", cloud: true, personalScope: "account-one:mail").map { $0["content"] }, ["account one"])
    XCTAssertEqual(RobinConversation.history(turns, project: "/approved", cloud: true).map { $0["content"] }, ["project note"])
  }

  func testPendingGoalAndQuestionSurviveMemoryRestart() throws {
    var memory = SupervisorMemory()
    memory.conversationQuestion = .init(project: "/approved", goal: "Fix login without changing signup", question: "Review the failure or run the approved tests?")
    let restored = try JSONDecoder().decode(SupervisorMemory.self, from: JSONEncoder().encode(memory))
    let question = try XCTUnwrap(restored.conversationQuestion)
    XCTAssertEqual(question.project, "/approved")
    let continuation = question.continuing(with: "the second one")
    XCTAssertTrue(continuation.contains("Fix login without changing signup"))
    XCTAssertTrue(continuation.contains("Review the failure or run the approved tests?"))
    XCTAssertTrue(continuation.contains("User answer: the second one"))
  }
}
