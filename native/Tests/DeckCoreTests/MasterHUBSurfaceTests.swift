import XCTest
@testable import DeckCore

final class MasterHUBSurfaceTests: XCTestCase {
  private func fixture(_ count: Int) async throws -> DeckSnapshot {
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"))
    for index in 0..<count {
      let receipt = await engine.ingest(agent: "claude", event: "UserPromptSubmit", body: [
        "data": ["session_id": "session-\(index)", "cwd": "/work/shared"],
        "env": ["bundleId": "com.apple.Terminal", "ppid": 100 + index, "tty": "/dev/ttys\(index)"],
      ])
      await engine.setCapabilities(receipt.sessionId, focus: true, interrupt: true)
    }
    var snapshot = await engine.snapshot()
    for (index, id) in snapshot.sessions.keys.sorted().enumerated() {
      snapshot.sessions[id]?.startedAt = Double(index)
    }
    return snapshot
  }
  func testAllActiveSessionsReachableAndLegacyGridUnaffected() async throws {
    var snapshot = try await fixture(23)
    let archivedID = snapshot.sessions.keys.first!
    snapshot.sessions[archivedID]?.status = .disconnected
    var surface = MasterHUBSurface()
    var targets: [String] = []
    for page in 0..<3 {
      let layout = surface.layout(snapshot: snapshot, configuration: .init())
      XCTAssertEqual(layout.tiles.count, 15)
      XCTAssertEqual(layout.pageCount, 3)
      XCTAssertEqual(layout.pageIndex, page)
      XCTAssertEqual(layout.tiles[10].tile.enabled, page > 0)
      XCTAssertEqual(layout.tiles[14].tile.enabled, page < 2)
      targets += layout.tiles.prefix(10).filter { $0.tile.action == "focus" }.map { $0.tile.target }
      surface.movePage(1)
    }
    XCTAssertEqual(Set(targets).count, 22)
    XCTAssertEqual(targets.count, 22)
    XCTAssertFalse(targets.contains(archivedID))
    XCTAssertEqual(snapshot.tiles.count, 9)
  }
  func testActiveDialSelectionUsesStableSurfaceOrderAndVersions() async throws {
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"))
    for index in 0..<12 {
      _ = await engine.ingest(agent: "claude", event: "UserPromptSubmit", body: [
        "data": ["session_id": "dial-\(index)", "cwd": "/work/dial-\(index)"],
        "env": ["bundleId": "com.apple.Terminal", "ppid": 100 + index, "tty": "/dev/ttys\(index)"],
      ])
    }
    let before = await engine.snapshot()
    let ordered = MasterHUBSurface.orderedSessions(before)
    await engine.setSelection(ordered[0].id)
    await engine.turnActive(11)
    let next = await engine.snapshot()
    XCTAssertEqual(next.selectedSessionId, ordered[11].id)
    XCTAssertGreaterThan(next.stateVersion ?? 0, before.stateVersion ?? 0)
    await engine.turnActive(1)
    let wrapped = await engine.snapshot()
    XCTAssertEqual(wrapped.selectedSessionId, ordered[0].id)
    await engine.turnActive(-1)
    let reversed = await engine.snapshot()
    XCTAssertEqual(reversed.selectedSessionId, ordered[11].id)
    let applied = await engine.turnActive(1, from: ordered[4].id)
    XCTAssertTrue(applied)
    let fromDisplayed = await engine.snapshot()
    XCTAssertEqual(fromDisplayed.selectedSessionId, ordered[5].id)
    let rejected = await engine.turnActive(1, from: "missing-session")
    XCTAssertFalse(rejected)
    let afterRejected = await engine.snapshot()
    XCTAssertEqual(afterRejected.selectedSessionId, fromDisplayed.selectedSessionId)
    XCTAssertEqual(afterRejected.stateVersion, fromDisplayed.stateVersion)
  }
  func testSelectionRevealsAgentBeyondFirstPage() async throws {
    var snapshot = try await fixture(23)
    let ordered = MasterHUBSurface.orderedSessions(snapshot)
    snapshot.selectedSessionId = ordered[21].id
    var surface = MasterHUBSurface()
    surface.revealSelection(in: snapshot)
    let layout = surface.layout(snapshot: snapshot, configuration: .init())
    XCTAssertEqual(layout.pageIndex, 2)
    XCTAssertEqual(layout.tiles[1].tile.target, snapshot.selectedSessionId)
  }
  func testStableOrderPinsAndDistinctSameProjectInstances() async throws {
    var snapshot = try await fixture(4)
    var surface = MasterHUBSurface()
    let first = surface.layout(snapshot: snapshot, configuration: .init())
    let ids = first.tiles.prefix(4).map { $0.tile.target }
    snapshot.sessions[ids[3]]?.status = .waiting
    let updated = surface.layout(snapshot: snapshot, configuration: .init())
    XCTAssertEqual(updated.tiles.prefix(4).map { $0.tile.target }, ids)
    XCTAssertEqual(Set(updated.tiles.prefix(4).map { $0.tile.sublabel }).count, 4)
    snapshot.preferences.pinnedSessionIds = [ids[3]]
    XCTAssertEqual(surface.layout(snapshot: snapshot, configuration: .init()).tiles.first?.tile.target, ids[3])
    snapshot.preferences.automaticSingleAgent = true
    XCTAssertEqual(surface.layout(snapshot: snapshot, configuration: .init()).page, .agents)
  }
  func testUnchangedFocusTargetSurvivesBackgroundStatusButNeverRetargets() async throws {
    var snapshot = try await fixture(2)
    var surface = MasterHUBSurface()
    let before = surface.layout(snapshot: snapshot, configuration: .init())
    let target = before.tiles[0].tile.target
    snapshot.sessions[target]?.status = .waiting
    let changedStatus = surface.layout(snapshot: snapshot, configuration: .init())
    XCTAssertNotEqual(before.revision, changedStatus.revision)
    XCTAssertNotNil(MasterHUBSurface.validatePress(before, current: changedStatus, index: 0, heldMs: 0))
    snapshot.sessions[target]?.status = .disconnected
    let changedTarget = surface.layout(snapshot: snapshot, configuration: .init())
    XCTAssertNil(MasterHUBSurface.validatePress(before, current: changedTarget, index: 0, heldMs: 0))
  }
  func testStableRevisionAndChangedBindingOrServiceRejectsOldPress() async throws {
    let snapshot = try await fixture(1)
    var surface = MasterHUBSurface(); surface.navigate(.mac)
    var configuration = MasterHUBConfiguration()
    let before = surface.layout(snapshot: snapshot, configuration: configuration)
    let same = surface.layout(snapshot: snapshot, configuration: configuration)
    XCTAssertEqual(before.revision, same.revision)
    XCTAssertNotNil(MasterHUBSurface.validatePress(before, current: same, index: 0, heldMs: 0))
    configuration.macKeys[0].kind = .mute // Same label, different action must invalidate a captured press.
    let changed = surface.layout(snapshot: snapshot, configuration: configuration)
    XCTAssertNil(MasterHUBSurface.validatePress(before, current: changed, index: 0, heldMs: 0))
    var restarted = snapshot; restarted.instanceId = "new-service"
    let newService = surface.layout(snapshot: restarted, configuration: configuration)
    XCTAssertNil(MasterHUBSurface.validatePress(changed, current: newService, index: 0, heldMs: 0))
    XCTAssertNil(MasterHUBSurface.validatePress(newService, current: newService, index: -1, heldMs: 0))
    XCTAssertNil(MasterHUBSurface.validatePress(newService, current: newService, index: 15, heldMs: 0))
  }
  func testAttentionAndActionsKeepExactRequestAndRequireHold() async throws {
    var snapshot = try await fixture(2)
    let ids = snapshot.sessions.keys.sorted()
    let first = PendingRequest(id: "request-one", sessionId: ids[0], title: "First command", context: "First context",
      choices: [.init(id: "allow", label: "Allow", requiresHold: true)], createdAt: 1,
      expiresAt: DeckClock.now + 10000, state: "pending", revision: 1, source: "test")
    var second = first; second.id = "request-two"; second.title = "Second command"; second.createdAt = 2
    snapshot.requests = [second, first]
    var surface = MasterHUBSurface(); surface.navigate(.attention)
    let attention = surface.layout(snapshot: snapshot, configuration: .init())
    XCTAssertEqual(attention.tiles[0].tile.requestId, first.id)
    surface.navigate(.actions, sessionID: ids[0], requestID: second.id)
    let actions = surface.layout(snapshot: snapshot, configuration: .init())
    let index = try XCTUnwrap(actions.tiles.firstIndex { $0.tile.action == "respond" })
    XCTAssertEqual(actions.tiles[index].tile.requestId, second.id)
    XCTAssertEqual(actions.tiles[index].tile.target, ids[0])
    XCTAssertNil(MasterHUBSurface.validatePress(actions, current: actions, index: index, heldMs: 699))
    XCTAssertNotNil(MasterHUBSurface.validatePress(actions, current: actions, index: index, heldMs: 700))
    snapshot.requests[0].state = "expired"
    let expired = surface.layout(snapshot: snapshot, configuration: .init())
    XCTAssertNil(MasterHUBSurface.validatePress(actions, current: expired, index: index, heldMs: 700))
    XCTAssertFalse(expired.tiles.contains { $0.tile.action == "respond" }, "An expired request must not become another pending request")
    XCTAssertNil(expired.selectedRequestID)
    snapshot.sessions[ids[0]]?.status = .disconnected
    let disconnected = surface.layout(snapshot: snapshot, configuration: .init())
    XCTAssertEqual(disconnected.selectedSessionID, "", "An explicit action context must not jump to another agent")
    XCTAssertFalse(disconnected.tiles.contains { ["respond", "stop", "focus"].contains($0.tile.action) && $0.tile.enabled })
  }
  func testAllRequestChoicesReachableWithoutLosingExactContext() async throws {
    var snapshot = try await fixture(1)
    let sessionID = try XCTUnwrap(snapshot.sessions.keys.first)
    let choices = (0..<19).map { RequestChoice(id: "choice-\($0)", label: "Choice \($0)", requiresHold: true) }
    snapshot.requests = [.init(id: "many-choices", sessionId: sessionID, title: "Choose one", context: "Exact context",
      choices: choices, createdAt: 1, expiresAt: DeckClock.now + 10000, state: "pending", revision: 1, source: "test")]
    var surface = MasterHUBSurface()
    surface.navigate(.actions, sessionID: sessionID, requestID: "many-choices")
    var reached: [String] = []
    for page in 0..<3 {
      let layout = surface.layout(snapshot: snapshot, configuration: .init())
      XCTAssertEqual(layout.pageIndex, page)
      XCTAssertEqual(layout.pageCount, 3)
      XCTAssertEqual(layout.selectedRequestID, "many-choices")
      let responses = layout.tiles.filter { $0.tile.action == "respond" }
      XCTAssertTrue(responses.allSatisfy { $0.tile.requestId == "many-choices" && $0.tile.target == sessionID })
      reached += responses.map { $0.tile.choiceId }
      surface.movePage(1)
    }
    XCTAssertEqual(reached, choices.map(\.id))
  }
  func testDefaultDeckShowsBusyRootsAndIdleIsExplicitOptIn() async throws {
    var snapshot = try await fixture(3)
    let ids = snapshot.sessions.keys.sorted()
    snapshot.sessions[ids[0]]?.status = .working
    snapshot.sessions[ids[1]]?.status = .idle
    snapshot.sessions[ids[2]]?.status = .done
    XCTAssertEqual(MasterHUBSurface.orderedSessions(snapshot).map(\.id), [ids[0]])
    snapshot.preferences.showIdleSessions = true
    XCTAssertEqual(MasterHUBSurface.orderedSessions(snapshot).count, 3)
    snapshot.sessions[ids[2]]?.status = .unknown
    XCTAssertEqual(MasterHUBSurface.orderedSessions(snapshot).count, 2)
  }
  func testMediaPlaybackStateDoesNotCancelSameToggleAction() {
    var surface = MasterHUBSurface(); surface.navigate(.media)
    var media = NowPlaying()
    let before = surface.layout(snapshot: nil, configuration: .init(), media: media)
    media.playing = true
    let playing = surface.layout(snapshot: nil, configuration: .init(), media: media)
    XCTAssertNotEqual(before.revision, playing.revision)
    XCTAssertNotNil(MasterHUBSurface.validatePress(before, current: playing, index: 1, heldMs: 0))
    surface.navigate(.tools)
    let changedPage = surface.layout(snapshot: nil, configuration: .init())
    XCTAssertNil(MasterHUBSurface.validatePress(before, current: changedPage, index: 1, heldMs: 0))
  }
  func testMediaAndToolsRemainAvailableWithoutAgentService() {
    var surface = MasterHUBSurface()
    surface.navigate(.media)
    let media = surface.layout(snapshot: nil, configuration: .init())
    XCTAssertEqual(media.tiles.count, 15)
    XCTAssertEqual(media.tiles.prefix(10).filter { $0.tile.enabled }.count, 10)
    XCTAssertEqual(media.tiles[1].tile.target, "playpause")
    XCTAssertEqual(media.tiles[13].tile.action, "hub.toolsPage")
    surface.navigate(.tools)
    let tools = surface.layout(snapshot: nil, configuration: .init())
    XCTAssertEqual(tools.tiles.prefix(10).compactMap(\.binding).count, 10)
    XCTAssertTrue(tools.tiles.prefix(10).allSatisfy { $0.tile.enabled && $0.binding?.valid == true })
    XCTAssertEqual(tools.tiles[13].tile.action, "hub.agents")
  }
  func testMacControlsAvailableOfflineAndAllOrientationsAreBijective() {
    var surface = MasterHUBSurface(); surface.navigate(.mac)
    let configuration = MasterHUBConfiguration()
    let offline = surface.layout(snapshot: nil, configuration: configuration)
    XCTAssertEqual(offline.tiles.prefix(10).filter { $0.binding != nil && $0.tile.enabled }.count, 10)
    for rotation in 0..<4 {
      let wires = (0..<15).compactMap { MasterHUBGeometry.wireIndex(logical: $0, rotation: rotation) }
      XCTAssertEqual(Set(wires), Set(0..<15))
      for logical in 0..<15 {
        XCTAssertEqual(MasterHUBGeometry.logicalIndex(wire: wires[logical], rotation: rotation), logical)
      }
    }
    XCTAssertNil(MasterHUBGeometry.wireIndex(logical: 0, rotation: 4))
  }
  func testLegacyMigrationPreservesAllSixBindingsAndRotaries() throws {
    let bindings: [[String: Any]] = (0..<6).map { index in
      ["label": "My shortcut \(index)", "action": "shortcut", "appPath": "", "keyCode": index, "modifiers": 1 << 20]
    }
    let oldKeys = try JSONSerialization.data(withJSONObject: ["version": 1, "bindings": bindings])
    var rotary = MasterHUBRotaryControls(); rotary.bindings[0].reversed = true
    let configuration = MasterHUBConfiguration.migrating(legacyKeys: oldKeys,
      legacyRotaries: try JSONEncoder().encode(rotary))
    XCTAssertTrue(configuration.valid)
    for index in 0..<6 { XCTAssertEqual(configuration.macKeys[index].label, "My shortcut \(index)") }
    XCTAssertEqual(configuration.rotaries, rotary)
    XCTAssertEqual(try JSONDecoder().decode(MasterHUBConfiguration.self, from: JSONEncoder().encode(configuration)), configuration)
  }
}
