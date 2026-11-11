import XCTest
@testable import DeckCore

final class SubscriptionTaskTests: XCTestCase {
  func testGeminiUsesExactAntigravityResumeWithoutPermissionBypass() {
    XCTAssertEqual(SupervisedProvider.gemini.executableNames, ["agy"])
    let args = SupervisedProvider.gemini.arguments(session: "exact-session", prompt: "Run tests")
    XCTAssertEqual(args, ["--output-format", "stream-json", "--conversation", "exact-session", "--print", "Run tests"])
    XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
    XCTAssertFalse(args.contains("--continue"))
  }

  func testAntigravityResultRequiresExplicitSuccessAndKeepsExactConversation() throws {
    var parsed = SupervisedOutput()
    let events: [[String: Any]] = [
      ["event": "init", "conversation_id": "agy-session"],
      ["event": "step_update", "step_update": ["step_type": "agent_response", "text_delta": "Partial answer"]],
      ["event": "result", "result": ["conversation_id": "agy-session", "status": "SUCCESS", "response": "Tests passed"]]
    ]
    for event in events { parsed.ingest(try JSONSerialization.data(withJSONObject: event), provider: .gemini) }
    XCTAssertEqual(parsed.session, "agy-session")
    XCTAssertEqual(parsed.result, "Tests passed")
    XCTAssertTrue(parsed.completed)
    XCTAssertFalse(parsed.failed)
    var missingStatus = SupervisedOutput()
    missingStatus.ingest(try JSONSerialization.data(withJSONObject: ["event":"result", "result": ["response": "Looks okay"]]), provider: .gemini)
    XCTAssertTrue(missingStatus.failed)
  }

  func testAntigravityToolFailureCannotBeErasedByFinalSuccess() throws {
    var parsed = SupervisedOutput()
    parsed.ingest(try JSONSerialization.data(withJSONObject: ["event": "step_update", "step_update": ["step_type": "tool", "tool_info": ["error": ["message": "permission denied"]]]]), provider: .gemini)
    parsed.ingest(try JSONSerialization.data(withJSONObject: ["event": "result", "result": ["status": "SUCCESS"]]), provider: .gemini)
    XCTAssertTrue(parsed.failed)
    var legacy = SupervisedOutput()
    legacy.ingest(try JSONSerialization.data(withJSONObject: ["type":"result", "status":"success"]), provider: .gemini)
    XCTAssertFalse(legacy.completed)
  }

  func testManagedCodexPolicyRejectsAPIAccountsAndFiltersInheritedCredentials() throws {
    XCTAssertTrue(ManagedSubscriptionPolicy.isChatGPTAccount(["account": ["type": "chatgpt", "planType": "plus"]]))
    for kind in ["apiKey", "amazonBedrock", "chatgptAuthTokens"] {
      XCTAssertFalse(ManagedSubscriptionPolicy.isChatGPTAccount(["account": ["type": kind]]))
    }
    XCTAssertFalse(ManagedSubscriptionPolicy.isChatGPTAccount(["account": NSNull()]))
    let clean = ManagedSubscriptionPolicy.environment(["HOME":"/home/person", "PATH":"/usr/bin", "OPENAI_API_KEY":"secret", "OPENAI_BASE_URL":"https://other.invalid", "AWS_PROFILE":"paid", "NODE_OPTIONS":"injected", "PYTHONPATH":"injected"])
    XCTAssertEqual(clean, ["HOME":"/home/person", "PATH":"/usr/bin"])
    XCTAssertTrue(ManagedSubscriptionPolicy.codexAppServerArguments.contains("forced_login_method=\"chatgpt\""))
    XCTAssertTrue(ManagedSubscriptionPolicy.codexAppServerArguments.contains("model_providers={}"))
    XCTAssertEqual(ManagedSubscriptionPolicy.codexThreadConfiguration["modelProvider"] as? String, "openai")
    XCTAssertEqual(ManagedSubscriptionPolicy.codexThreadConfiguration["approvalPolicy"] as? String, "on-request")
    XCTAssertEqual(ManagedSubscriptionPolicy.codexThreadConfiguration["sandbox"] as? String, "workspace-write")
  }

  func testSavedSubscriptionTaskPolicyIsBackwardCompatibleAndFailsClosedOnCorruption() throws {
    XCTAssertFalse(ManagedSubscriptionPolicy.enabled(configurationData: nil))
    XCTAssertFalse(ManagedSubscriptionPolicy.enabled(configurationData: try JSONEncoder().encode(SupervisorConfiguration())))
    var value = SupervisorConfiguration(); value.robinSubscriptionOnly = true
    XCTAssertTrue(ManagedSubscriptionPolicy.enabled(configurationData: try JSONEncoder().encode(value)))
    XCTAssertTrue(ManagedSubscriptionPolicy.enabled(configurationData: Data("corrupt".utf8)))
  }
}
