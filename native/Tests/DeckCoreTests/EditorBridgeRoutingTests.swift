import XCTest
@testable import DeckCore

final class EditorBridgeRoutingTests: XCTestCase {
  private func makeSession(
    hostInstanceId: String = "external-terminal",
    pid: Int = 4242
  ) -> SessionSnapshot {
    SessionSnapshot(
      id: "session-1",
      agentId: "claude",
      agentName: "Claude Code",
      workspace: "repo",
      cwd: "/tmp/repo",
      providerSessionId: "provider-1",
      hostInstanceId: hostInstanceId,
      bundleId: "com.todesktop.230313mzl4w4u92",
      pid: pid,
      tty: "",
      terminalId: "",
      status: .working,
      detail: "Running",
      tool: "",
      updatedAt: 1000,
      startedAt: 900,
      lastHookAt: 1000,
      capabilities: Capabilities()
    )
  }

  // MARK: - SessionActionRouter

  func testRouterManagedCodexActions() {
    let session = makeSession(hostInstanceId: "managed-codex", pid: 0)
    let ignoredBridge = EditorBridgeTarget(instanceId: "cursor-1", terminalId: "term-1")

    XCTAssertEqual(
      SessionActionRouter.route(action: "focus", session: session, bridgeTarget: ignoredBridge),
      .managedCodex(stop: false)
    )
    XCTAssertEqual(
      SessionActionRouter.route(action: "stop", session: session, bridgeTarget: ignoredBridge),
      .managedCodex(stop: true)
    )
    XCTAssertEqual(
      SessionActionRouter.route(action: "approve", session: session, bridgeTarget: ignoredBridge),
      .unsupported
    )
  }

  func testRouterBridgedSessionFocusRaisesWindowAndStopDoesNot() {
    let session = makeSession(hostInstanceId: "cursor-host", pid: 500)
    let target = EditorBridgeTarget(instanceId: "cursor-1", terminalId: "term-9")

    XCTAssertEqual(
      SessionActionRouter.route(action: "focus", session: session, bridgeTarget: target),
      .bridge(target, raiseWindowFirst: true)
    )
    XCTAssertEqual(
      SessionActionRouter.route(action: "stop", session: session, bridgeTarget: target),
      .bridge(target, raiseWindowFirst: false)
    )
    XCTAssertEqual(
      SessionActionRouter.route(action: "respond", session: session, bridgeTarget: target),
      .unsupported
    )
  }

  func testRouterLocalTerminalAndUnsupportedActions() {
    let session = makeSession(hostInstanceId: "terminal-host", pid: 600)

    XCTAssertEqual(
      SessionActionRouter.route(action: "stop", session: session, bridgeTarget: nil),
      .localTerminalInterrupt
    )
    XCTAssertEqual(
      SessionActionRouter.route(action: "focus", session: session, bridgeTarget: nil),
      .guiFocus
    )
    XCTAssertEqual(
      SessionActionRouter.route(action: "dashboard", session: session, bridgeTarget: nil),
      .unsupported
    )
  }

  // MARK: - EditorTerminalBridgeRegistry Matching

  func testRegistryMatchesLiveBridgeAndExpiresAtStaleThreshold() {
    var registry = EditorTerminalBridgeRegistry(staleAfterMs: 5000)
    registry.recordPoll(
      instanceId: "cursor-a",
      terminals: [
        EditorTerminalEntry(id: "term-1", processTree: [100, 101]),
        EditorTerminalEntry(id: "term-2", processTree: [200, 201]),
      ],
      now: 10_000
    )

    XCTAssertEqual(
      registry.findTarget(forSessionPID: 201, now: 14_999),
      EditorBridgeTarget(instanceId: "cursor-a", terminalId: "term-2")
    )
    XCTAssertNil(registry.findTarget(forSessionPID: 201, now: 15_000))
    XCTAssertNil(registry.findTarget(forSessionPID: 201, now: 16_000))
  }

