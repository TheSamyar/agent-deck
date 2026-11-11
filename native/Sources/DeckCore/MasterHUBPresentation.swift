import Foundation

public struct MasterHUBDialPresentation: Equatable, Sendable {
  public var agentId: String
  public var sessionID: String
  public var projectKey: String
  public var project: String
  public var identity: String
  public var status: String
  public var state: String
  public var work: SessionWork?
  public var summary: String
  public var position: String
  public init(snapshot: DeckSnapshot?, handoffs: Bool = false) {
    let sessions = snapshot.map { value in handoffs ? AgentHandoff.records(value).compactMap { value.sessions[$0.sessionID] } : MasterHUBSurface.orderedSessions(value) } ?? []
    let index = sessions.firstIndex { $0.id == snapshot?.selectedSessionId }
    let selected = index.map { sessions[$0] }
    agentId = selected?.agentId ?? ""
    sessionID = selected?.id ?? ""
    projectKey = selected?.projectKey ?? "quiet"
    project = selected?.workspace ?? (snapshot == nil ? "Offline" : "All quiet")
    identity = selected?.agentName ?? "Agent Deck"
    if let selected {
      let duplicates = sessions.filter { $0.agentId == selected.agentId && $0.workspace == selected.workspace }
      if duplicates.count > 1, let ordinal = duplicates.firstIndex(where: { $0.id == selected.id }) { identity += " · \(ordinal + 1)" }
    }
    if selected?.status == .working, let work = selected?.work, work.awaitingResults || work.hasOutstanding { status = work.label }
    else { status = selected?.status.label ?? "No active work" }
    work = selected?.work
    state = selected?.status.rawValue ?? "IDLE"
    let observed = snapshot?.sessions.values.filter { session in
      snapshot?.preferences.enabledAgents.contains(session.agentId) == true && ![.disconnected, .unknown].contains(session.status)
    } ?? []
    summary = "\(observed.filter { $0.status == .working }.count) WORK · \(observed.filter { $0.status == .waiting || $0.status == .error }.count) INPUT · \(observed.filter { $0.status == .done }.count) DONE"
    position = index.map { "\($0 + 1) / \(sessions.count) · Press to focus" } ?? ""
  }
}
