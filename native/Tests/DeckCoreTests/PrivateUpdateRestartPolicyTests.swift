import XCTest
@testable import DeckCore

final class PrivateUpdateRestartPolicyTests: XCTestCase {
  func testRecoveryRequiresExactTopLevelLaunchdPIDAndCurrentBundleProgram() {
    let program = "/Users/test/Applications/Agent Deck.app/Contents/Helpers/DeckService.bundle/Contents/MacOS/deck-service"
    let prefix = "gui/501/com.aiagentdeck.service = {\n"
    let matching = prefix + "\tprogram = " + program + "\n\tpid = 123\n}\n"
    XCTAssertTrue(PrivateUpdateRestartPolicy.launchdServiceMatches(matching, pid: 123, programPath: program))
    XCTAssertFalse(PrivateUpdateRestartPolicy.launchdServiceMatches(matching, pid: 124, programPath: program))
    XCTAssertFalse(PrivateUpdateRestartPolicy.launchdServiceMatches(matching, pid: 123,
      programPath: program.replacingOccurrences(of: "/Applications/", with: "/Old Applications/")))
    XCTAssertFalse(PrivateUpdateRestartPolicy.launchdServiceMatches(prefix + "\targuments = {\n\t\t" + program + "\n\t}\n\tpid = 123\n}", pid: 123, programPath: program))
    XCTAssertFalse(PrivateUpdateRestartPolicy.launchdServiceMatches(prefix + "\tprogram = " + program + "\n\tenvironment = {\n\t\tpid = 123\n\t}\n}", pid: 123, programPath: program))
    XCTAssertFalse(PrivateUpdateRestartPolicy.launchdServiceMatches(matching + "\tprogram = " + program + "\n", pid: 123, programPath: program))
    XCTAssertFalse(PrivateUpdateRestartPolicy.launchdServiceMatches(matching, pid: 0, programPath: program))
  }
  private func task(_ state: SupervisedTaskState) -> SupervisedTask {
    var result = SupervisedTask(provider: .codex, cwd: "/private/tmp", goal: "fixture", criteria: "fixture")
    result.state = state
    return result
  }

  func testRequiresConnectedIdleStateAndExactlyZeroRequests() {
    XCTAssertTrue(PrivateUpdateRestartPolicy.canRestart(connected: true, pendingRequestCount: 0,
      busy: false, tasks: [], processIsAlive: { _ in false }))
    XCTAssertFalse(PrivateUpdateRestartPolicy.canRestart(connected: false, pendingRequestCount: 0,
      busy: false, tasks: [], processIsAlive: { _ in false }))
    XCTAssertFalse(PrivateUpdateRestartPolicy.canRestart(connected: true, pendingRequestCount: 1,
      busy: false, tasks: [], processIsAlive: { _ in false }))
    XCTAssertFalse(PrivateUpdateRestartPolicy.canRestart(connected: true, pendingRequestCount: -1,
      busy: false, tasks: [], processIsAlive: { _ in false }))
    XCTAssertFalse(PrivateUpdateRestartPolicy.canRestart(connected: true, pendingRequestCount: 0,
      busy: true, tasks: [], processIsAlive: { _ in false }))
  }

  func testWorkingTaskBlocksEvenWithoutAnObservedProcess() {
    XCTAssertFalse(PrivateUpdateRestartPolicy.canRestart(connected: true, pendingRequestCount: 0,
      busy: false, tasks: [task(.working)], processIsAlive: { _ in false }))
  }

  func testLiveOriginalProcessBlocksEveryNonworkingTaskState() {
    for state in [SupervisedTaskState.blocked, .review, .stopped, .done] {
      var owned = task(state)
      owned.pid = 123; owned.processBirth = "fixture-process-birth"
      XCTAssertFalse(PrivateUpdateRestartPolicy.canRestart(connected: true, pendingRequestCount: 0,
        busy: false, tasks: [owned], processIsAlive: { $0.pid == 123 && $0.processBirth == "fixture-process-birth" }), "\(state)")
    }
  }

  func testUnknownIdentityFailsClosedWhenProcessProbeCannotRuleOutOwnership() {
    let unknown = task(.blocked)
    XCTAssertNil(unknown.pid)
    XCTAssertNil(unknown.processBirth)
    XCTAssertFalse(PrivateUpdateRestartPolicy.canRestart(connected: true, pendingRequestCount: 0,
      busy: false, tasks: [unknown], processIsAlive: { _ in true }))
  }

  func testCompletedTasksAllowRestartOnlyWhenEveryProcessIsGone() {
    let tasks = [task(.review), task(.blocked), task(.stopped), task(.done)]
    XCTAssertTrue(PrivateUpdateRestartPolicy.canRestart(connected: true, pendingRequestCount: 0,
      busy: false, tasks: tasks, processIsAlive: { _ in false }))
    let stillAlive = tasks.last!.id
    XCTAssertFalse(PrivateUpdateRestartPolicy.canRestart(connected: true, pendingRequestCount: 0,
      busy: false, tasks: tasks, processIsAlive: { $0.id == stillAlive }))
  }

  func testActiveAppManagedCodexTurnsBlockEvenWithoutSupervisedTasks() {
    for state in [SessionState.working, .waiting] {
      let session = SessionSnapshot(id: "fixture", agentId: "codex", agentName: "Codex", workspace: "fixture", cwd: "/private/tmp",
        providerSessionId: "fixture", hostInstanceId: "managed-codex", bundleId: "", pid: 0, tty: "", terminalId: "",
        status: state, detail: "fixture", tool: "", updatedAt: 0, startedAt: 0, lastHookAt: 0, capabilities: Capabilities())
      XCTAssertFalse(PrivateUpdateRestartPolicy.canRestart(connected: true, pendingRequestCount: 0,
        busy: false, tasks: [], managedSessions: [session], processIsAlive: { _ in false }))
      var external = session; external.hostInstanceId = "external-terminal"
      XCTAssertTrue(PrivateUpdateRestartPolicy.canRestart(connected: true, pendingRequestCount: 0,
        busy: false, tasks: [], managedSessions: [external], processIsAlive: { _ in false }))
    }
  }

  func testRecoveryMarkerAppliesByNumericBuildOrder() {
    XCTAssertTrue(PrivateUpdateRestartPolicy.applies(expectedBuild: "10", currentBuild: "10"))
    XCTAssertTrue(PrivateUpdateRestartPolicy.applies(expectedBuild: "9", currentBuild: "10"))
    XCTAssertFalse(PrivateUpdateRestartPolicy.applies(expectedBuild: "10", currentBuild: "9"))
    XCTAssertTrue(PrivateUpdateRestartPolicy.applies(expectedBuild: "00010", currentBuild: "11"))
    XCTAssertTrue(PrivateUpdateRestartPolicy.applies(expectedBuild: "0", currentBuild: "0"))
    XCTAssertTrue(PrivateUpdateRestartPolicy.applies(expectedBuild: "999999999999999998", currentBuild: "999999999999999999"))
  }

  func testInvalidMarkerOrCurrentBuildNeverApplies() {
    for invalid in ["", " ", "10 ", " 10", "+10", "-10", "1.0", "10\n", "١٠", "１０", "9999999999999999999"] {
      XCTAssertFalse(PrivateUpdateRestartPolicy.applies(expectedBuild: invalid, currentBuild: "10"), invalid)
      XCTAssertFalse(PrivateUpdateRestartPolicy.applies(expectedBuild: "10", currentBuild: invalid), invalid)
    }
  }
}
