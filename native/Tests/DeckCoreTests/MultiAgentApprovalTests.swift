import XCTest

@testable import DeckCore

final class MultiAgentApprovalTests: XCTestCase {
  private func makeEngine() throws -> DeckEngine {
    try DeckEngine(database: DeckDatabase(path: ":memory:"), codexEvidenceLookup: { _ in .root })
  }

  private func setToolHookApprovals(_ engine: DeckEngine, enabled: Bool) async throws {
    var prefs = DeckPreferences()
    prefs.toolHookApprovals = enabled
    try await engine.updatePreferences(JSONEncoder().encode(prefs))
  }

  func testCodexPermissionRequestCreatesApprovalAndResolves() async throws {
    let engine = try makeEngine()
    let receipt = await engine.ingest(
      agent: "codex",
      event: "PermissionRequest",
      body: [
        "data": [
          "session_id": "codex-1",
          "cwd": "/work/codex-app",
          "tool_name": "Bash",
          "tool_use_id": "tu-1",
          "reason": "Run test suite",
          "tool_input": ["command": "swift test"],
        ],
        "env": ["ppid": 101],
      ],
      decisionChannel: true
    )
    let id = try XCTUnwrap(receipt.requestId)
    let snapshot = await engine.snapshot()
    XCTAssertEqual(snapshot.sessions[receipt.sessionId]?.status, .waiting)
    XCTAssertEqual(snapshot.sessions[receipt.sessionId]?.detail, "Permission requested")
    XCTAssertEqual(snapshot.sessions[receipt.sessionId]?.capabilities.approve, true)

    let request = try XCTUnwrap(snapshot.requests.first { $0.id == id })
    XCTAssertEqual(request.source, "codex-hook")
    XCTAssertEqual(request.title, "Allow Bash?")
    XCTAssertEqual(request.context, "swift test")
    XCTAssertEqual(request.toolUseId, "tu-1")
    XCTAssertEqual(request.choices.map(\.id), ["allow", "deny"])
    XCTAssertTrue(request.choices[0].requiresHold)
    XCTAssertFalse(request.choices[1].requiresHold)

    let waiter = Task { await engine.waitForDecision(id) }
    try await Task.sleep(for: .milliseconds(15))
    let result = await engine.resolve(
      .init(
        action: "respond",
        sessionId: receipt.sessionId,
        requestId: id,
        choiceId: "allow",
        heldMs: 700
      )
    )
    XCTAssertEqual(result.state, "submitted")
    let decision = await waiter.value
    XCTAssertEqual(decision, "allow")
  }

