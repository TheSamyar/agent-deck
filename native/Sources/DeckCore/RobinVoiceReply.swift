import Foundation
public enum RobinVoiceReply: Equatable, Sendable {
  case allow, deny, later, repeatQuestion, stop, unclear
  public static func shouldAsk(_ request: PendingRequest, in snapshot: DeckSnapshot, now: Double = DeckClock.now) -> Bool {
    guard request.state == "pending", request.expiresAt > now,
      let session = snapshot.sessions[request.sessionId],
      snapshot.preferences.enabledAgents.contains(session.agentId),
      !snapshot.preferences.mutedProjects.contains(session.projectKey) else { return false }
    return request.choices.contains { $0.id == "allow" && $0.label.lowercased().contains("once") }
      && request.choices.contains { $0.id == "deny" }
  }
  public static func canApprove(context: String) -> Bool {
    let scope = context.trimmingCharacters(in: .whitespacesAndNewlines)
    return !scope.isEmpty && scope.count <= 600
      && !scope.lowercased().contains("not provided")
      && !scope.contains("requests permission in")
      && SupervisorSpeech.prepared(scope) == scope
  }
  public static func parse(_ text: String) -> Self {
    let words = text.lowercased().trimmingCharacters(in:.whitespacesAndNewlines).trimmingCharacters(in:.punctuationCharacters)
    switch words {
    case "approve", "allow once": return .allow
    case "deny", "no": return .deny
    case "later", "not now": return .later
    case "repeat": return .repeatQuestion
    case "stop listening", "cancel", "stop": return .stop
    default: return .unclear
    }
  }
}
