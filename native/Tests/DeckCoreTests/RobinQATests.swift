import XCTest
@testable import DeckCore

/// Cross-feature regressions found independently during integration review.
final class RobinQATests: XCTestCase {
  @MainActor func testPhysicalWakeCaptureUsesListeningIdentity() {
    XCTAssertEqual(RobinArtwork.mode(for: "Wake listening"), .listening)
    XCTAssertEqual(RobinArtwork.mode(for: "Opening microphone"), .thinking)
    XCTAssertEqual(RobinArtwork.mode(for: "Needs your decision"), .needsYou)
  }

  func testCompletionDoesNotAnnounceBlockedInputOrReplayAcrossServiceRestart() async throws {
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"))
    let receipt = await engine.ingest(agent: "claude", event: "UserPromptSubmit", body: [
      "data": ["session_id": "qa-completion", "cwd": "/work/qa"]])
    var old = await engine.snapshot()
    old.sessions[receipt.sessionId]?.status = .working
    var done = old
    done.sessions[receipt.sessionId]?.status = .done
    done.sessions[receipt.sessionId]?.updatedAt = 50_000
    done.sessions[receipt.sessionId]?.work = .init(subagents: 0, shellJobs: 0, tools: 0,
      awaitingResults: false, scheduledWakeups: 0, needsInput: true)
    XCTAssertTrue(RobinCompletion.fresh(previous: old, current: done, now: 50_001).isEmpty,
      "A contradictory Done state must not announce success while work still needs input")
    done.sessions[receipt.sessionId]?.work = nil
    done.instanceId = "restarted-service"
    XCTAssertTrue(RobinCompletion.fresh(previous: old, current: done, now: 50_001).isEmpty,
      "A reconnect cannot replay historical completion")
  }

  func testBriefingDoesNotHideInputNeededByWorkingDependency() async throws {
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"))
    let receipt = await engine.ingest(agent: "claude", event: "UserPromptSubmit", body: [
      "data": ["session_id": "qa-blocked-child", "cwd": "/work/blocked-child"]])
    var snapshot = await engine.snapshot()
    snapshot.sessions[receipt.sessionId]?.status = .working
    snapshot.sessions[receipt.sessionId]?.work = .init(subagents: 1, shellJobs: 0, tools: 0,
      awaitingResults: true, scheduledWakeups: 0, needsInput: true)
    let report = RobinBriefing.make(snapshot: snapshot, tasks: [])
    XCTAssertEqual(report.attentionCount, 1)
    XCTAssertEqual(report.workingCount, 0)
    XCTAssertFalse(report.nextDecision.contains("No decision is waiting"))
  }
}
