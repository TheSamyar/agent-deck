import XCTest
@testable import DeckCore

final class RobinIntelligenceQATests: XCTestCase {
  func testCloudGateRejectsCommonQuotedAndSpacedCredentialFields() {
    for text in [#"{"password": "sensitive-value"}"#, "password : sensitive-value", "api-key = sensitive-value", "token : sensitive-value"] {
      XCTAssertFalse(RobinReasoningPolicy.permitsCloud(text: text), text)
    }
  }
  func testUnspecifiedAcceptanceCannotTurnAnUnrelatedPassingCommandIntoMissionSuccess() {
    var mission = RobinMission(goal: "Fix login and verify authentication", project: "/work/app", acceptance: [])
    mission.checks = [.init(name: "Approved project command", succeeded: true, verified: true, detail: "echo exited zero")]
    XCTAssertFalse(mission.acceptanceVerified, "The task's actual acceptance must be defined before completion can be claimed")
  }
}
