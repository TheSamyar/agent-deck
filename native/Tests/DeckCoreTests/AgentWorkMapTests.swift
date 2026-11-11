import XCTest
@testable import DeckCore
final class AgentWorkMapTests: XCTestCase {
  func testSmallWorkloadsPreserveIndividualUncertainty() {
    let work = SessionWork(subagents:1,shellJobs:1,tools:0,awaitingResults:true,scheduledWakeups:0,dependencies:[.init(id:"child",kind:.subagent,state:.needsInput),.init(id:"shell",kind:.shell,state:.unknown)])
    let nodes = AgentWorkNode.nodes(for:work)
    XCTAssertEqual(nodes.count,2)
    XCTAssertEqual(nodes[0].state,.needsInput)
    XCTAssertEqual(nodes[1].state,.unknown)
    XCTAssertTrue(nodes.allSatisfy { $0.count == 1 })
  }
  func testLargeOrIncompleteMetadataUsesTruthfulBoundedCounts() {
    let work = SessionWork(subagents:50,shellJobs:100,tools:1,awaitingResults:true,scheduledWakeups:0,dependencies:[.init(id:"overflow",kind:.tool,state:.unknown)])
    let nodes = AgentWorkNode.nodes(for:work)
    XCTAssertEqual(nodes.count,3)
    XCTAssertEqual(nodes.reduce(0) { $0+$1.count },151)
    XCTAssertEqual(nodes.first { $0.kind == .tool }?.state,.unknown)
  }
}
