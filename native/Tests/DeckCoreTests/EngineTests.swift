import XCTest

@testable import DeckCore

final class EngineTests: XCTestCase {
  func testStableGridIsDefault() {
    XCTAssertFalse(DeckPreferences().automaticSingleAgent)
  }
  func testArtworkWrapPreservesShortNamesAndBoundsLongNames() {
    XCTAssertEqual(TileArtwork.wrap("Agent Deck"), ["Agent Deck", ""])
    let lines = TileArtwork.wrap(String(repeating: "W", count: 80))
    XCTAssertEqual(lines.count, 2)
    XCTAssertTrue(lines[1].hasSuffix("…"))
    XCTAssertLessThan(lines.joined().count, 25)
    XCTAssertEqual(TileArtwork.wrap(""), ["", ""])
  }
  func engine() throws -> DeckEngine { try DeckEngine(database: DeckDatabase(path: ":memory:")) }
  func body(_ provider: String, cwd: String = "/work/shared", pid: Int = 42) -> [String: Any] {
    [
      "data": [
        "session_id": provider, "cwd": cwd, "tool_name": "Bash",
        "tool_input": ["command": "printf test"],
      ], "env": ["bundleId": MacControl.cursorBundle, "ppid": pid],
    ]
  }
  func testSeparateSessionsInSameProject() async throws {
    let engine = try engine()
    let first = await engine.ingest(agent: "claude", event: "SessionStart", body: body("first"))
    let second = await engine.ingest(agent: "claude", event: "SessionStart", body: body("second"))
    XCTAssertNotEqual(first.sessionId, second.sessionId)
    let snapshot = await engine.snapshot()
    XCTAssertEqual(snapshot.sessionCount, 2)
    XCTAssertEqual(Set(snapshot.sessions.values.map(\.workspace)), ["shared"])
  }
  func testFullPathsAndLongNamesDoNotCollide() {
    let a = SessionSnapshot.identity(
      agent: "claude", providerID: "", cwd: "/a/abcdefghijklmnop-project", host: "host", pid: 1)
    let b = SessionSnapshot.identity(
      agent: "claude", providerID: "", cwd: "/b/abcdefghijklmnop-project", host: "host", pid: 1)
    XCTAssertNotEqual(a, b)
    XCTAssertNotEqual(
      a,
      SessionSnapshot.identity(
        agent: "claude", providerID: "", cwd: "/a/abcdefghijklmnop-project", host: "host", pid: 2))
  }
  func testApprovalIsBoundToExactRequestAndDeliveredOnce() async throws {
    let engine = try engine()
    let receipt = await engine.ingest(
      agent: "claude", event: "PermissionRequest", body: body("first"), decisionChannel: true)
    let other = await engine.ingest(
      agent: "claude", event: "PermissionRequest", body: body("second"), decisionChannel: true)
    let id = try XCTUnwrap(receipt.requestId)
    let waiter = Task { await engine.waitForDecision(id) }
    try await Task.sleep(for: .milliseconds(20))
    let wrong = await engine.resolve(
      .init(
        action: "respond", sessionId: other.sessionId, requestId: id, choiceId: "allow", heldMs: 700
      ))
    XCTAssertFalse(wrong.ok)
    let tap = await engine.resolve(
      .init(action: "respond", sessionId: receipt.sessionId, requestId: id, choiceId: "allow"))
    XCTAssertFalse(tap.ok)
    let command = ActionCommand(
      action: "respond", sessionId: receipt.sessionId, requestId: id, choiceId: "allow", heldMs: 700
    )
    let sent = await engine.resolve(command)
    XCTAssertEqual(sent.state, "submitted")
    let decision = await waiter.value
    XCTAssertEqual(decision, "allow")
    let duplicate = await engine.resolve(command)
    XCTAssertEqual(duplicate, sent)
    let again = await engine.resolve(
      .init(
        action: "respond", sessionId: receipt.sessionId, requestId: id, choiceId: "allow",
        heldMs: 700))
    XCTAssertFalse(again.ok)
    await engine.cancelRequest(other.requestId!)
  }
  func testCancelledHookCannotBeApproved() async throws {
    let engine = try engine()
    let receipt = await engine.ingest(
      agent: "claude", event: "PermissionRequest", body: body("first"), decisionChannel: true)
    let id = try XCTUnwrap(receipt.requestId)
    let waiter = Task { await engine.waitForDecision(id) }
    try await Task.sleep(for: .milliseconds(10))
    await engine.cancelRequest(id)
    let decision = await waiter.value
    XCTAssertNil(decision)
    let result = await engine.resolve(
      .init(
        action: "respond", sessionId: receipt.sessionId, requestId: id, choiceId: "allow",
        heldMs: 700))
    XCTAssertFalse(result.ok)
  }
  func testAllSessionsAreReachableWithoutReorderingOnStatus() async throws {
    let engine = try engine()
    for i in 0..<14 {
      _ = await engine.ingest(
        agent: "claude", event: "SessionStart", body: body("s\(i)", cwd: "/work/p\(i)"))
    }
    let first = await engine.snapshot()
    XCTAssertEqual(first.pageCount, 3)
    let initial = first.tiles.prefix(6).map(\.target)
    _ = await engine.ingest(
      agent: "claude", event: "PostToolUse", body: body("s5", cwd: "/work/p5"))
    _ = await engine.navigate("overview")
    let after = await engine.snapshot()
    XCTAssertEqual(initial, after.tiles.prefix(6).map(\.target))
    _ = await engine.navigate("next")
    let second = await engine.snapshot()
    XCTAssertEqual(second.page, 1)
    XCTAssertTrue(Set(initial).isDisjoint(with: second.tiles.prefix(6).map(\.target)))
  }
  func testRestartDoesNotResurrectApprovals() async throws {
    let db = try DeckDatabase(path: ":memory:")
    let first = DeckEngine(database: db)
    _ = await first.ingest(
      agent: "claude", event: "PermissionRequest", body: body("first"), decisionChannel: true)
    let restored = DeckEngine(database: db)
    let snapshot = await restored.snapshot()
    XCTAssertTrue(snapshot.requests.isEmpty)
    XCTAssertEqual(snapshot.sessions.values.first?.status, .disconnected)
    XCTAssertEqual(snapshot.sessions.values.first?.capabilities.approve, false)
  }
  func testArtworkEscapesUserInputAndHasNoIdleAnimation() {
    let tile = TileSnapshot(key: "0", label: "<project>&", sublabel: "CLAUDE", detail: "Idle")
    let svg = TileArtwork.render(tile)
    XCTAssertTrue(svg.contains("&lt;project&gt;&amp;"))
    XCTAssertFalse(svg.contains("<animate"))
  }
  func testCursorWarningDoesNotBecomeWorkspace() {
    XCTAssertEqual(
      workspaceName("2.1.314 — cories — The following extensions want to relaunch the terminal"),
      "cories")
  }
  func testLegacyWaitingSessionRemainsVisibleWithoutUnsafeApproval() async throws {
    let engine = try engine()
    let legacy: [String: Any] = [
      "sessions": [
        "old": [
          "agentId": "claude", "status": "WAITING", "cwd": "/work/legacy", "pid": 42,
          "bundleId": MacControl.cursorBundle,
        ]
      ]
    ]
    await engine.migrateLegacy(try JSONSerialization.data(withJSONObject: legacy))
    _ = await engine.navigate("attention")
    let snapshot = await engine.snapshot()
    XCTAssertEqual(snapshot.summary.waitingCount, 1)
    XCTAssertTrue(snapshot.requests.isEmpty)
    XCTAssertEqual(snapshot.tiles[0].action, "focus")
    XCTAssertEqual(snapshot.tiles[7].sublabel, "1 WAITING")
    XCTAssertFalse(snapshot.sessions.values.first!.capabilities.approve)
  }
  func testIdleStateVersionDoesNotChangeWhenHealthScanFindsSameWindows() async throws {
    let engine = try engine()
    await engine.synchronizeCursorWindows(["Editor — project"])
    let version = await engine.version()
    await engine.synchronizeCursorWindows(["Editor — project"])
    let after = await engine.version()
    XCTAssertEqual(version, after)
  }

