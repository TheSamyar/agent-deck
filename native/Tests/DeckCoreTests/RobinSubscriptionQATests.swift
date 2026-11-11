import XCTest
@testable import DeckCore

final class RobinSubscriptionQATests: XCTestCase {
  func testSubscriptionOnlyRejectsEveryAPIRouteAndPreservesLocal() throws {
    for model in RobinModelCatalog.all {
      XCTAssertEqual(RobinModelCatalog.permits(providerID:model.providerID,subscriptionOnly:true), model.providerID == "local" || RobinModelCatalog.subscriptionProviderIDs.contains(model.providerID))
      XCTAssertTrue(RobinModelCatalog.permits(providerID:model.providerID,subscriptionOnly:false))
      if RobinModelCatalog.subscriptionProviderIDs.contains(model.providerID) {
        XCTAssertFalse(model.requiresPaidConsent)
        XCTAssertThrowsError(try RobinProviderCodec.request(model:model,messages:[["role":"user","content":"fixture"]],schema:[:],credential:"fixture"))
      }
    }
    XCTAssertFalse(RobinModelCatalog.permits(providerID:"unknown",subscriptionOnly:true))
    var config = SupervisorConfiguration(); config.robinSubscriptionOnly = true
    XCTAssertEqual(try JSONDecoder().decode(SupervisorConfiguration.self,from:JSONEncoder().encode(config)).robinSubscriptionOnly,true)
  }
  func testSubscriptionInvocationCannotInheritUserProviderOrRules() {
    let args = RobinSubscriptionPolicy.arguments(schema: "/tmp/schema with spaces.json", output: "/tmp/answer.json")
    XCTAssertTrue(args.contains("--ignore-user-config"))
    XCTAssertTrue(args.contains("--ignore-rules"))
    XCTAssertTrue(args.contains("forced_login_method=\"chatgpt\""))
    XCTAssertTrue(args.contains("model_provider=\"openai\""))
    XCTAssertTrue(args.contains("mcp_servers={}"))
    XCTAssertTrue(args.contains("web_search=\"disabled\""))
    XCTAssertEqual(args.last, "-")
    XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
    XCTAssertFalse(args.contains("--full-auto"))
    XCTAssertEqual(args[args.firstIndex(of: "--sandbox")! + 1], "read-only")
    XCTAssertEqual(args[args.firstIndex(of: "--output-schema")! + 1], "/tmp/schema with spaces.json")
  }

  func testToolAttemptIsRejectedEvenBeforeCompletion() {
    for type in ["command_execution", "mcp_tool_call", "web_search", "file_change", "computer_use", "browser_use"] {
      for eventType in ["item.started", "item.updated", "item.completed"] {
        XCTAssertTrue(RobinSubscriptionPolicy.unexpectedToolEvent(["type": eventType, "item": ["type": type]]), "\(eventType) \(type)")
      }
    }
    XCTAssertFalse(RobinSubscriptionPolicy.unexpectedToolEvent(["type": "turn.completed", "usage": ["input_tokens": 10]]))
    XCTAssertFalse(RobinSubscriptionPolicy.unexpectedToolEvent(["type": "item.completed", "item": ["type": "agent_message", "text": "Fixture"]]))
  }
}