  func testCursorBeforeShellAndBeforeMCPApprovalsFollowPreference() async throws {
    let engine = try makeEngine()

    let nilShell = await engine.ingest(
      agent: "cursor",
      event: "beforeShellExecution",
      body: [
        "data": ["conversation_id": "cur-1", "cwd": "/work/cursor-app", "command": "ls -la"],
        "env": ["ppid": 201],
      ],
      decisionChannel: true
    )
    XCTAssertNil(nilShell.requestId)
    var snapshot = await engine.snapshot()
    XCTAssertEqual(snapshot.sessions[nilShell.sessionId]?.status, .working)
    XCTAssertEqual(snapshot.sessions[nilShell.sessionId]?.capabilities.approve, false)

    try await setToolHookApprovals(engine, enabled: false)
    let falseMCP = await engine.ingest(
      agent: "cursor",
      event: "beforeMCPExecution",
      body: [
        "data": ["conversation_id": "cur-1", "cwd": "/work/cursor-app", "mcp_name": "github"],
        "env": ["ppid": 201],
      ],
      decisionChannel: true
    )
    XCTAssertNil(falseMCP.requestId)
    snapshot = await engine.snapshot()
    XCTAssertEqual(snapshot.sessions[falseMCP.sessionId]?.status, .working)
    XCTAssertEqual(snapshot.sessions[falseMCP.sessionId]?.capabilities.approve, false)

    try await setToolHookApprovals(engine, enabled: true)
    let shellReceipt = await engine.ingest(
      agent: "cursor",
      event: "beforeShellExecution",
      body: [
        "data": ["conversation_id": "cur-2", "cwd": "/work/cursor-app", "command": "npm test"],
        "env": ["ppid": 202],
      ],
      decisionChannel: true
    )
    let shellId = try XCTUnwrap(shellReceipt.requestId)
    snapshot = await engine.snapshot()
    XCTAssertEqual(snapshot.sessions[shellReceipt.sessionId]?.status, .waiting)
    XCTAssertEqual(snapshot.sessions[shellReceipt.sessionId]?.detail, "Permission requested")
    XCTAssertEqual(snapshot.sessions[shellReceipt.sessionId]?.capabilities.approve, true)
    let shellRequest = try XCTUnwrap(snapshot.requests.first { $0.id == shellId })
    XCTAssertEqual(shellRequest.source, "cursor-hook")
    XCTAssertEqual(shellRequest.title, "Allow Shell?")
    XCTAssertEqual(shellRequest.context, "npm test")

    let waiter = Task { await engine.waitForDecision(shellId) }
    try await Task.sleep(for: .milliseconds(15))
    let resolved = await engine.resolve(
      .init(
        action: "respond",
        sessionId: shellReceipt.sessionId,
        requestId: shellId,
        choiceId: "allow",
        heldMs: 700
      )
    )
    XCTAssertEqual(resolved.state, "submitted")
    let shellDecision = await waiter.value
    XCTAssertEqual(shellDecision, "allow")

    let mcpReceipt = await engine.ingest(
      agent: "cursor",
      event: "beforeMCPExecution",
      body: [
        "data": [
          "conversation_id": "cur-3",
          "cwd": "/work/cursor-app",
          "mcp_name": "github",
          "tool_input": ["url": "https://api.github.com/repos"],
        ],
        "env": ["ppid": 203],
      ],
      decisionChannel: true
    )
    let mcpId = try XCTUnwrap(mcpReceipt.requestId)
    snapshot = await engine.snapshot()
    let mcpRequest = try XCTUnwrap(snapshot.requests.first { $0.id == mcpId })
    XCTAssertEqual(mcpRequest.source, "cursor-hook")
    XCTAssertEqual(mcpRequest.title, "Allow github?")
    XCTAssertEqual(mcpRequest.context, "https://api.github.com/repos")

    let fallbackMCPReceipt = await engine.ingest(
      agent: "cursor",
      event: "beforeMCPExecution",
      body: [
        "data": [
          "conversation_id": "cur-4",
          "cwd": "/work/cursor-app",
          "reason": "Call external MCP server",
        ],
        "env": ["ppid": 204],
      ],
      decisionChannel: true
    )
    let fallbackMCPId = try XCTUnwrap(fallbackMCPReceipt.requestId)
    snapshot = await engine.snapshot()
    let fallbackMCPRequest = try XCTUnwrap(snapshot.requests.first { $0.id == fallbackMCPId })
    XCTAssertEqual(fallbackMCPRequest.title, "Allow MCP tool?")
    XCTAssertEqual(fallbackMCPRequest.context, "Call external MCP server")
  }

  func testGeminiBeforeToolApprovalsFollowPreference() async throws {
    let engine = try makeEngine()

    let nilTool = await engine.ingest(
      agent: "gemini",
      event: "BeforeTool",
      body: [
        "data": [
          "session_id": "gem-1",
          "cwd": "/work/gemini-app",
          "tool_name": "write_file",
          "tool_input": ["file_path": "/work/gemini-app/README.md"],
        ],
        "env": ["ppid": 301],
      ],
      decisionChannel: true
    )
    XCTAssertNil(nilTool.requestId)
    var snapshot = await engine.snapshot()
    XCTAssertEqual(snapshot.sessions[nilTool.sessionId]?.status, .working)
    XCTAssertEqual(snapshot.sessions[nilTool.sessionId]?.capabilities.approve, false)

    try await setToolHookApprovals(engine, enabled: false)
    let falseTool = await engine.ingest(
      agent: "gemini",
      event: "BeforeTool",
      body: [
        "data": [
          "session_id": "gem-1",
          "cwd": "/work/gemini-app",
          "tool_name": "list_directory",
          "tool_input": ["dir_path": "/work/gemini-app"],
        ],
        "env": ["ppid": 301],
      ],
      decisionChannel: true
    )
    XCTAssertNil(falseTool.requestId)
    snapshot = await engine.snapshot()
    XCTAssertEqual(snapshot.sessions[falseTool.sessionId]?.status, .working)

    try await setToolHookApprovals(engine, enabled: true)
    let receipt = await engine.ingest(
      agent: "gemini",
      event: "BeforeTool",
      body: [
        "data": [
          "session_id": "gem-2",
          "cwd": "/work/gemini-app",
          "tool_name": "write_file",
          "tool_input": ["file_path": "/work/gemini-app/README.md"],
        ],
        "env": ["ppid": 302],
      ],
      decisionChannel: true
    )
    let id = try XCTUnwrap(receipt.requestId)
    snapshot = await engine.snapshot()
    XCTAssertEqual(snapshot.sessions[receipt.sessionId]?.status, .waiting)
    XCTAssertEqual(snapshot.sessions[receipt.sessionId]?.detail, "Permission requested")
    XCTAssertEqual(snapshot.sessions[receipt.sessionId]?.capabilities.approve, true)
    let request = try XCTUnwrap(snapshot.requests.first { $0.id == id })
    XCTAssertEqual(request.source, "gemini-hook")
    XCTAssertEqual(request.title, "Allow write_file?")
    XCTAssertEqual(request.context, "/work/gemini-app/README.md")

    let waiter = Task { await engine.waitForDecision(id) }
    try await Task.sleep(for: .milliseconds(15))
    let resolved = await engine.resolve(
      .init(
        action: "respond",
        sessionId: receipt.sessionId,
        requestId: id,
        choiceId: "deny"
      )
    )
    XCTAssertEqual(resolved.state, "submitted")
    let decision = await waiter.value
    XCTAssertEqual(decision, "deny")
  }

