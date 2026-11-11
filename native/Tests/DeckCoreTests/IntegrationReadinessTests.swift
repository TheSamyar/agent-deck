import XCTest
@testable import DeckCore

final class IntegrationReadinessTests: XCTestCase {
  private let hook = "/Applications/Agent Deck.app/Contents/MacOS/deck-hook"
  func testPartialAndMalformedHooksAreNotReady() {
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "claude", text: nil, hookPath: hook), .missing)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "claude", text: "{broken", hookPath: hook), .invalid)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "claude", text: "{\"hooks\":[]}", hookPath: hook), .invalid)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "claude", text: "{}", hookPath: hook), .missing)
  }
  func testNativeHooksAreRecognizedWithoutAcceptingAnUnrelatedCommand() throws {
    let hooks = Dictionary(uniqueKeysWithValues: ["SessionStart", "PermissionRequest", "Stop"].map { event in
      (event, [["hooks": [["command": "\"\(hook)\" claude \(event)"]]]])
    })
    let text = String(data: try JSONSerialization.data(withJSONObject: ["hooks": hooks]), encoding: .utf8)!
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "claude", text: text, hookPath: hook), .ready)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "claude", text: text.replacingOccurrences(of: "SessionStart", with: "Other"), hookPath: hook), .missing)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "claude", text: text.replacingOccurrences(of: "command", with: "description"), hookPath: hook), .missing)
  }
  func testCodexExternalNotifyIsPreservedAndNotCalledInstalled() throws {
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "codex", text: "notify = [\"other-tool\"]", hookPath: hook), .externalNotify)
    let argv = String(data: try JSONSerialization.data(withJSONObject: [hook, "codex", "turn-ended"]), encoding: .utf8)!
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "codex", text: "notify = \(argv)", hookPath: hook), .ready)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "codex", text: "notify = [\n", hookPath: hook), .invalid)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "antigravity", text: "{}", hookPath: hook), .unsupported)
  }
  func testCodexRequiresAnExactRootNotifyAndCompleteCommand() throws {
    let argv = String(data: try JSONSerialization.data(withJSONObject: [hook, "codex", "turn-ended"]), encoding: .utf8)!
    for text in ["notify_extra = \(argv)", "[profiles.test]\nnotify = \(argv)", "# notify = \(argv)"] {
      XCTAssertEqual(IntegrationReadiness.configuration(agent: "codex", text: text, hookPath: hook), .missing)
    }
    let incomplete = String(data: try JSONSerialization.data(withJSONObject: [hook]), encoding: .utf8)!
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "codex", text: "notify = \(incomplete)", hookPath: hook), .externalNotify)
  }
  func testUnquotedExecutableWithSpacesIsNotReady() throws {
    let entry: [String: Any] = ["hooks": [["command": "\(hook) claude event"]]]
    let hooks = Dictionary(uniqueKeysWithValues: ["SessionStart", "PermissionRequest", "Stop"].map { ($0, [entry]) })
    let text = String(data: try JSONSerialization.data(withJSONObject: ["hooks": hooks]), encoding: .utf8)!
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "claude", text: text, hookPath: hook), .missing)
  }

  func testCodexLifecycleRequiresNativeAgentAndExactEvents() throws {
    let events = ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"]
    let hooks = Dictionary(uniqueKeysWithValues: events.map { event in
      (event, [["hooks": [["command": "\"\(hook)\" codex \(event)"]]]])
    })
    let text = String(data: try JSONSerialization.data(withJSONObject: ["hooks": hooks]), encoding: .utf8)!
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "codex", text: text, hookPath: hook), .ready)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "codex", text: text.replacingOccurrences(of: "codex ", with: "claude "), hookPath: hook), .missing)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "codex", text: text.replacingOccurrences(of: "codex Stop", with: "codex Stopper"), hookPath: hook), .missing)
  }

}
