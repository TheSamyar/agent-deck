import XCTest
@testable import DeckCore

final class RobinBriefingTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_793_750_400)
  private func fixture() async throws -> DeckSnapshot {
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"))
    for provider in ["claude", "codex"] {
      _ = await engine.ingest(agent: provider, event: "SessionStart", body: ["data": ["session_id": "briefing-" + provider, "cwd": "/projects/" + provider]])
    }
    var snapshot = await engine.snapshot()
    snapshot.timestamp = now.timeIntervalSince1970 * 1000
    for id in snapshot.sessions.keys {
      snapshot.sessions[id]?.status = .idle
      snapshot.sessions[id]?.updatedAt = now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000
    }
    return snapshot
  }
  func testOnlyRecentReportedCompletionIsCountedAndNeverInventsOvernightWork() async throws {
    var snapshot = try await fixture()
    let claude = try XCTUnwrap(snapshot.sessions.values.first { $0.agentId == "claude" }?.id)
    let codex = try XCTUnwrap(snapshot.sessions.values.first { $0.agentId == "codex" }?.id)
    snapshot.sessions[claude]?.status = .done
    snapshot.sessions[codex]?.status = .done
    snapshot.sessions[codex]?.updatedAt = now.addingTimeInterval(-90000).timeIntervalSince1970 * 1000
    let report = RobinBriefing.make(snapshot: snapshot, tasks: [], now: now)
    XCTAssertEqual(report.finishedCount, 1)
    XCTAssertTrue(report.spokenText.contains("In the last 24 hours"))
    XCTAssertTrue(report.spokenText.contains("reported finished"))
    XCTAssertFalse(report.spokenText.lowercased().contains("overnight"))
    XCTAssertFalse(report.spokenText.contains("verified"))
  }
  func testExactPendingRequestIsTheNextDecisionAndExpiredRequestsAreIgnored() async throws {
    var snapshot = try await fixture()
    let session = try XCTUnwrap(snapshot.sessions.values.first)
    let timestamp = now.timeIntervalSince1970 * 1000
    snapshot.requests = [
      .init(id: "expired", sessionId: session.id, title: "Old request", context: "", choices: [], createdAt: timestamp-10000, expiresAt: timestamp-1, state: "pending", revision: 1, source: "test"),
      .init(id: "live", sessionId: session.id, title: "Run tests?", context: "swift test", choices: [], createdAt: timestamp-1000, expiresAt: timestamp+30000, state: "pending", revision: 1, source: "test")
    ]
    let report = RobinBriefing.make(snapshot: snapshot, tasks: [], now: now)
    XCTAssertEqual(report.attentionCount, 1)
    XCTAssertTrue(report.nextDecision.contains("Run tests?"))
    XCTAssertFalse(report.spokenText.contains("Old request"))
  }
  func testManagedWorkIsNotDoubleCountedAsObservedSession() async throws {
    var snapshot = try await fixture()
    let session = try XCTUnwrap(snapshot.sessions.values.first { $0.agentId == "codex" })
    snapshot.sessions[session.id]?.status = .working
    var task = SupervisedTask(provider: .codex, cwd: session.cwd, goal: "Fix the dashboard", criteria: "Tests pass")
    task.session = session.providerSessionId
    task.state = .working
    let report = RobinBriefing.make(snapshot: snapshot, tasks: [task], now: now)
    XCTAssertEqual(report.workingCount, 1)
    XCTAssertTrue(report.working.first?.contains("Fix the dashboard") == true)
    task.state = .review
    snapshot.sessions[session.id]?.status = .waiting
    let review = RobinBriefing.make(snapshot: snapshot, tasks: [task], now: now)
    XCTAssertEqual(review.attentionCount, 1)
    XCTAssertEqual(review.finishedCount, 0)
  }
  func testUnavailableAgentPreventsAnAllClearClaim() async throws {
    var snapshot = try await fixture()
    let id = try XCTUnwrap(snapshot.sessions.keys.first)
    snapshot.sessions[id]?.status = .unknown
    snapshot.sessions[id]?.lastHookAt = now.timeIntervalSince1970 * 1000 - 1000
    let report = RobinBriefing.make(snapshot: snapshot, tasks: [], now: now)
    XCTAssertEqual(report.unavailableCount, 1)
    XCTAssertTrue(report.nextDecision.contains("Reconnect"))
    XCTAssertFalse(report.nextDecision.contains("Choose your next task"))
  }
  func testHistoricalDisconnectedAndStaleUnknownAgentsDoNotDemandReconnection() async throws {
    var snapshot = try await fixture()
    let ids = Array(snapshot.sessions.keys).sorted()
    snapshot.sessions[ids[0]]?.status = .disconnected
    snapshot.sessions[ids[0]]?.lastHookAt = now.timeIntervalSince1970 * 1000
    snapshot.sessions[ids[1]]?.status = .unknown
    snapshot.sessions[ids[1]]?.lastHookAt = now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000
    let report = RobinBriefing.make(snapshot: snapshot, tasks: [], now: now)
    XCTAssertEqual(report.unavailableCount, 0)
    XCTAssertFalse(report.spokenText.contains("Reconnect"))
  }
  func testMutedProjectsAreExcludedFromObservedAndManagedBriefing() async throws {
    var snapshot = try await fixture()
    let session = try XCTUnwrap(snapshot.sessions.values.first { $0.agentId == "codex" })
    snapshot.preferences.mutedProjects = snapshot.sessions.values.map(\.projectKey)
    for id in snapshot.sessions.keys { snapshot.sessions[id]?.status = .done }
    var task = SupervisedTask(provider: .codex, cwd: session.cwd, goal: "Private task", criteria: "Done")
    task.state = .blocked
    let timestamp = now.timeIntervalSince1970 * 1000
    snapshot.requests = [.init(id: "muted", sessionId: session.id, title: "Private approval", context: "", choices: [], createdAt: timestamp-1000, expiresAt: timestamp+30000, state: "pending", revision: 1, source: "test")]
    let report = RobinBriefing.make(snapshot: snapshot, tasks: [task], now: now)
    XCTAssertEqual(report.finishedCount, 0)
    XCTAssertEqual(report.attentionCount, 0)
    XCTAssertEqual(report.workingCount, 0)
    XCTAssertFalse(report.spokenText.contains("Private"))
  }
  func testScheduleIsOncePerLocalCalendarDayAndDefersBeforeHour() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    func date(_ day: Int, _ hour: Int) -> Date {
      calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }
    XCTAssertFalse(RobinBriefingSchedule.isDue(now: date(3, 8), lastBriefingAt: nil, enabled: true, calendar: calendar))
    XCTAssertTrue(RobinBriefingSchedule.isDue(now: date(3, 9), lastBriefingAt: date(2, 23), enabled: true, calendar: calendar))
    XCTAssertFalse(RobinBriefingSchedule.isDue(now: date(3, 16), lastBriefingAt: date(3, 9), enabled: true, calendar: calendar))
    XCTAssertFalse(RobinBriefingSchedule.isDue(now: date(3, 16), lastBriefingAt: date(4, 9), enabled: true, calendar: calendar))
    XCTAssertFalse(RobinBriefingSchedule.isDue(now: date(3, 16), lastBriefingAt: nil, enabled: false, calendar: calendar))
  }
}
