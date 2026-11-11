import XCTest
@testable import DeckCore

final class AlfredReasoningReceiptQATests: XCTestCase {
  func testReceiptPersistsActualProviderAndUsageIdentityOnMessage() throws {
    let usage = UUID()
    let receipt = RobinReasoningReceipt(selectedModelID: "chatgpt", actualModelID: "chatgpt", outcome: .success, durationMilliseconds: 1234, usageRecordID: usage)
    var message = SupervisorMessage(role: "assistant", content: "Evidence checked", project: "/approved")
    message.reasoningReceipts = [receipt]
    let restored = try JSONDecoder().decode(SupervisorMessage.self, from: JSONEncoder().encode(message))
    XCTAssertEqual(restored.reasoningReceipts, [receipt])
    XCTAssertEqual(restored.reasoningReceipts?.first?.usageRecordID, usage)
    XCTAssertTrue(receipt.summary.contains("1.2 s"))
  }

  func testOldMessagesDecodeWithoutInventingProviderEvidence() throws {
    let data = Data(#"{"id":"00000000-0000-0000-0000-000000000000","role":"assistant","content":"old reply","project":"/approved"}"#.utf8)
    let message = try JSONDecoder().decode(SupervisorMessage.self, from: data)
    XCTAssertNil(message.reasoningReceipts)
  }

  func testScriptedAndBlockedResponsesDoNotClaimCodexAnswered() throws {
    let scripted = RobinReasoningReceipt(selectedModelID: "chatgpt", outcome: .scripted)
    XCTAssertEqual(scripted.summary, "Built-in action · no model used")
    for outcome in [RobinReasoningReceipt.Outcome.blocked, .failed, .cancelled] {
      let receipt = RobinReasoningReceipt(selectedModelID: "chatgpt", outcome: outcome)
      XCTAssertNil(receipt.actualModelID)
      XCTAssertFalse(receipt.summary.contains("answered"))
      XCTAssertTrue(receipt.summary.contains(outcome.rawValue))
    }
  }
}
