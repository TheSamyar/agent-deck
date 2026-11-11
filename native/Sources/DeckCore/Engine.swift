import Foundation

public actor DeckEngine {
  private var sessions: [String: SessionSnapshot]
  private var workLedgers: [String: SessionWorkLedger] = [:]
  private var requests: [String: PendingRequest] = [:]
  private var decisions: [String: CheckedContinuation<String?, Never>] = [:]
  private var history: [ActivityEvent]
  private var handoffHistory: [AgentHandoff]
  private var handoffStates: [String: SessionState] = [:]
  private var preferences: DeckPreferences
  private let codexEvidenceLookup: @Sendable (String) -> CodexThreadEvidence.Kind
  private let database: DeckDatabase
  private var voiceProofs: [String: (request: String, revision: Int, expires: Double)] = [:]
  private var commandResults: [String: ActionResult] = [:]
  private let instanceId = UUID().uuidString
  private var generation = 1
  private var revision = 1
  private var signature = ""
  private var page = 0
  private var view = "overview"
  private var selected = ""
  private var manualOverview = false
  private var activeSet = ""
  private var lastResult: ActionResult?
  private var lastResultAt: Double = 0
  private var lastError = ""
  private var artworkCache: [String: String] = [:]
  public init(database: DeckDatabase, codexEvidenceLookup: @escaping @Sendable (String) -> CodexThreadEvidence.Kind = { CodexThreadEvidence.lookup($0) }) {
    self.codexEvidenceLookup = codexEvidenceLookup
    self.database = database
    self.sessions = database.load([String: SessionSnapshot].self, key: "sessions") ?? [:]
    self.preferences = database.load(DeckPreferences.self, key: "preferences") ?? DeckPreferences()
    self.handoffHistory = database.load([AgentHandoff].self, key: "handoffs") ?? []
    self.history = database.load([ActivityEvent].self, key: "history") ?? []
    // Restored sessions are evidence of past work, not proof of a live connection.
    for id in sessions.keys {
      sessions[id]?.work = nil
      sessions[id]?.status = .disconnected
      sessions[id]?.capabilities = Capabilities()
    }
  }
  private func persist() {
    for session in sessions.values {
      if handoffStates[session.id] != session.status, [.done,.waiting,.error].contains(session.status) {
        handoffHistory.insert(.init(id: session.id + ":" + String(session.updatedAt), sessionID: session.id,
          project: preferences.projectNames[session.projectKey] ?? session.workspace, state: session.status,
          timestamp: session.updatedAt, sessionMilliseconds: max(0,session.updatedAt-session.startedAt), canFocus: false), at:0)
      }
      handoffStates[session.id] = session.status
    }
    handoffHistory = Array(handoffHistory.filter { DeckClock.now-$0.timestamp < 7*86400000 }.prefix(100))

    requests = requests.filter { ["pending", "submitted"].contains($0.value.state) }
    generation += 1
    do {
      try database.save(sessions, key: "sessions")
      try database.save(preferences, key: "preferences")
      try database.save(history, key: "history")
      try database.save(handoffHistory, key: "handoffs")
    } catch { lastError = "Could not save session history. Check available disk space." }
  }
  private func record(_ title: String, session: String = "", outcome: String = "") {
    history.insert(
      ActivityEvent(timestamp: DeckClock.now, sessionId: session, title: title, outcome: outcome),
      at: 0)
    history = Array(history.filter { DeckClock.now - $0.timestamp < 7 * 86_400_000 }.prefix(1000))
  }
  public func updatePreferences(_ data: Data) throws {
    preferences = try JSONDecoder().decode(DeckPreferences.self, from: data)
    persist()
  }
  public func ingest(
    agent: String, event: String, body: [String: Any], decisionChannel: Bool = false
  ) -> (sessionId: String, requestId: String?) {
    let data = body["data"] as? [String: Any] ?? body
    let env = body["env"] as? [String: Any] ?? [:]
    let cwd =
      data["cwd"] as? String ?? (data["workspace_roots"] as? [String])?.first ?? env["pwd"]
      as? String ?? ""
    let provider =
      data["session_id"] as? String ?? data["sessionId"] as? String ?? data["thread-id"] as? String
      ?? data["threadId"] as? String ?? data["conversation_id"] as? String ?? data["conversationId"] as? String ?? ""
    let bundle = env["bundleId"] as? String ?? ""
    let pid = env["ppid"] as? Int ?? data["pid"] as? Int ?? 0
    let host = env["hostInstanceId"] as? String ?? bundle
    let id = SessionSnapshot.identity(
      agent: agent, providerID: provider, cwd: cwd, host: host, pid: pid)
    let now = DeckClock.now
    let eventKey = event.lowercased().filter(\.isLetter)
    let childTranscript = (data["transcript_path"] as? String ?? "").contains("/subagents/")
    let codexEvidence = agent == "codex" ? codexEvidenceLookup(provider) : .unknown
    let child = childTranscript || (["claude", "codex"].contains(agent) && !(data["agent_id"] as? String ?? "").isEmpty) || !(data["parent_thread_id"] as? String ?? data["parentThreadId"] as? String ?? "").isEmpty
      || eventKey == "subagentstart" || eventKey == "subagentstop"
      || (agent == "codex" && codexEvidence == .child)
    if ["subagentstart", "subagentstop"].contains(eventKey) {
      guard let existingParent = sessions[id], existingParent.status != .disconnected else { return (id, nil) }
      var ledger = workLedgers[id] ?? SessionWorkLedger()
      let wasBlocked = ledger.summary.needsInput == true
      _ = ledger.observe(event, data: data)
      if workLedgers.count < 2000 || workLedgers[id] != nil { workLedgers[id] = ledger }
      if var parent = sessions[id], parent.status != .disconnected {
        parent.work = ledger.summary
        if ledger.summary.needsInput == true { parent.status = .waiting; parent.detail = "Subagent needs input" }
        else if wasBlocked && parent.status == .waiting && !requests.values.contains(where: { $0.sessionId == id && $0.state == "pending" }) {
          parent.status = .working; parent.detail = ledger.summary.label
        }
        else if parent.status == .working && (ledger.summary.hasOutstanding || ledger.summary.awaitingResults) {
          parent.status = .working; parent.detail = ledger.summary.label
        }
        parent.updatedAt = now; parent.lastHookAt = now; sessions[id] = parent; persist()
      }
      return (id, nil)
    }
    if child {
      if var parent = sessions[id], parent.status != .disconnected {
        var ledger = workLedgers[id] ?? SessionWorkLedger()
        let wasBlocked = ledger.summary.needsInput == true
        ledger.observeChild(event, data: data); workLedgers[id] = ledger; parent.work = ledger.summary
        parent.updatedAt = now; parent.lastHookAt = now
        if ledger.summary.needsInput == true { parent.status = .waiting; parent.detail = "Subagent needs input" }
        else if wasBlocked && parent.status == .waiting && !requests.values.contains(where: { $0.sessionId == id && $0.state == "pending" }) {
          parent.status = .working; parent.detail = ledger.summary.label
        }
        sessions[id] = parent; persist()
      }
      return (id, nil)
    }
    if agent == "codex" && codexEvidence == .archived { return (id, nil) }
    var ledger = workLedgers[id] ?? SessionWorkLedger()
    guard ledger.observe(event, data: data) else { return (id, nil) }
    workLedgers[id] = ledger
    if !provider.isEmpty {
      for old in sessions.values
      where old.id != id && old.agentId == agent && old.providerSessionId.isEmpty && old.cwd == cwd
        && old.pid == pid
      { sessions.removeValue(forKey: old.id) }
    }
    if agent == "cursor" {
      for old in sessions.values
      where old.agentId == "cursor" && old.lastHookAt == 0
        && old.workspace == URL(fileURLWithPath: cwd).lastPathComponent
      { sessions.removeValue(forKey: old.id) }
    }
    var s =
      sessions[id]
      ?? SessionSnapshot(
        id: id, agentId: agent, agentName: agentName(agent),
        workspace: URL(fileURLWithPath: cwd).lastPathComponent, cwd: cwd,
        providerSessionId: provider, hostInstanceId: host, bundleId: bundle, pid: pid, tty: "",
        terminalId: "", status: .idle, detail: "Ready", tool: "", updatedAt: now, startedAt: now,
        lastHookAt: now, capabilities: Capabilities())
    if !bundle.isEmpty { s.bundleId = bundle }
    else if agent == "cursor" { s.bundleId = "com.todesktop.230313mzl4w4u92" }
    if pid > 0 { s.pid = pid }
    if let tty = env["tty"] as? String, !tty.isEmpty { s.tty = tty }
    if let terminal = env["terminalId"] as? String, !terminal.isEmpty { s.terminalId = terminal }
    if let name = data["workspace"] as? String { s.workspace = name }
    if !cwd.isEmpty { s.cwd = cwd }
    s.tool = String((data["tool_name"] as? String ?? data["tool"] as? String ?? s.tool).prefix(120))
    if let birth = env["processBirth"] as? String, !birth.isEmpty { s.processBirth = birth }
    s.lastHookAt = now
    s.updatedAt = now
    let key = event.lowercased().filter(\.isLetter)
    var requestId: String?
    switch key {
    case "sessionend":
      cancelRequests(sessionId: id)
      sessions.removeValue(forKey: id)
      workLedgers.removeValue(forKey: id)
      record("Session closed", session: id)
      persist()
      return (id, nil)
    case "sessionstart":
      s.status = .idle
      s.detail = "Ready"
    case "permissionrequest":
      s.status = .waiting
      s.detail = "Permission requested"
      if decisionChannel && ["claude", "codex"].contains(agent) {
        requestId = createApprovalRequest(agent: agent, key: key, session: s, data: data, now: now)
      }
    case "notification":
      let type = data["notification_type"] as? String ?? ""
      if type == "permission_prompt" || type == "elicitation_dialog" {
        s.status = .waiting
        s.detail = "Open the session to respond"
      }
    case "userpromptsubmit", "beforesubmitprompt", "beforeagent", "pretooluse", "beforetool",
      "preinvocation", "beforeshellexecution", "beforemcpexecution":
      if decisionChannel && preferences.toolHookApprovals == true
        && ((agent == "cursor" && ["beforeshellexecution", "beforemcpexecution"].contains(key))
          || (agent == "gemini" && key == "beforetool"))
      {
        s.status = .waiting
        s.detail = "Permission requested"
        requestId = createApprovalRequest(agent: agent, key: key, session: s, data: data, now: now)
      } else {
        s.status = .working
        s.detail = s.tool.isEmpty ? "Working" : s.tool
      }
    case "posttooluse", "aftertool", "aftermcpexecution", "aftershellexecution", "afterfileedit":
      s.status = .working
      s.detail = s.tool.isEmpty ? "Working" : "Completed \(s.tool)"
      acknowledgeRequests(sessionId: id, toolUseId: data["tool_use_id"] as? String ?? "")
    case "interrupt":
      s.status = .idle
      s.detail = "Interrupted"
      cancelRequests(sessionId: id)
    case "stop", "turnended", "afteragent":
      s.status = data["error"] == nil ? .done : .error
      s.detail = s.status == .done ? "Turn finished" : "Agent reported an error"
      if !requests.values.contains(where: { $0.sessionId == id && $0.state == "pending" }) { cancelRequests(sessionId: id) }
    default:
      if s.status == .disconnected {
        s.status = .idle
        s.detail = "Connected"
      }
    }
    if ["posttooluse", "posttoolusefailure", "aftertool", "aftermcpexecution", "aftershellexecution", "afterfileedit"].contains(key), [.done, .error].contains(sessions[id]?.status ?? .unknown),
      !ledger.summary.hasOutstanding && !ledger.summary.awaitingResults { s.status = sessions[id]?.status ?? .done; s.detail = s.status == .error ? "Agent reported an error" : "Turn finished" }
    s.work = ledger.summary
    if ledger.summary.needsInput == true { s.status = .waiting; s.detail = "Input needed" }
    else if ledger.summary.hasOutstanding || ledger.summary.awaitingResults {
      if s.status != .waiting && s.status != .error { s.status = .working; s.detail = ledger.summary.label }
    } else if ["stop", "turnended", "afteragent"].contains(key), ledger.summary.scheduledWakeups > 0 {
      s.status = .idle; s.detail = "Scheduled"
    }
    if requests.values.contains(where: { $0.sessionId == id && $0.state == "pending" }) {
      s.status = .waiting
      s.detail = "Permission requested"
    }
    if agent == "codex", eventKey == "turnended", codexEvidence == .unknown,
      host != "managed-codex", sessions[id] == nil {
      s.status = .unknown
      s.detail = "Codex thread provenance is unverified. Waiting for root-session registration."
    }
    s.capabilities.focus = s.bundleId == "com.todesktop.230313mzl4w4u92" || !s.tty.isEmpty
    s.capabilities.approve = requests.values.contains {
      $0.sessionId == id && $0.state == "pending"
    }
    s.capabilities.interrupt =
      !s.tty.isEmpty && ["com.apple.Terminal", "com.googlecode.iterm2"].contains(s.bundleId)
    s.capabilities.reason =
      s.capabilities.approve
      ? "Request-specific permission hook connected"
      : "Open the original session to answer unsupported requests."
    sessions[id] = s
    record(s.detail, session: id, outcome: s.status.rawValue)
    persist()
    return (id, requestId)
  }
  private func createApprovalRequest(
    agent: String, key: String, session: SessionSnapshot, data: [String: Any], now: Double
  ) -> String {
    let rid = UUID().uuidString
    func nonEmpty(_ value: Any?) -> String? {
      guard let text = value as? String, !text.isEmpty else { return nil }
      return text
    }
    let label: String
    if !session.tool.isEmpty {
      label = session.tool
    } else if key == "beforeshellexecution" {
      label = "Shell"
    } else if key == "beforemcpexecution" {
      label = nonEmpty(data["mcp_name"]) ?? "MCP tool"
    } else {
      label = "this action"
    }
    let input = data["tool_input"] as? [String: Any] ?? [:]
    let context =
      nonEmpty(input["command"])
      ?? nonEmpty(data["command"])
      ?? nonEmpty(input["file_path"])
      ?? nonEmpty(input["path"])
      ?? nonEmpty(input["dir_path"])
      ?? nonEmpty(data["file_path"])
      ?? nonEmpty(input["url"])
      ?? nonEmpty(data["reason"])
      ?? "\(label) requests permission in \(session.workspace)."
    requests[rid] = PendingRequest(
      id: rid, sessionId: session.id, title: "Allow \(label)?",
      context: context,
      choices: [
        .init(id: "allow", label: "Allow once", requiresHold: true),
        .init(id: "deny", label: "Deny"),
      ], createdAt: now, expiresAt: now + 300_000, state: "pending", revision: 1,
      source: "\(agent)-hook")
    requests[rid]?.toolUseId = data["tool_use_id"] as? String
    Task {
      try? await Task.sleep(for: .seconds(300))
      self.cancelRequest(rid, reason: "Request expired. Answer in the original session.")
    }
    return rid
  }
  public func registerRequest(
    sessionId: String, title: String, context: String, choices: [RequestChoice], source: String
  ) -> String {
    let id = UUID().uuidString
    let now = DeckClock.now
    requests[id] = PendingRequest(
      id: id, sessionId: sessionId, title: title, context: context, choices: choices,
      createdAt: now, expiresAt: now + 300_000, state: "pending", revision: 1, source: source)
    sessions[sessionId]?.status = .waiting
    sessions[sessionId]?.capabilities.approve = true
    record(title, session: sessionId, outcome: "WAITING")
    persist()
    Task {
      try? await Task.sleep(for: .seconds(300))
      self.cancelRequest(id)
    }
    return id
  }
  public func waitForDecision(_ id: String) async -> String? {
    guard requests[id]?.state == "pending" else { return nil }
    return await withCheckedContinuation { decisions[id] = $0 }
  }
  public func upstreamResolved(_ id: String, activeTurn: Bool = true) {
    let sessionID = requests[id]?.sessionId
    if requests[id]?.state == "submitted" {
      requests[id]?.state = "acknowledged"
      record(
        "Agent acknowledged the response", session: requests[id]?.sessionId ?? "",
        outcome: "acknowledged")
      persist()
    } else {
      cancelRequest(id)
    }
    if let sessionID, !requests.values.contains(where: { $0.sessionId == sessionID && $0.state == "pending" }) {
      workLedgers[sessionID]?.inputResolved()
      let work = workLedgers[sessionID]?.summary
      sessions[sessionID]?.work = work
      if sessions[sessionID]?.status == .waiting && work?.needsInput != true {
        let busy = activeTurn || work?.hasOutstanding == true || work?.awaitingResults == true
        sessions[sessionID]?.status = busy ? .working : .idle
        sessions[sessionID]?.detail = busy ? (work?.label ?? "Working") : "No active turn"
        persist()
      }
    }
  }
  public func cancelRequest(_ id: String, reason: String = "The request is no longer available.") {
    guard let request = requests[id], ["pending", "submitted"].contains(request.state) else {
      return
    }
    requests[id]?.state = "expired"
    if requests.values.filter({ $0.sessionId == request.sessionId && $0.state == "pending" })
      .isEmpty
    {
      sessions[request.sessionId]?.capabilities.approve = false
    }
    decisions.removeValue(forKey: id)?.resume(returning: nil)
    record(reason, session: request.sessionId, outcome: "expired")
    persist()
  }
  private func cancelRequests(sessionId: String) {
    for id in requests.values.filter({ $0.sessionId == sessionId }).map(\.id) { cancelRequest(id) }
  }
  private func acknowledgeRequests(sessionId: String, toolUseId: String) {
    guard !toolUseId.isEmpty else { return }
    for id in requests.values.filter({
      $0.sessionId == sessionId && $0.state == "submitted" && $0.toolUseId == toolUseId
    }).map(\.id) {
      requests[id]?.state = "acknowledged"
      record("Agent resumed after response", session: sessionId, outcome: "acknowledged")
    }
  }
  public func prepareVoiceConfirmation(requestID: String) -> String? {
    voiceProofs = voiceProofs.filter { $0.value.expires > DeckClock.now }
    guard voiceProofs.count < 32, let r = requests[requestID], r.state == "pending", r.expiresAt > DeckClock.now else { return nil }
    let token = UUID().uuidString
    voiceProofs[token] = (r.id, r.revision, min(r.expiresAt, DeckClock.now + 90000))
    return token
  }
  public func resolve(_ command: ActionCommand) -> ActionResult {
    if let prior = commandResults[command.id] { return prior }
    let result: ActionResult
    guard let request = requests[command.requestId], request.sessionId == command.sessionId,
      request.state == "pending", request.expiresAt > DeckClock.now
    else {
      return remember(.failure("This request has expired or was already answered.", id: command.id))
    }
    guard let choice = request.choices.first(where: { $0.id == command.choiceId }) else {
      return remember(.failure("This response is not supported.", id: command.id))
    }
    var voiceConfirmed = false
    if let token = command.voiceConfirmation {
      guard let proof = voiceProofs.removeValue(forKey: token), proof.request == request.id,
        proof.revision == request.revision, proof.expires > DeckClock.now,
        command.revision == request.revision,
        (choice.id == "deny" || (choice.id == "allow" && choice.label.lowercased().contains("once"))) else {
        return remember(.failure("The spoken question is no longer current.", id: command.id))
      }
      voiceConfirmed = true
    }
    if choice.requiresHold && command.heldMs < 700 && !voiceConfirmed {
      return .failure("Hold Allow for 0.7 seconds to confirm.", id: command.id)
    }
    guard let continuation = decisions.removeValue(forKey: request.id) else {
      return remember(
        .failure(
          "The permission hook disconnected. Answer in the original session.", id: command.id))
    }
    requests[request.id]?.state = "submitted"
    sessions[request.sessionId]?.capabilities.approve = requests.values.contains {
      $0.sessionId == request.sessionId && $0.state == "pending"
    }
    workLedgers[request.sessionId]?.inputResolved()
    continuation.resume(returning: choice.id)
    result = .init(
      ok: true, state: "submitted", message: "Response sent. Waiting for the agent.",
      commandId: command.id)
    record("Response sent: \(choice.label)", session: command.sessionId, outcome: "submitted")
    persist()
    return remember(result)
  }
  public func remember(_ result: ActionResult) -> ActionResult {
    lastResult = result
    lastResultAt = DeckClock.now
    generation += 1
    let time = lastResultAt
    Task {
      try? await Task.sleep(for: .seconds(8))
      self.expireFeedback(time)
    }
    if !result.ok { lastError = result.message } else { lastError = "" }
    if !result.commandId.isEmpty { commandResults[result.commandId] = result }
    if commandResults.count > 1000 { commandResults.removeAll(keepingCapacity: true) }
    return result
  }
  private func expireFeedback(_ time: Double) {
    if time == lastResultAt {
      lastResult = nil
      generation += 1
    }
  }
  public func priorResult(_ id: String) -> ActionResult? { commandResults[id] }
  public func version() -> Int { generation }
  public func sessionsForHealth() -> [SessionSnapshot] {
    for id in sessions.keys
    where sessions[id]?.status == .working
      && DeckClock.now - (sessions[id]?.lastHookAt ?? DeckClock.now) > 600_000
    {
      sessions[id]?.status = .unknown
      sessions[id]?.detail = "No recent updates. Open the session to check."
      generation += 1
    }
    return Array(sessions.values)
  }
  public func setCapabilities(_ id: String, focus: Bool, interrupt: Bool) {
    guard let s = sessions[id], s.status != .disconnected else { return }
    if s.capabilities.focus != focus || s.capabilities.interrupt != interrupt {
      sessions[id]?.capabilities.focus = focus
      sessions[id]?.capabilities.interrupt = interrupt
      generation += 1
    }
  }
  public func session(_ id: String) -> SessionSnapshot? { sessions[id] }
  public func setSelection(_ id: String) {
    if selected != id {
      selected = id
      generation += 1
    }
  }
  @discardableResult public func turnActive(_ delta: Int, from sessionID: String? = nil, handoffs: Bool = false) -> Bool {
    let current = snapshot()
    let all = handoffs ? AgentHandoff.records(current).compactMap { current.sessions[$0.sessionID] } : MasterHUBSurface.orderedSessions(current)
    guard !all.isEmpty else { return false }
    if let sessionID, !all.contains(where: { $0.id == sessionID }) { return false }
    let old = all.firstIndex(where: { $0.id == (sessionID ?? selected) }) ?? 0
    selected = all[((old + delta) % all.count + all.count) % all.count].id
    generation += 1
    return true
  }
  public func turn(_ delta: Int) {
    let all = orderedSessions()
    guard !all.isEmpty else { return }
    let old = all.firstIndex(where: { $0.id == selected }) ?? 0
    selected = all[((old + delta) % all.count + all.count) % all.count].id
    generation += 1
  }
  public func navigate(_ action: String, target: String = "") -> ActionResult {
    switch action {
    case "previous": page = max(0, page - 1)
    case "next": page += 1
    case "attention":
      view = "attention"
      page = 0
    case "overview", "toggle_mode", "mode":
      view = "overview"
      manualOverview = true
      activeSet = sessions.values.filter { [.working, .waiting].contains($0.status) }.map(\.id)
        .sorted().joined(separator: "|")
      page = 0
    case "select":
      selected = target
      view = "session"
      page = 0
    default: return .failure("Unknown navigation action")
    }
    generation += 1
    return .init(ok: true, state: "acknowledged", message: "View updated")
  }
  private func orderedSessions() -> [SessionSnapshot] {
    let enabled = sessions.values.filter { preferences.enabledAgents.contains($0.agentId) }
    let pins = preferences.pinnedSessionIds
    return enabled.sorted {
      let a = pins.firstIndex(of: $0.id) ?? Int.max
      let b = pins.firstIndex(of: $1.id) ?? Int.max
      return a != b
        ? a < b : ($0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt : $0.id < $1.id)
    }
  }
  public func synchronizeCursorWindows(_ titles: [String]) {
    // An editor window is not evidence that an agent session exists in it.
    let synthetic = sessions.values.filter { $0.hostInstanceId == "cursor-window" }.map(\.id)
    for id in synthetic { cancelRequests(sessionId: id); sessions.removeValue(forKey: id) }
    if !synthetic.isEmpty { persist() }
  }
  public func markUnverified(_ id: String) {
    guard let session = sessions[id], ![.disconnected, .unknown].contains(session.status) else { return }
    sessions[id]?.status = .unknown
    sessions[id]?.detail = "Session ownership is unverified. Waiting for a live root-session event."
    cancelRequests(sessionId: id)
    persist()
  }
  public func observeRunningProcess(_ id: String) {
    guard sessions[id]?.status == .disconnected, sessions[id]?.hostInstanceId != "managed-codex"
    else { return }
    sessions[id]?.status = .unknown
    sessions[id]?.detail = "Process is running. Open the session to check."
    sessions[id]?.capabilities.approve = false
    persist()
  }
  public func markDisconnected(_ id: String) {
    guard sessions[id]?.status != .disconnected else { return }
    sessions[id]?.status = .disconnected
    sessions[id]?.capabilities = Capabilities()
    sessions[id]?.work = nil; workLedgers.removeValue(forKey: id)
    cancelRequests(sessionId: id)
    persist()
  }
  public func setHealthError(_ message: String) {
    if lastError != message {
      lastError = message
      generation += 1
    }
  }
  public func migrateLegacy(_ data: Data) {
    guard sessions.isEmpty,
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let old = root["sessions"] as? [String: [String: Any]]
    else { return }
    for value in old.values where value["agentId"] as? String != "cursor" {
      let agent = value["agentId"] as? String ?? ""
      let oldState = value["status"] as? String ?? "IDLE"
      let event =
        oldState == "WAITING"
        ? "PermissionRequest"
        : oldState == "WORKING"
          ? "PreToolUse" : oldState == "DONE" || oldState == "ERROR" ? "Stop" : "SessionStart"
      var payload: [String: Any] = [
        "cwd": value["cwd"] as? String ?? "",
        "session_id": value["agentSessionId"] as? String ?? "",
        "tool_name": value["tool"] as? String ?? "",
      ]
      if oldState == "ERROR" { payload["error"] = "Previously reported agent error" }
      _ = ingest(
        agent: agent, event: event,
        body: [
          "data": payload,
          "env": [
            "bundleId": value["bundleId"] as? String ?? "", "ppid": value["pid"] as? Int ?? 0,
            "tty": value["tty"] as? String ?? "",
            "terminalId": value["terminalId"] as? String ?? "",
          ],
        ])
    }
  }
  public func snapshot() -> DeckSnapshot {
    let now = DeckClock.now
    for id in requests.values.filter({ $0.state == "pending" && $0.expiresAt <= now }).map(\.id) {
      cancelRequest(id)
    }
    for id in sessions.keys
    where sessions[id]?.status == .working && now - (sessions[id]?.lastHookAt ?? now) > 600_000 {
      sessions[id]?.status = .unknown
      sessions[id]?.detail = "No recent updates. Open the session to check."
    }
    let ordered = orderedSessions()
    let active = ordered.filter { [.working, .waiting].contains($0.status) }
    let currentActiveSet = active.map(\.id).sorted().joined(separator: "|")
    if currentActiveSet != activeSet {
      manualOverview = false
      activeSet = currentActiveSet
    }
    let pending = requests.values.filter { $0.state == "pending" }.sorted {
      $0.createdAt < $1.createdAt
    }
    let unstructured = ordered.filter { s in
      s.status == .waiting && !pending.contains(where: { $0.sessionId == s.id })
    }.sorted { $0.updatedAt < $1.updatedAt }
    let waitingCount = ordered.filter { $0.status == .waiting }.count
    if selected.isEmpty || sessions[selected] == nil { selected = ordered.first?.id ?? "" }
    let single =
      preferences.automaticSingleAgent && !manualOverview && active.count == 1
      && view != "attention"
    let mode =
      view == "attention"
      ? "attention" : single || view == "session" ? "single_agent" : "multi_instance"
    if single { selected = active[0].id }
    let keys = [
      "antigravity", "claude", "cursor", "gemini", "codex", "summary", "approve", "deny",
      "dashboard",
    ]
    var tiles: [TileSnapshot] = []
    let pages =
      mode == "attention"
      ? max(1, pending.count + unstructured.count)
      : mode == "multi_instance" ? max(1, (ordered.count + 5) / 6) : 1
    page = min(page, pages - 1)
    func tile(
      _ index: Int, _ label: String, _ subtitle: String = "", _ detail: String = "",
      action: String = "none", target: String = "", status: String = "IDLE", enabled: Bool = true
    ) -> TileSnapshot {
      TileSnapshot(
        key: keys[index], label: label, sublabel: subtitle, detail: detail, status: status,
        action: action, target: target, enabled: enabled)
    }
    if mode == "attention", page < pending.count {
      let request = pending[page]
      let owner = sessions[request.sessionId]
      tiles.append(
        tile(
          0, owner?.workspace ?? "Session", owner?.shortName ?? "", "Open session", action: "focus",
          target: request.sessionId, status: "WAITING"))
      tiles.append(
        tile(
          1, request.title, "REQUEST", "See full text in app", action: "dashboard",
          status: "WAITING"))
      tiles.append(
        tile(
          2, "Next request", "\(page + 1) OF \(pages)", action: "next", enabled: page + 1 < pages))
      for index in 0..<3 {
        if index < request.choices.count {
          let choice = request.choices[index]
          var t = tile(
            index + 3, choice.label, choice.requiresHold ? "HOLD TO CONFIRM" : "RESPONSE",
            action: "respond", target: request.sessionId, status: "WAITING")
          t.requestId = request.id
          t.choiceId = choice.id
          t.requiresHold = choice.requiresHold
          tiles.append(t)
        } else {
          tiles.append(tile(index + 3, "", enabled: false))
        }
      }
    } else if mode == "attention", !unstructured.isEmpty {
      let s = unstructured[min(page - pending.count, unstructured.count - 1)]
      tiles = [
        tile(
          0, s.workspace, s.shortName, "Needs your input", action: "focus", target: s.id,
          status: "WAITING", enabled: s.capabilities.focus),
        tile(
          1, "Open session", "RESPOND THERE", s.detail, action: "focus", target: s.id,
          enabled: s.capabilities.focus),
        tile(
          2, "Next request", "\(page + 1) OF \(pages)", action: "next", enabled: page + 1 < pages),
        tile(3, "On computer", "RESPONSE REQUIRED", enabled: false), tile(4, "", enabled: false),
        tile(5, "Open app", action: "dashboard"),
      ]
    } else if mode == "single_agent", let s = sessions[selected] {
      let title = preferences.projectNames[s.projectKey] ?? s.workspace
      tiles = [
        tile(
          0, title, s.shortName, s.status.label, action: "focus", target: s.id,
          status: s.status.rawValue),
        tile(
          1, "Open session", s.shortName, action: "focus", target: s.id,
          enabled: s.capabilities.focus),
        tile(2, s.tool.isEmpty ? "Ready" : s.tool, "CURRENT TOOL", action: "dashboard"),
        tile(
          3, "Requests", "\(waitingCount) WAITING", action: "attention",
          status: pending.isEmpty ? "IDLE" : "WAITING"),
        tile(
          4, "Stop", "HOLD TO CONFIRM", action: "stop", target: s.id,
          enabled: s.capabilities.interrupt), tile(5, "Open app", action: "dashboard"),
      ]
      tiles[4].requiresHold = true
    } else {
      let visible = Array(ordered.dropFirst(page * 6).prefix(6))
      for index in 0..<6 {
        if index < visible.count {
          let s = visible[index]
          tiles.append(
            tile(
              index, preferences.projectNames[s.projectKey] ?? s.workspace, s.shortName,
              s.status.label, action: "focus", target: s.id, status: s.status.rawValue,
              enabled: s.capabilities.focus))
        } else {
          tiles.append(tile(index, "No session", enabled: false))
        }
      }
    }
    tiles.append(
      tile(
        6, mode == "multi_instance" ? "Previous" : "Back", "\(page + 1) / \(pages)",
        action: mode == "multi_instance" ? "previous" : "overview",
        enabled: mode != "multi_instance" || page > 0))
    tiles.append(
      tile(
        7, "Attention", "\(waitingCount) WAITING", action: "attention",
        status: pending.isEmpty ? "IDLE" : "WAITING"))
    tiles.append(
      tile(
        8, mode == "multi_instance" ? "Next" : "Open app",
        action: mode == "multi_instance" ? "next" : "dashboard",
        enabled: mode != "multi_instance" || page + 1 < pages))
    let nextSignature = tiles.map {
      "\($0.key)|\($0.action)|\($0.target)|\($0.requestId)|\($0.choiceId)|\($0.enabled)"
    }.joined(separator: ";")
    if nextSignature != signature {
      revision += 1
      signature = nextSignature
    }
    for i in tiles.indices {
      let key = [
        tiles[i].key, tiles[i].label, tiles[i].sublabel, tiles[i].detail, tiles[i].status,
        String(tiles[i].enabled),
      ].joined(separator: "\u{0}")
      if let cached = artworkCache[key] {
        tiles[i].svg = cached
      } else {
        let svg = TileArtwork.render(tiles[i])
        artworkCache[key] = svg
        tiles[i].svg = svg
      }
    }
    if artworkCache.count > 500 { artworkCache.removeAll(keepingCapacity: true) }
    var dial = tile(
      0, sessions[selected]?.workspace ?? "Agent Deck", sessions[selected]?.shortName ?? "",
      "Open selected session", action: "focus", target: selected)
    dial.key = "dial"
    dial.svg = TileArtwork.render(dial)
    return DeckSnapshot(
      handoffs: handoffHistory, instanceId: instanceId, stateVersion: generation, timestamp: now, revision: revision, layoutMode: mode,
      selectedSessionId: selected, sessionCount: ordered.count, page: page, pageCount: pages,
      summary: DeckSummary(
        workingCount: active.filter { $0.status == .working }.count, waitingCount: waitingCount,
        doneCount: ordered.filter { $0.status == .done }.count,
        headline: waitingCount > 0 ? "\(waitingCount) need you" : "All clear"),
      sessions: Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) }), requests: pending,
      tiles: tiles, dial: dial, recentEvents: Array(history.prefix(100)),
      lastAction: now - lastResultAt < 8000 ? lastResult : nil, lastError: lastError,
      preferences: preferences)
  }
}