  func testRegistryRejectsNonPositivePIDAndEmptyIdentifiers() {
    var registry = EditorTerminalBridgeRegistry()
    registry.recordPoll(
      instanceId: "",
      terminals: [EditorTerminalEntry(id: "term-1", processTree: [42])],
      now: 1000
    )
    XCTAssertNil(registry.findTarget(forSessionPID: 42, now: 1000))

    registry.recordPoll(
      instanceId: "cursor-a",
      terminals: [
        EditorTerminalEntry(id: "", processTree: [42]),
        EditorTerminalEntry(id: "term-valid", processTree: [0, -1, 43]),
      ],
      now: 1000
    )
    XCTAssertNil(registry.findTarget(forSessionPID: 42, now: 1000))
    XCTAssertNil(registry.findTarget(forSessionPID: 0, now: 1000))
    XCTAssertNil(registry.findTarget(forSessionPID: -1, now: 1000))
    XCTAssertEqual(
      registry.findTarget(forSessionPID: 43, now: 1000),
      EditorBridgeTarget(instanceId: "cursor-a", terminalId: "term-valid")
    )
  }

  func testRegistryFailsClosedOnMultipleMatchingTerminalsInSingleBridge() {
    var registry = EditorTerminalBridgeRegistry()
    registry.recordPoll(
      instanceId: "cursor-a",
      terminals: [
        EditorTerminalEntry(id: "term-1", processTree: [300, 301]),
        EditorTerminalEntry(id: "term-2", processTree: [301, 302]),
      ],
      now: 1000
    )
    registry.recordPoll(
      instanceId: "cursor-b",
      terminals: [EditorTerminalEntry(id: "term-b1", processTree: [301])],
      now: 1000
    )

    XCTAssertNil(registry.findTarget(forSessionPID: 301, now: 1200))
    XCTAssertEqual(
      registry.findTarget(forSessionPID: 302, now: 1200),
      EditorBridgeTarget(instanceId: "cursor-a", terminalId: "term-2")
    )
  }

  func testRegistryFailsClosedOnMultipleLiveBridgesUntilOneExpires() {
    var registry = EditorTerminalBridgeRegistry(staleAfterMs: 5000)
    registry.recordPoll(
      instanceId: "cursor-a",
      terminals: [EditorTerminalEntry(id: "term-a", processTree: [777])],
      now: 1000
    )
    registry.recordPoll(
      instanceId: "cursor-b",
      terminals: [EditorTerminalEntry(id: "term-b", processTree: [777])],
      now: 3000
    )

    XCTAssertNil(registry.findTarget(forSessionPID: 777, now: 4000))
    XCTAssertEqual(
      registry.findTarget(forSessionPID: 777, now: 6500),
      EditorBridgeTarget(instanceId: "cursor-b", terminalId: "term-b")
    )
  }

  // MARK: - Command Queueing, Results, and Cancellation

  func testCommandEnqueuePopResultConsumptionAndNoLeakAfterwards() {
    var registry = EditorTerminalBridgeRegistry()
    registry.enqueueCommand(
      instanceId: "cursor-a",
      commandId: "cmd-1",
      terminalId: "term-1",
      action: "stop"
    )

    let popped = registry.takePendingCommand(for: "cursor-a")
    XCTAssertEqual(popped, EditorBridgeCommand(id: "cmd-1", terminalId: "term-1", action: "stop"))
    XCTAssertNil(registry.takePendingCommand(for: "cursor-a"))

    // Polling before the extension replies must not drop the pending command ID.
    XCTAssertNil(registry.takeResult(for: "cmd-1"))

    registry.recordPoll(
      instanceId: "cursor-a",
      terminals: [],
      result: (id: "cmd-1", ok: true, message: "Sent Ctrl+C"),
      now: 2000
    )

    let consumed = registry.takeResult(for: "cmd-1")
    XCTAssertEqual(
      consumed,
      ActionResult(ok: true, state: "acknowledged", message: "Sent Ctrl+C", commandId: "cmd-1")
    )
    XCTAssertNil(registry.takeResult(for: "cmd-1"))

    // Re-reporting the same command ID after consumption must be ignored.
    registry.recordPoll(
      instanceId: "cursor-a",
      terminals: [],
      result: (id: "cmd-1", ok: true, message: "Duplicate"),
      now: 2100
    )
    XCTAssertNil(registry.takeResult(for: "cmd-1"))
  }

