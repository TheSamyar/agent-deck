import Foundation

public struct RobinMission: Codable, Identifiable, Sendable, Equatable {
  public enum Phase: String, Codable, Sendable { case understanding, planning, acting, checking, repairing, needsYou, done, blocked }
  public struct Evidence: Codable, Sendable, Equatable {
    public var name: String
    public var succeeded: Bool
    public var verified: Bool
    public var detail: String
    public var timestamp: Date
    public init(name: String, succeeded: Bool, verified: Bool, detail: String, timestamp: Date = Date()) {
      self.name = name; self.succeeded = succeeded; self.verified = verified; self.detail = String(detail.prefix(4000)); self.timestamp = timestamp
    }
  }
  public var id = UUID()
  public var goal: String
  public var project: String
  public var acceptance: [String]
  public var plan: [String] = []
  public var phase: Phase = .understanding
  public var currentStep = "Understanding your request"
  public var evidence: [Evidence] = []
  public var checks: [Evidence] = []
  public var blocker: String?
  public var startedAt = Date()
  public var updatedAt = Date()
  public var actionCount = 0
  public var requiresObservation = false
  public var failureSignature: String?
  public var equivalentFailures = 0
  public init(goal: String, project: String, acceptance: [String]) {
    self.goal = String(goal.prefix(16000)); self.project = project; self.acceptance = Array(acceptance.prefix(20))
  }
  public func budgetBlocker(now: Date = Date()) -> String? {
    if requiresObservation { return "Re-observe the project before continuing this saved mission." }
    if equivalentFailures >= 3 { return "Three equivalent failures. Recheck the assumption behind the failed action." }
    if actionCount >= 32 { return "The 32-action budget is reached. Review this checkpoint before continuing." }
    if now.timeIntervalSince(startedAt) >= 600 { return "The ten-minute budget is reached. Review this checkpoint before continuing." }
    return nil
  }
  public var acceptanceVerified: Bool {
    !requiresObservation && !acceptance.isEmpty && !checks.isEmpty && checks.allSatisfy { $0.succeeded && $0.verified }
      && acceptance.allSatisfy { criterion in checks.contains { $0.name == criterion && $0.succeeded && $0.verified } }
  }
  public var deviceState: String {
    switch phase { case .understanding, .planning: "Thinking"; case .acting: "Working"; case .checking: "Checking"; case .repairing: "Repairing"; case .needsYou: "Needs your decision"; case .done: "Complete"; case .blocked: "Blocked" }
  }
}
