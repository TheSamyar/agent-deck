import XCTest
@testable import DeckCore
final class AgentHandoffTests: XCTestCase {
  func testOnlyVerifiedOutcomesAppearAndExactSessionIdentitySurvives() async throws {
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"), codexEvidenceLookup: { _ in .root })
    var ids: [String] = []
    for index in 0..<5 {
      let result = await engine.ingest(agent: "claude", event: "UserPromptSubmit", body: ["data": ["session_id": "handoff-\(index)", "cwd": "/work/same-name"], "env": ["ppid": 123]])
      ids.append(result.sessionId)
    }
    var snapshot = await engine.snapshot()
    let states: [SessionState] = [.done, .waiting, .error, .disconnected, .unknown]
    for (index,id) in ids.enumerated() { snapshot.sessions[id]?.status = states[index]; snapshot.sessions[id]?.updatedAt = Double(index) }
    let records = AgentHandoff.records(snapshot)
    XCTAssertEqual(records.count,3)
    XCTAssertEqual(records.map(\.sessionID),[ids[2],ids[1],ids[0]])
    XCTAssertEqual(Set(records.map(\.id)).count,3)
    XCTAssertFalse(records.contains { $0.state == .disconnected || $0.state == .unknown })
    snapshot.handoffs = records
    snapshot.sessions[ids[1]]?.status = .working
    XCTAssertFalse(AgentHandoff.records(snapshot).contains { $0.state == .waiting }, "Resolved input must not remain Needs input in Handoffs")
    snapshot.handoffs = nil; snapshot.sessions[ids[1]]?.status = .waiting
    snapshot.preferences.showIdleSessions = false
    var surface = MasterHUBSurface(); surface.navigate(.handoffs)
    let layout = surface.layout(snapshot: snapshot, configuration: .init())
    XCTAssertEqual(layout.tiles[0].tile.target,ids[2])
    XCTAssertEqual(layout.tiles[2].tile.target,ids[0])
    XCTAssertEqual(layout.tiles.count,15)
    XCTAssertEqual(layout.tiles[0].characterKey,"/work/same-name")
  }
  func testHandoffSurvivesRestartButCannotFocusDeadOwner() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    let database = try DeckDatabase(path: url.path)
    let engine = try DeckEngine(database: database)
    let body: [String:Any] = ["data":["session_id":"durable","cwd":"/work/project"],"env":["ppid":123]]
    let root = await engine.ingest(agent:"claude",event:"UserPromptSubmit",body:body)
    _ = await engine.ingest(agent:"claude",event:"Stop",body:body)
    let before = await engine.snapshot()
    XCTAssertTrue(AgentHandoff.records(before).contains { $0.sessionID == root.sessionId && $0.state == .done })
    let restarted = try DeckEngine(database: database)
    let after = await restarted.snapshot()
    let handoff = AgentHandoff.records(after).first { $0.sessionID == root.sessionId }
    XCTAssertNotNil(handoff)
    XCTAssertEqual(handoff?.canFocus,false)
  }
  func testCompletingRootDoesNotMoveAnotherAgentsKey() async throws {
    let engine = try DeckEngine(database: DeckDatabase(path:":memory:"))
    var ids: [String] = []
    for index in 0..<3 {
      let result = await engine.ingest(agent:"claude",event:"UserPromptSubmit",body:["data":["session_id":"stable-\(index)","cwd":"/work/\(index)"],"env":["ppid":123]])
      ids.append(result.sessionId)
    }
    var snapshot = await engine.snapshot(); snapshot.preferences.showIdleSessions = false
    for (index,id) in ids.enumerated() { snapshot.sessions[id]?.startedAt = Double(index) }
    var surface = MasterHUBSurface()
    let initial = surface.layout(snapshot:snapshot,configuration:.init())
    XCTAssertEqual(initial.tiles[1].tile.target,ids[1])
    snapshot.sessions[ids[0]]?.status = .done
    let completed = surface.layout(snapshot:snapshot,configuration:.init())
    XCTAssertFalse(completed.tiles[0].tile.enabled)
    XCTAssertEqual(completed.tiles[1].tile.target,ids[1])
    XCTAssertEqual(completed.tiles[2].tile.target,ids[2])
    snapshot.sessions[ids[0]]?.status = .working
    let returned = surface.layout(snapshot:snapshot,configuration:.init())
    XCTAssertEqual(returned.tiles[0].tile.target,ids[0])
    XCTAssertEqual(returned.tiles[1].tile.target,ids[1])
  }
}
