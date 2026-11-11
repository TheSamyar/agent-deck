import Foundation

/// A factual briefing assembled locally. No model infers completion or decides permissions.
public struct RobinBriefingReport: Equatable, Sendable {
  public let generatedAt: Date
  public let since: Date
  public let finishedCount: Int
  public let attentionCount: Int
  public let workingCount: Int
  public let unavailableCount: Int
  public let finished: [String]
  public let needsYou: [String]
  public let working: [String]
  public let nextDecision: String
  public let spokenText: String
}

public enum RobinBriefing {
  public static func make(snapshot: DeckSnapshot, tasks: [SupervisedTask], now: Date = Date(), since: Date? = nil) -> RobinBriefingReport {
    let start = min(since ?? now.addingTimeInterval(-86400), now)
    let from = start.timeIntervalSince1970 * 1000, until = now.timeIntervalSince1970 * 1000
    let enabled = Set(snapshot.preferences.enabledAgents)
    let muted = Set(snapshot.preferences.mutedProjects)
    let sessions = snapshot.sessions.values.filter { enabled.contains($0.agentId) && !muted.contains($0.projectKey) }
      .sorted { $0.id < $1.id }
    let managed = tasks.filter { enabled.contains($0.provider.rawValue) && !muted.contains($0.cwd) }.sorted { $0.id < $1.id }
    func clean(_ value: String, limit: Int = 100) -> String {
      String(value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(limit))
    }
    func project(_ session: SessionSnapshot) -> String {
      clean(snapshot.preferences.projectNames[session.projectKey] ?? session.workspace)
    }
    func taskProject(_ task: SupervisedTask) -> String {
      clean(snapshot.preferences.projectNames[task.cwd] ?? URL(fileURLWithPath: task.cwd).lastPathComponent)
    }
    func matches(_ task: SupervisedTask, _ session: SessionSnapshot) -> Bool {
      guard let id = task.session, !id.isEmpty else { return false }
      return task.provider.rawValue == session.agentId && id == session.providerSessionId
        && URL(fileURLWithPath: task.cwd).standardizedFileURL.path == URL(fileURLWithPath: session.cwd).standardizedFileURL.path
    }
    func inWindow(_ timestamp: Double) -> Bool { timestamp.isFinite && timestamp > from && timestamp <= until }
    func taskLabel(_ task: SupervisedTask) -> String { "\(task.provider.title) in \(taskProject(task)): \(clean(task.goal))" }
    func sessionLabel(_ session: SessionSnapshot) -> String { "\(session.agentName) in \(project(session))" }

    var finished: [(Double, String)] = managed.filter { $0.state == .done && inWindow($0.updatedAt.timeIntervalSince1970 * 1000) }
      .map { ($0.updatedAt.timeIntervalSince1970 * 1000, taskLabel($0)) }
    // A handoff records the completion event even if that session has started another turn.
    var completedSessions: [String: (Double, String)] = [:]
    for session in sessions where session.status == .done && session.work?.needsInput != true && session.work?.hasOutstanding != true && session.work?.awaitingResults != true && inWindow(session.updatedAt) && !managed.contains(where: { matches($0, session) }) {
      completedSessions[session.id] = (session.updatedAt, sessionLabel(session))
    }
    for handoff in snapshot.handoffs ?? [] where handoff.state == .done && inWindow(handoff.timestamp) {
      guard let session = snapshot.sessions[handoff.sessionID], enabled.contains(session.agentId), !muted.contains(session.projectKey),
        !managed.contains(where: { matches($0, session) }) else { continue }
      if completedSessions[session.id].map({ $0.0 < handoff.timestamp }) != false {
        completedSessions[session.id] = (handoff.timestamp, sessionLabel(session))
      }
    }
    finished.append(contentsOf: completedSessions.values)
    finished.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }

