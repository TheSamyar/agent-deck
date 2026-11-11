import Foundation

public struct RobinProactiveQuestion: Codable, Sendable, Equatable, Identifiable {
  public enum Reason: String, Codable, Sendable { case blocker, review, priorities, successCriteria }
  public var id: String
  public var project: String
  public var taskID: String?
  public var reason: Reason
  public var evidence: String
  public var question: String
  public var recommendation: String
  public init(id: String, project: String, taskID: String? = nil, reason: Reason, evidence: String, question: String, recommendation: String) {
    self.id=id; self.project=project; self.taskID=taskID; self.reason=reason
    self.evidence=String(evidence.prefix(1000)); self.question=String(question.prefix(600)); self.recommendation=String(recommendation.prefix(400))
  }
  public var spokenText: String { [evidence, recommendation, question].filter { !$0.isEmpty }.joined(separator: " ") }
}

/// Evidence-driven invitations, separate from permission requests and their proofs.
/// Persist this value with the conversation to retain snoozes/deduplication.
public struct RobinProactiveQuestions: Codable, Sendable {
  public private(set) var pending: RobinProactiveQuestion?
  public private(set) var lastAskedAt: Date?
  public private(set) var snoozedUntil: Date?
  private var seen: [String] = []
  private var baselineTasks: [String: String] = [:]
  private var previousSnapshot: DeckSnapshot?
  private var initialized = false
  public init() {}
  public mutating func offer(_ candidate: RobinProactiveQuestion, now: Date = Date(), available: Bool) -> RobinProactiveQuestion? {
    guard available, pending == nil, !seen.contains(candidate.id), !candidate.project.isEmpty,
      !candidate.evidence.isEmpty, !candidate.question.isEmpty,
      snoozedUntil.map({ now >= $0 }) ?? true,
      lastAskedAt.map({ now.timeIntervalSince($0) >= 600 }) ?? true else { return nil }
    pending=candidate; lastAskedAt=now; seen.append(candidate.id)
    if seen.count > 500 { seen.removeFirst(seen.count - 500) }
    return candidate
  }
  public mutating func answer(now: Date = Date()) { pending=nil; snoozedUntil=nil }
  public mutating func dismiss() { pending=nil }
  public mutating func snooze(now: Date = Date()) { snoozedUntil=now.addingTimeInterval(900) }
  public mutating func resume(now: Date = Date()) -> RobinProactiveQuestion? {
    guard snoozedUntil.map({now >= $0}) ?? true else {return nil}
    return pending
  }
  public mutating func update(snapshot: DeckSnapshot, tasks: [SupervisedTask], now: Date = Date(), available: Bool) -> RobinProactiveQuestion? {
    let age=now.timeIntervalSince1970 - snapshot.timestamp / 1000
    guard snapshot.ok, age.isFinite, (-5...30).contains(age) else {return nil}
    let enabled=Set(snapshot.preferences.enabledAgents), muted=Set(snapshot.preferences.mutedProjects)
    let eligible=tasks.filter {enabled.contains($0.provider.rawValue) && !muted.contains($0.cwd)}
    if let question = pending {
      let sourceChanged = question.taskID.map { id in
        guard let source = eligible.first(where: { $0.id == id }) else { return true }
        let evidenceChanged = question.id.hasPrefix("task:") && question.id != "task:\(source.id):\(signature(source))"
        return evidenceChanged || (question.reason == .blocker ? source.state != .blocked : question.reason == .review && source.state != .review)
      } ?? false
      if muted.contains(question.project) || sourceChanged { pending=nil; snoozedUntil=nil }
    }
    let signatures=Dictionary(uniqueKeysWithValues:eligible.map {($0.id, signature($0))})
    guard initialized else {initialized=true;baselineTasks=signatures;previousSnapshot=snapshot;return nil}
    // Keep observations while busy; changed decisions are reconsidered when available.
    guard available else {return nil}
    var candidates: [RobinProactiveQuestion] = []
    for task in eligible.sorted(by: {$0.id < $1.id}) where baselineTasks[task.id] != signatures[task.id] {
      let name=String(URL(fileURLWithPath:task.cwd).lastPathComponent.prefix(80))
      if task.state == .blocked {
        candidates.append(.init(id:"task:\(task.id):\(signature(task))",project:task.cwd,taskID:task.id,reason:.blocker,
          evidence:"\(task.provider.title) is blocked on \(name): \(String(task.result.prefix(240)))",
          question:"Should we investigate this blocker or pause this task?",recommendation:"I recommend investigating the blocker first."))
      } else if task.state == .review {
        candidates.append(.init(id:"task:\(task.id):\(signature(task))",project:task.cwd,taskID:task.id,reason:.review,
          evidence:"\(task.provider.title) has a result ready for review in \(name).",
          question:"Would you like me to review its evidence and remaining issues?",recommendation:"I recommend reviewing before marking it complete."))
      }
    }
    for session in RobinCompletion.fresh(previous:previousSnapshot,current:snapshot,now:now.timeIntervalSince1970*1000) {
      candidates.append(.init(id:"session:\(session.id):\(session.updatedAt)",project:session.projectKey,reason:.review,
        evidence:"\(session.agentName) reported finished in \(String(session.workspace.prefix(80))).",
        question:"Would you like me to review the result?",recommendation:"I recommend checking the evidence before moving on."))
    }
    // Blockers take priority, then stable ordering. No fabricated priority conflicts.
    candidates.sort { a,b in a.reason == b.reason ? a.id < b.id : a.reason == .blocker }
    guard pending == nil else {return nil}
    for candidate in candidates {if let offered=offer(candidate,now:now,available:available) {baselineTasks=signatures;previousSnapshot=snapshot;return offered}}
    // During cooldown preserve transitions so they can be offered when it ends.
    if candidates.isEmpty {baselineTasks=signatures;previousSnapshot=snapshot}
    return nil
  }
  private func signature(_ task: SupervisedTask) -> String {task.state.rawValue + ":" + String(task.result.prefix(1000))}
}
