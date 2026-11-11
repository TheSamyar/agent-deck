import XCTest
@testable import DeckCore

final class RobinCompletionTests: XCTestCase {
  func testOnlyFreshObservedRootCompletionCelebrates() async throws {
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"))
    let receipt = await engine.ingest(agent: "claude", event: "UserPromptSubmit", body: ["data": ["session_id": "completion", "cwd": "/work/mission"]])
    var old = await engine.snapshot()
    old.sessions[receipt.sessionId]?.status = .working
    var done = old
    done.sessions[receipt.sessionId]?.status = .done
    done.sessions[receipt.sessionId]?.updatedAt = 20_000
    XCTAssertEqual(RobinCompletion.fresh(previous: old, current: done, now: 20_001).map(\.id), [receipt.sessionId])
    XCTAssertTrue(RobinCompletion.fresh(previous: nil, current: done, now: 20_001).isEmpty, "No launch replay")
    XCTAssertTrue(RobinCompletion.fresh(previous: done, current: done, now: 20_001).isEmpty, "No duplicate")
    XCTAssertTrue(RobinCompletion.fresh(previous: old, current: done, now: 40_000).isEmpty, "No delayed historical celebration")
    done.sessions[receipt.sessionId]?.work = .init(subagents: 1, shellJobs: 0, tools: 0, awaitingResults: true, scheduledWakeups: 0)
    XCTAssertTrue(RobinCompletion.fresh(previous: old, current: done, now: 20_001).isEmpty, "A child still running is not complete")
    done.sessions[receipt.sessionId]?.work = nil
    done.preferences.mutedProjects = ["/work/mission"]
    XCTAssertTrue(RobinCompletion.fresh(previous: old, current: done, now: 20_001).isEmpty, "Respect project mute")
  }
}
