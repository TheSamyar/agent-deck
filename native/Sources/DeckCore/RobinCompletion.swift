import Foundation

/// Celebrates observed root transitions, never historical results loaded on launch.
public enum RobinCompletion {
  public static func fresh(previous: DeckSnapshot?, current: DeckSnapshot, now: Double = DeckClock.now) -> [SessionSnapshot] {
    guard let previous, previous.instanceId == current.instanceId else { return [] }
    return current.sessions.values.filter { session in
      guard let old = previous.sessions[session.id] else { return false }
      return [.working, .waiting].contains(old.status) && session.status == .done
        && session.updatedAt <= now && now - session.updatedAt < 10_000
        && session.work?.hasOutstanding != true && session.work?.awaitingResults != true && session.work?.needsInput != true
        && current.preferences.enabledAgents.contains(session.agentId)
        && !current.preferences.mutedProjects.contains(session.projectKey)
    }.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt < $1.updatedAt }
  }
}
