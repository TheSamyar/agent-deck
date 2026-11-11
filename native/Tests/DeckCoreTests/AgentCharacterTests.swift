import XCTest
@testable import DeckCore
final class AgentCharacterTests: XCTestCase {
  func testIdentityIsStableAndWorkDoesNotCelebrateDependencies() {
    let work = SessionWork(subagents: 2, shellJobs: 1, tools: 0, awaitingResults: true, scheduledWakeups: 0)
    let busy = AgentCharacter(project: "project", state: .working, work: work)
    XCTAssertEqual(busy.expression, .watching)
    XCTAssertEqual(busy.subagents, 2)
    XCTAssertEqual(busy.variant, AgentCharacter(project: "project", state: .done).variant)
    XCTAssertEqual(AgentCharacter(project: "project", state: .waiting).expression, .asking)
    XCTAssertEqual(AgentCharacter(project: "project", state: .disconnected).expression, .unknown)
  }
}

extension AgentCharacterTests {
  func testDependencyMetadataIsBoundedAndDoesNotExposeProviderIdentifiers() throws {
    var ledger = SessionWorkLedger()
    for index in 0..<100 { _ = ledger.observe("SubagentStart", data: ["agent_id": "private-provider-thread-\(index)"]) }
    let summary = ledger.summary
    XCTAssertEqual(summary.subagents, 100)
    XCTAssertEqual(summary.dependencies?.count, 64)
    let data = try JSONEncoder().encode(summary)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-provider-thread"))
    ledger.observeChild("PermissionRequest", data: ["agent_id": "private-provider-thread-0"])
    XCTAssertTrue(ledger.summary.dependencies?.contains { $0.state == .needsInput } == true)
  }
  func testOlderWorkPayloadRemainsDecodable() throws {
    let value = try JSONDecoder().decode(SessionWork.self, from: Data(#"{"subagents":1,"shellJobs":0,"tools":0,"awaitingResults":true,"scheduledWakeups":0}"#.utf8))
    XCTAssertNil(value.dependencies)
    XCTAssertTrue(value.hasOutstanding)
  }
}

extension AgentCharacterTests {
  @MainActor func testDuplicateRootOrdinalsAreVisibleInPhysicalKeyArtwork() {
    let previous = AgentVisualStyle.isolated; AgentVisualStyle.isolated = true
    defer { AgentVisualStyle.isolated = previous }
    let first = MasterHUBArtwork.jpeg(title:"Same project",subtitle:"Codex · 1",state:"WORKING",size:72,symbol:"gearshape.2")
    let second = MasterHUBArtwork.jpeg(title:"Same project",subtitle:"Codex · 2",state:"WORKING",size:72,symbol:"gearshape.2")
    XCTAssertNotNil(first); XCTAssertNotNil(second)
    XCTAssertNotEqual(first,second)
  }
}
