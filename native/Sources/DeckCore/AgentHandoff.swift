import Foundation

public struct AgentHandoff: Codable, Identifiable, Equatable, Sendable {
  public let id: String
  public let sessionID: String
  public let project: String
  public let state: SessionState
  public let timestamp: Double
  public let sessionMilliseconds: Double
  public var canFocus: Bool
  public static func records(_ snapshot: DeckSnapshot) -> [Self] {
    let live = snapshot.sessions.values.filter {
      snapshot.preferences.enabledAgents.contains($0.agentId) && [.done, .waiting, .error].contains($0.status)
    }.map { session in
      Self(id: session.id + ":" + String(session.updatedAt), sessionID: session.id,
        project: snapshot.preferences.projectNames[session.projectKey] ?? session.workspace,
        state: session.status, timestamp: session.updatedAt,
        sessionMilliseconds: max(0, session.updatedAt - session.startedAt), canFocus: session.capabilities.focus)
    }
    var unique: [String: Self] = [:]
    for var record in (snapshot.handoffs ?? []) + live {
      guard snapshot.preferences.enabledAgents.contains(snapshot.sessions[record.sessionID]?.agentId ?? "") else { continue }
      let session = snapshot.sessions[record.sessionID]
      if record.state == .waiting && session?.status != .waiting { continue }
      record.canFocus = session?.capabilities.focus == true && session?.status != .disconnected && session?.status != .unknown
      if unique[record.sessionID].map({ $0.timestamp > record.timestamp }) != true { unique[record.sessionID] = record }
    }
    return unique.values.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp }.prefix(100).map { $0 }
  }
}
