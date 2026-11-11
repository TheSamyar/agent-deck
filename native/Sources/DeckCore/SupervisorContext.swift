import Foundation

public enum SupervisorContext {
  public static func json(snapshot: DeckSnapshot?, tasks: [SupervisedTask], connected: Bool, local: Bool) -> String {
    let visible = connected ? (snapshot?.sessions.values.filter {
      snapshot?.preferences.enabledAgents.contains($0.agentId) == true && $0.status != .unknown && $0.status != .disconnected
    } ?? []) : []
    func rank(_ state: SessionState) -> Int {
      switch state { case .waiting: 0; case .error: 1; case .working: 2; case .done: 3; default: 4 }
    }
    let ordered = visible.sorted { rank($0.status) == rank($1.status) ? $0.id < $1.id : rank($0.status) < rank($1.status) }
    let agents: [[String: Any]] = ordered.prefix(local ? 16 : 40).map { session in
      let task = tasks.first { $0.session == session.providerSessionId && $0.provider.rawValue == session.agentId }
      let project = snapshot?.preferences.projectNames[session.projectKey] ?? (session.workspace.isEmpty ? URL(fileURLWithPath: session.cwd).lastPathComponent : session.workspace)
      return ["id": session.id, "agent": session.agentName, "provider": session.agentId,
        "project": project, "status": session.status.label, "lastActivity": String(session.detail.prefix(300)),
        "currentTool": String(session.tool.prefix(80)), "backgroundWork": session.work?.hasOutstanding == true ? session.work!.label : "",
        "needsInput": session.status == .waiting,
        "inputRequests": snapshot?.requests.filter { $0.sessionId == session.id }.map { String($0.title.prefix(160)) } ?? [],
        "control": task == nil ? "observe only" : "managed task", "managedTaskId": task?.id ?? "",
        "selected": snapshot?.selectedSessionId == session.id]
    }
    let managed: [[String: Any]] = tasks.suffix(local ? 6 : 12).map {
      ["id": $0.id, "provider": $0.provider.rawValue, "goal": String($0.goal.prefix(1500)), "state": $0.state.rawValue,
        "result": String($0.result.suffix(local ? 1500 : 6000)), "canDraftFollowUp": $0.session != nil && [.review, .blocked, .stopped].contains($0.state)]
    }
    let counts: [String: Int] = ["visible": visible.count, "working": visible.filter { $0.status == .working }.count,
      "needsInput": visible.filter { $0.status == .waiting }.count, "errors": visible.filter { $0.status == .error }.count,
      "managedTasks": tasks.count]
    let overview: String
    if !connected { overview = "Live agent connection is unavailable. Do not present cached tasks as current activity." }
    else if visible.isEmpty && tasks.isEmpty { overview = "No visible agent sessions or managed tasks are connected right now." }
    else { overview = "There are \(visible.count) visible agent sessions: \(counts["working"]!) working, \(counts["needsInput"]!) needing input, \(counts["errors"]!) errors. There are \(tasks.count) managed tasks. Summarize these agents without asking which one the user means." }
    let context: [String: Any] = ["connected": connected, "overview": overview, "counts": counts,
      "observedAgents": agents, "managedTasks": managed, "omittedObservedAgents": max(0, visible.count - agents.count),
      "limits": "Observed sessions expose project, status, tool activity, and request titles, not full task transcripts. Only managed tasks accept follow-up prompts. Use observedAgents even when managedTasks is empty."]
    guard let data = try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }
}
