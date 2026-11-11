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
    let events = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop", "SessionEnd"]
    let hooks = Dictionary(uniqueKeysWithValues: events.map { event in
      (event, [["hooks": [["command": "\"\(hook)\" codex \(event)"]]]])
    })
    let text = String(data: try JSONSerialization.data(withJSONObject: ["hooks": hooks]), encoding: .utf8)!
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "codex", text: text, hookPath: hook), .ready)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "codex", text: text.replacingOccurrences(of: "codex ", with: "claude "), hookPath: hook), .missing)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "codex", text: text.replacingOccurrences(of: "codex Stop", with: "codex Stopper"), hookPath: hook), .missing)
  }

  func testCursorHooksRequireExactEventsAndAgent() throws {
    let noSpaceHook = "/usr/local/bin/deck-hook"
    let requiredEvents = ["beforeSubmitPrompt", "beforeShellExecution", "beforeMCPExecution", "stop"]
    let quoted = Dictionary(uniqueKeysWithValues: requiredEvents.map { event in
      (event, [["command": "\"\(hook)\" cursor \(event)"]])
    })
    let quotedText = String(data: try JSONSerialization.data(withJSONObject: ["hooks": quoted]), encoding: .utf8)!
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "cursor", text: quotedText, hookPath: hook), .ready)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "cursor", text: quotedText.replacingOccurrences(of: "cursor ", with: "claude "), hookPath: hook), .missing)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "cursor", text: quotedText.replacingOccurrences(of: "cursor stop", with: "cursor stopped"), hookPath: hook), .missing)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "cursor", text: quotedText.replacingOccurrences(of: "\"stop\"", with: "\"afterFileEdit\""), hookPath: hook), .missing)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "cursor", text: quotedText.replacingOccurrences(of: "\"beforeSubmitPrompt\"", with: "\"afterFileEdit\""), hookPath: hook), .missing)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "cursor", text: quotedText.replacingOccurrences(of: "\"beforeShellExecution\"", with: "\"afterFileEdit\""), hookPath: hook), .missing)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "cursor", text: quotedText.replacingOccurrences(of: "\"beforeMCPExecution\"", with: "\"afterFileEdit\""), hookPath: hook), .missing)

    let unquoted = Dictionary(uniqueKeysWithValues: requiredEvents.map { event in
      (event, [["command": "\(noSpaceHook) cursor \(event)"]])
    })
    let unquotedText = String(data: try JSONSerialization.data(withJSONObject: ["hooks": unquoted]), encoding: .utf8)!
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "cursor", text: unquotedText, hookPath: noSpaceHook), .ready)

    let unquotedWithSpaces = Dictionary(uniqueKeysWithValues: requiredEvents.map { event in
      (event, [["command": "\(hook) cursor \(event)"]])
    })
    let unquotedSpacesText = String(data: try JSONSerialization.data(withJSONObject: ["hooks": unquotedWithSpaces]), encoding: .utf8)!
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "cursor", text: unquotedSpacesText, hookPath: hook), .missing)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "cursor", text: nil, hookPath: hook), .missing)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "cursor", text: "{broken", hookPath: hook), .invalid)
  }

  func testGeminiHooksRequireExactEventsAndAgent() throws {
    let events = ["SessionStart", "BeforeTool", "AfterAgent"]
    let hooks = Dictionary(uniqueKeysWithValues: events.map { event in
      (event, [["hooks": [["command": "\"\(hook)\" gemini \(event)"]]]])
    })
    let text = String(data: try JSONSerialization.data(withJSONObject: ["hooks": hooks]), encoding: .utf8)!
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "gemini", text: text, hookPath: hook), .ready)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "gemini", text: text.replacingOccurrences(of: "gemini ", with: "cursor "), hookPath: hook), .missing)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "gemini", text: text.replacingOccurrences(of: "gemini AfterAgent", with: "gemini AfterAgentDone"), hookPath: hook), .missing)
    for event in events {
      XCTAssertEqual(IntegrationReadiness.configuration(agent: "gemini", text: text.replacingOccurrences(of: "\"\(event)\"", with: "\"Other\""), hookPath: hook), .missing)
    }

    let noSpaceHook = "/usr/local/bin/deck-hook"
    let unquoted = Dictionary(uniqueKeysWithValues: events.map { event in
      (event, [["hooks": [["command": "\(noSpaceHook) gemini \(event)"]]]])
    })
    let unquotedText = String(data: try JSONSerialization.data(withJSONObject: ["hooks": unquoted]), encoding: .utf8)!
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "gemini", text: unquotedText, hookPath: noSpaceHook), .ready)
    XCTAssertEqual(IntegrationReadiness.configuration(agent: "gemini", text: unquotedText, hookPath: hook), .missing)
  }

  func testConfigurationStateLabels() {
    XCTAssertEqual(IntegrationConfigurationState.ready.label, "Hooks installed")
    XCTAssertEqual(IntegrationConfigurationState.missing.label, "Setup needed")
    XCTAssertEqual(IntegrationConfigurationState.invalid.label, "Check configuration")
    XCTAssertEqual(IntegrationConfigurationState.externalNotify.label, "Existing notify preserved")
    XCTAssertEqual(IntegrationConfigurationState.unsupported.label, "Experimental")
  }
}