  func testCancelCommandOnTimeoutRemovesPendingAndRejectsLateResults() {
    var registry = EditorTerminalBridgeRegistry()
    registry.enqueueCommand(
      instanceId: "cursor-a",
      commandId: "cmd-timeout",
      terminalId: "term-1",
      action: "focus"
    )
    registry.cancelCommand(instanceId: "cursor-a", commandId: "cmd-timeout")

    XCTAssertNil(registry.takePendingCommand(for: "cursor-a"))

    registry.recordPoll(
      instanceId: "cursor-a",
      terminals: [],
      result: (id: "cmd-timeout", ok: true, message: "Late reply"),
      now: 5000
    )
    XCTAssertNil(registry.takeResult(for: "cmd-timeout"))

    // Cancelling an older command ID must not remove a newer pending command.
    registry.enqueueCommand(
      instanceId: "cursor-a",
      commandId: "cmd-new",
      terminalId: "term-1",
      action: "stop"
    )
    registry.cancelCommand(instanceId: "cursor-a", commandId: "cmd-old")
    XCTAssertEqual(
      registry.takePendingCommand(for: "cursor-a"),
      EditorBridgeCommand(id: "cmd-new", terminalId: "term-1", action: "stop")
    )
  }

  func testUnawaitedResultsAreRejectedAndFailedResultsPreserveState() {
    var registry = EditorTerminalBridgeRegistry()
    registry.recordPoll(
      instanceId: "cursor-a",
      terminals: [],
      result: (id: "unsolicited-cmd", ok: true, message: "Should not store"),
      now: 1000
    )
    XCTAssertNil(registry.takeResult(for: "unsolicited-cmd"))

    registry.enqueueCommand(
      instanceId: "cursor-a",
      commandId: "cmd-fail",
      terminalId: "term-1",
      action: "stop"
    )
    registry.recordPoll(
      instanceId: "cursor-a",
      terminals: [],
      result: (id: "cmd-fail", ok: false, message: "Terminal closed"),
      now: 1100
    )
    XCTAssertEqual(
      registry.takeResult(for: "cmd-fail"),
      ActionResult(ok: false, state: "failed", message: "Terminal closed", commandId: "cmd-fail")
    )
  }

  func testEnqueueOverwriteCleansUpOverwrittenCommandIDAndBoundsPendingCommands() {
    var registry = EditorTerminalBridgeRegistry()
    registry.enqueueCommand(
      instanceId: "cursor-a",
      commandId: "cmd-overwritten",
      terminalId: "term-1",
      action: "focus"
    )
    registry.enqueueCommand(
      instanceId: "cursor-a",
      commandId: "cmd-current",
      terminalId: "term-1",
      action: "stop"
    )

    registry.recordPoll(
      instanceId: "cursor-a",
      terminals: [],
      result: (id: "cmd-overwritten", ok: true, message: "Late overwritten reply"),
      now: 2000
    )
    XCTAssertNil(registry.takeResult(for: "cmd-overwritten"))

    XCTAssertEqual(
      registry.takePendingCommand(for: "cursor-a"),
      EditorBridgeCommand(id: "cmd-current", terminalId: "term-1", action: "stop")
    )
    registry.recordPoll(
      instanceId: "cursor-a",
      terminals: [],
      result: (id: "cmd-current", ok: true, message: "Stopped"),
      now: 2100
    )
    XCTAssertEqual(
      registry.takeResult(for: "cmd-current")?.commandId,
      "cmd-current"
    )

    for i in 0...256 {
      registry.enqueueCommand(
        instanceId: "inst-\(i)",
        commandId: "cmd-\(i)",
        terminalId: "term-1",
        action: "stop"
      )
    }
    XCTAssertNil(registry.takePendingCommand(for: "inst-0"))
    registry.recordPoll(
      instanceId: "inst-0",
      terminals: [],
      result: (id: "cmd-0", ok: true, message: "Evicted"),
      now: 2200
    )
    XCTAssertNil(registry.takeResult(for: "cmd-0"))
    XCTAssertEqual(
      registry.takePendingCommand(for: "inst-256"),
      EditorBridgeCommand(id: "cmd-256", terminalId: "term-1", action: "stop")
    )
  }

  func testRecordPollCapsLiveBridgesAtSixtyFour() {
    var registry = EditorTerminalBridgeRegistry(staleAfterMs: 5000)
    for i in 0..<70 {
      registry.recordPoll(
        instanceId: "inst-\(i)",
        terminals: [EditorTerminalEntry(id: "term-\(i)", processTree: [10_000 + i])],
        now: Double(1000 + i)
      )
    }

    for i in 0..<6 {
      XCTAssertNil(registry.findTarget(forSessionPID: 10_000 + i, now: 1100))
    }
    for i in 6..<70 {
      XCTAssertEqual(
        registry.findTarget(forSessionPID: 10_000 + i, now: 1100),
        EditorBridgeTarget(instanceId: "inst-\(i)", terminalId: "term-\(i)")
      )
    }
  }
}