  func testDeckPreferencesBackwardCompatibility() throws {
    let legacyJSON = Data(
      #"{"pinnedSessionIds":[],"projectNames":{},"mutedProjects":[],"automaticSingleAgent":true,"reduceMotion":false,"notifications":false,"showSensitiveNotifications":false,"enabledAgents":["claude","codex"]}"#
        .utf8)
    let decoded = try JSONDecoder().decode(DeckPreferences.self, from: legacyJSON)
    XCTAssertTrue(decoded.automaticSingleAgent)
    XCTAssertEqual(decoded.enabledAgents, ["claude", "codex"])
    XCTAssertNil(decoded.toolHookApprovals)
  }

  func testHookMetadataFiltered() {
    let payload: [String: Any] = [
      "session_id": "s-1",
      "cwd": "/work/app",
      "tool_name": "BeforeTool",
      "command": "echo hi",
      "file_path": "/work/app/main.swift",
      "reason": "Need to run command",
      "mcp_name": "filesystem",
      "prompt": "secret user prompt",
      "tool_input": [
        "command": "echo hi",
        "file_path": "/work/app/main.swift",
        "path": "/work/app/other.swift",
        "dir_path": "/work/app",
        "url": "https://example.com",
        "server_name": "github",
        "reason": "Input reason",
        "content": "large secret file content",
        "api_key": "should-not-leak",
      ],
    ]

    let statusOnly = HookMetadata.filtered(payload, permissionContext: false)
    XCTAssertEqual(statusOnly["session_id"] as? String, "s-1")
    XCTAssertNil(statusOnly["command"])
    XCTAssertNil(statusOnly["file_path"])
    XCTAssertNil(statusOnly["reason"])
    XCTAssertNil(statusOnly["mcp_name"])
    XCTAssertNil(statusOnly["prompt"])
    XCTAssertNil(statusOnly["tool_input"])

    let withContext = HookMetadata.filtered(payload, permissionContext: true)
    XCTAssertEqual(withContext["command"] as? String, "echo hi")
    XCTAssertEqual(withContext["file_path"] as? String, "/work/app/main.swift")
    XCTAssertEqual(withContext["reason"] as? String, "Need to run command")
    XCTAssertEqual(withContext["mcp_name"] as? String, "filesystem")
    XCTAssertNil(withContext["prompt"])

    let input = withContext["tool_input"] as? [String: Any]
    XCTAssertEqual(input?["command"] as? String, "echo hi")
    XCTAssertEqual(input?["file_path"] as? String, "/work/app/main.swift")
    XCTAssertEqual(input?["path"] as? String, "/work/app/other.swift")
    XCTAssertEqual(input?["dir_path"] as? String, "/work/app")
    XCTAssertEqual(input?["url"] as? String, "https://example.com")
    XCTAssertEqual(input?["server_name"] as? String, "github")
    XCTAssertEqual(input?["reason"] as? String, "Input reason")
    XCTAssertNil(input?["content"])
    XCTAssertNil(input?["api_key"])
  }
}