  func testObservedProcessRestoresFocusWithoutRestoringApproval() async throws {
    let db = try DeckDatabase(path: ":memory:")
    let first = DeckEngine(database: db)
    let receipt = await first.ingest(
      agent: "claude", event: "PermissionRequest", body: body("restore"), decisionChannel: true)
    let restored = DeckEngine(database: db)
    await restored.observeRunningProcess(receipt.sessionId)
    await restored.setCapabilities(receipt.sessionId, focus: true, interrupt: false)
    let snapshot = await restored.snapshot()
    XCTAssertEqual(snapshot.sessions[receipt.sessionId]?.status, .unknown)
    XCTAssertEqual(snapshot.sessions[receipt.sessionId]?.capabilities.focus, true)
    XCTAssertEqual(snapshot.sessions[receipt.sessionId]?.capabilities.approve, false)
    XCTAssertTrue(snapshot.requests.isEmpty)
  }

  func testOtherToolCannotAcknowledgePermissionResponse() async throws {
    let engine = try engine()
    var requestBody = body("correlation")
    var data = requestBody["data"] as! [String: Any]
    data["tool_use_id"] = "tool-a"
    requestBody["data"] = data
    let receipt = await engine.ingest(
      agent: "claude", event: "PermissionRequest", body: requestBody, decisionChannel: true)
    let id = receipt.requestId!
    let waiter = Task { await engine.waitForDecision(id) }
    try await Task.sleep(for: .milliseconds(10))
    _ = await engine.resolve(
      .init(
        action: "respond", sessionId: receipt.sessionId, requestId: id, choiceId: "allow",
        heldMs: 700))
    _ = await waiter.value
    data["tool_use_id"] = "tool-b"
    requestBody["data"] = data
    _ = await engine.ingest(agent: "claude", event: "PostToolUse", body: requestBody)
    var snapshot = await engine.snapshot()
    XCTAssertFalse(snapshot.recentEvents.contains { $0.outcome == "acknowledged" })
    data["tool_use_id"] = "tool-a"
    requestBody["data"] = data
    _ = await engine.ingest(agent: "claude", event: "PostToolUse", body: requestBody)
    snapshot = await engine.snapshot()
    XCTAssertTrue(snapshot.recentEvents.contains { $0.outcome == "acknowledged" })
  }
  func testParallelRequestKeepsSessionInAttention() async throws {
    let engine = try engine()
    let first = await engine.ingest(
      agent: "claude", event: "PermissionRequest", body: body("parallel"), decisionChannel: true)
    _ = await engine.ingest(agent: "claude", event: "PostToolUse", body: body("parallel"))
    let snapshot = await engine.snapshot()
    XCTAssertEqual(snapshot.sessions[first.sessionId]?.status, .waiting)
    XCTAssertEqual(snapshot.summary.waitingCount, 1)
    await engine.cancelRequest(first.requestId!)
  }

}