    let pending = snapshot.requests.filter {
      $0.state == "pending" && $0.expiresAt > until && $0.createdAt <= until
        && snapshot.sessions[$0.sessionId].map { enabled.contains($0.agentId) && !muted.contains($0.projectKey) } == true
    }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    let pendingSessions = Set(pending.map(\.sessionId))
    var needsYou = pending.compactMap { request -> String? in
      guard let session = snapshot.sessions[request.sessionId] else { return nil }
      return "\(sessionLabel(session)): \(clean(request.title))"
    }
    for task in managed where task.state == .review || task.state == .blocked {
      guard !sessions.contains(where: { pendingSessions.contains($0.id) && matches(task, $0) }) else { continue }
      needsYou.append("\(taskLabel(task)) — \(task.state == .review ? "ready for your review" : "blocked")")
    }
    for session in sessions where session.status == .waiting || session.status == .error || (![SessionState.disconnected, .unknown].contains(session.status) && session.work?.needsInput == true) {
      guard !pendingSessions.contains(session.id), !managed.contains(where: { matches($0, session) && ($0.state == .review || $0.state == .blocked) }) else { continue }
      needsYou.append("\(sessionLabel(session)): \(session.status == .error ? "reported an error" : "needs input")")
    }
    var working = managed.filter { task in
      task.state == .working && !sessions.contains { session in matches(task, session) && (pendingSessions.contains(session.id) || session.work?.needsInput == true) }
    }.map(taskLabel)
    working.append(contentsOf: sessions.filter { session in session.status == .working && session.work?.needsInput != true && !pendingSessions.contains(session.id) && !managed.contains(where: { $0.state == .working && matches($0, session) }) }.map(sessionLabel))
    // Closed sessions are history, not machines the user needs to reconnect.
    let unavailable = sessions.filter {
      $0.status == .unknown && $0.lastHookAt <= until && until - $0.lastHookAt < 15 * 60 * 1000
    }.count
    let next: String
    if let first = pending.first, let session = snapshot.sessions[first.sessionId] {
      next = "Review \(sessionLabel(session)): \(clean(first.title))."
    } else if let first = needsYou.first { next = "Open \(first) in Agent Deck." }
    else if !working.isEmpty { next = "No decision is waiting. Your agents are still working." }
    else if unavailable > 0 { next = "Reconnect the unavailable agents to check their status." }
    else { next = "No decision is waiting. Choose your next task." }
    let window = since == nil ? "In the last 24 hours" : "Since your last briefing"
    var sentences = ["Alfred briefing. \(window), \(finished.count) \(finished.count == 1 ? "item reported finished" : "items reported finished")."]
    if !finished.isEmpty { sentences.append(finished.prefix(3).map(\.1).joined(separator: ". ") + ".") }
    sentences.append("\(needsYou.count) \(needsYou.count == 1 ? "item needs" : "items need") you. \(working.count) \(working.count == 1 ? "item is" : "items are") working.")
    if !needsYou.isEmpty { sentences.append(needsYou.prefix(2).joined(separator: ". ") + ".") }
    if unavailable > 0 { sentences.append("\(unavailable) \(unavailable == 1 ? "agent has" : "agents have") unavailable status.") }
    sentences.append("Next: \(next)")
    return .init(generatedAt: now, since: start, finishedCount: finished.count, attentionCount: needsYou.count,
      workingCount: working.count, unavailableCount: unavailable, finished: finished.map(\.1), needsYou: needsYou,
      working: working, nextDecision: next, spokenText: sentences.joined(separator: " "))
  }
}

public enum RobinBriefingSchedule {
  /// A local-calendar day is claimed once. A clock rollback does not repeat a briefing.
  public static func isDue(now: Date, lastBriefingAt: Date?, enabled: Bool, hour: Int = 9, calendar: Calendar = .current) -> Bool {
    guard enabled, calendar.component(.hour, from: now) >= min(23, max(0, hour)) else { return false }
    guard let lastBriefingAt else { return true }
    return calendar.startOfDay(for: now) > calendar.startOfDay(for: lastBriefingAt)
  }
}
