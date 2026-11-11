import XCTest
@testable import DeckCore

final class RobinMissionTests: XCTestCase {
  func testMissionBudgetsStopWithoutInventingCompletion() {
    var mission = RobinMission(goal: "Fix login", project: "/work/app", acceptance: ["Login tests pass"])
    XCTAssertNil(mission.budgetBlocker(now: mission.startedAt))
    mission.actionCount = 32
    XCTAssertNotNil(mission.budgetBlocker(now: mission.startedAt))
    XCTAssertNotEqual(mission.phase, .done)
    mission.actionCount = 0; mission.equivalentFailures = 3
    XCTAssertTrue(mission.budgetBlocker(now: mission.startedAt)!.contains("assumption"))
    mission.equivalentFailures = 0
    XCTAssertNotNil(mission.budgetBlocker(now: mission.startedAt.addingTimeInterval(600)))
  }
  func testEveryAcceptanceCriterionNeedsEvidenceAndDispatchIsInsufficient() {
    var mission = RobinMission(goal: "Fix login", project: "/work/app", acceptance: ["Tests pass", "Login works"])
    mission.evidence = [.init(name: "agentPrompt", succeeded: true, verified: true, detail: "Dispatched")]
    XCTAssertFalse(mission.acceptanceVerified)
    mission.checks = [.init(name: "Tests pass", succeeded: true, verified: true, detail: "Exit zero")]
    XCTAssertFalse(mission.acceptanceVerified)
    mission.checks.append(.init(name: "Login works", succeeded: true, verified: true, detail: "Observed authenticated view"))
    XCTAssertTrue(mission.acceptanceVerified)
    mission.requiresObservation = true
    XCTAssertFalse(mission.acceptanceVerified)
    XCTAssertEqual(RobinEvaluation.cases.count, 30)
    XCTAssertEqual(Set(RobinEvaluation.cases.map(\.id)).count, 30)
  }
  func testRestoredMissionRequiresFreshObservationAndRoundTripsEvidence() throws {
    var mission = RobinMission(goal: "Run checks", project: "/work/app", acceptance: ["Tests pass"])
    mission.requiresObservation = true
    mission.evidence = [.init(name: "agentPrompt", succeeded: true, verified: true, detail: "Task dispatched")]
    let restored = try JSONDecoder().decode(RobinMission.self, from: JSONEncoder().encode(mission))
    XCTAssertTrue(restored.requiresObservation)
    XCTAssertNotNil(restored.budgetBlocker())
    XCTAssertTrue(restored.checks.isEmpty)
    XCTAssertNotEqual(restored.phase, .done)
  }
}
