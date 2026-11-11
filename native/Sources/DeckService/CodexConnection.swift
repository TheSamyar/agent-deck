import DeckCore
import Foundation

actor CodexConnection {
  let engine: DeckEngine
  private var process: Process?
  private var processSubscriptionOnly = false
  private var input: FileHandle?
  private var sequence = 0
  private var replies: [Int: CheckedContinuation<[String: Any], Error>] = [:]
  private var threads: [String: (cwd: String, session: String, turn: String)] = [:]
  private var childParents: [String: String] = [:]
  private var childTurns: [String: String] = [:]
  private struct ItemKey: Hashable { let thread: String; let item: String }
  private var items: [ItemKey: [String: Any]] = [:]
  private var upstreamRequests: [String: String] = [:]
  init(engine: DeckEngine) { self.engine = engine }
  private func send(_ value: [String: Any]) throws {
    guard let input else { throw CocoaError(.executableNotLoadable) }
    try input.write(contentsOf: JSONSerialization.data(withJSONObject: value) + Data("\n".utf8))
  }
  private func rpc(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
    sequence += 1
    let id = sequence
    return try await withCheckedThrowingContinuation { continuation in
      replies[id] = continuation
      do { try send(["id": id, "method": method, "params": params]) } catch {
        replies.removeValue(forKey: id)?.resume(throwing: error)
      }
      Task {
        try? await Task.sleep(for: .seconds(15))
        self.timeout(id)
      }
    }
  }
  private func timeout(_ id: Int) {
    replies.removeValue(forKey: id)?.resume(
      throwing: NSError(
        domain: "Codex", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Codex did not answer. Check that the CLI is installed and signed in."
        ]))
  }
  private func subscriptionOnly() -> Bool {
    ManagedSubscriptionPolicy.enabled(configurationData: UserDefaults(suiteName: "com.aiagentdeck.app")?.data(forKey: "supervisor.configuration"))
  }
  private func subscriptionProblem(_ message: String) -> NSError {
    NSError(domain: "Codex", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
  }
  private func connect() async throws {
    let onlySubscriptions = subscriptionOnly()
    if process?.isRunning == true {
      guard processSubscriptionOnly == onlySubscriptions else {
        throw subscriptionProblem("The managed Codex connection uses an older billing policy. Finish its tasks and restart Agent Deck before starting another session.")
      }
      return
    }
    let env = ProcessInfo.processInfo.environment
    let candidates = [
      env["AGENT_DECK_CODEX_BINARY"] ?? "", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex")
        .path,
    ]
    guard
      let binary = candidates.first(where: {
        !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0)
      })
    else {
      throw NSError(
        domain: "Codex", code: 2,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Install and sign in to Codex CLI before starting a managed session."
        ])
    }
    let child = Process()
    var childEnvironment = onlySubscriptions ? ManagedSubscriptionPolicy.environment(env) : env
    childEnvironment["AGENT_DECK_HOST_INSTANCE"] = "managed-codex"
    childEnvironment["__CFBundleIdentifier"] = "com.aiagentdeck.app"
    child.environment = childEnvironment
    child.executableURL = URL(fileURLWithPath: binary)
    child.arguments = onlySubscriptions ? ManagedSubscriptionPolicy.codexAppServerArguments : ["app-server"]
    let stdin = Pipe()
    let stdout = Pipe()
    child.standardInput = stdin
    child.standardOutput = stdout
    child.standardError = FileHandle.nullDevice
    try child.run()
    process = child
    processSubscriptionOnly = onlySubscriptions
    input = stdin.fileHandleForWriting
    let handle = stdout.fileHandleForReading
    Task.detached { [weak self] in
      var buffer = Data()
      while true {
        let data = handle.availableData
        if data.isEmpty {
          await self?.disconnected()
          return
        }
        buffer.append(data)
        if buffer.count > 2_000_000 {
          child.terminate()
          await self?.disconnected()
          return
        }
        while let newline = buffer.firstIndex(of: 10) {
          let line = Data(buffer[..<newline])
          buffer.removeSubrange(...newline)
          if let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
            await self?.receive(value)
          }
        }
      }
    }
    _ = try await rpc(
      "initialize",
      ["clientInfo": ["name": "agent_deck", "title": "Agent Deck", "version": "0.2.0"]])
    try send(["method": "initialized", "params": [:]])
  }
  func start(cwd: String, prompt: String) async -> ActionResult {
    var directory: ObjCBool = false
    guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd, isDirectory: &directory),
      directory.boolValue, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return .failure("Choose an existing project folder and enter a task.") }
    do {
      try await connect()
      let onlySubscriptions = subscriptionOnly()
      if onlySubscriptions {
        guard processSubscriptionOnly else { throw subscriptionProblem("Billing policy changed during connection. Restart Agent Deck before starting another managed session.") }
        let account = try await rpc("account/read", ["refreshToken": false])
        guard ManagedSubscriptionPolicy.isChatGPTAccount(account) else {
          throw subscriptionProblem("Sign in to Codex with ChatGPT. Subscription-only mode blocks API-key accounts; no task was sent.")
        }
      }
      var threadParameters: [String: Any] = ["cwd": cwd]
      if onlySubscriptions { threadParameters.merge(ManagedSubscriptionPolicy.codexThreadConfiguration) { _, policy in policy } }
      let result = try await rpc("thread/start", threadParameters)
      if onlySubscriptions {
        let actualProvider = result["modelProvider"] as? String ?? (result["thread"] as? [String: Any])?["modelProvider"] as? String
        guard actualProvider == "openai" else {
          throw subscriptionProblem("Codex did not confirm the official OpenAI provider. No prompt was sent.")
        }
        // Recheck account immediately before inference, rather than trusting startup metadata.
        let account = try await rpc("account/read", ["refreshToken": false])
        guard ManagedSubscriptionPolicy.isChatGPTAccount(account), subscriptionOnly() else {
          throw subscriptionProblem("Codex subscription sign-in or billing policy changed. No prompt was sent.")
        }
      }
      guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
        return .failure("Codex returned an unsupported thread response.")
      }
      let receipt = await engine.ingest(
        agent: "codex", event: "SessionStart",
        body: [
          "data": ["session_id": id, "cwd": cwd],
          "env": [
            "bundleId": "com.aiagentdeck.app", "hostInstanceId": "managed-codex",
            "ppid": Int(process?.processIdentifier ?? 0),
          ],
        ])
      threads[id] = (cwd, receipt.sessionId, "")
      let turnResult = try await rpc(
        "turn/start", ["threadId": id, "input": [["type": "text", "text": prompt]]])
      if let turn = turnResult["turn"] as? [String: Any], let turnID = turn["id"] as? String {
        threads[id]?.turn = turnID
      }
      return .init(
        ok: true, state: "acknowledged",
        message: "Codex session started. Requests will appear in Attention.")
    } catch { return .failure(error.localizedDescription) }
  }
  func canInterrupt(sessionId: String) -> Bool {
    guard let root = threads.first(where: { $0.value.session == sessionId }) else { return false }
    return !root.value.turn.isEmpty || childTurns.contains { childParents[$0.key] == root.key && !$0.value.isEmpty }
  }
  func interrupt(sessionId: String) async -> ActionResult {
    guard let root = threads.first(where: { $0.value.session == sessionId }) else { return .failure("This Codex session is no longer connected.") }
    var targets = childTurns.filter { childParents[$0.key] == root.key && !$0.value.isEmpty }.map { ($0.key, $0.value) }
    if !root.value.turn.isEmpty { targets.append((root.key, root.value.turn)) }
    guard !targets.isEmpty else { return .failure("No interruptible turn is known. Open the session to manage its background work.") }
    do {
      for (thread, turn) in targets { _ = try await rpc("turn/interrupt", ["threadId": thread, "turnId": turn]) }
      return .init(ok: true, state: "acknowledged", message: "Codex acknowledged the root and known child interrupts")
    } catch { return .failure("Codex did not acknowledge every interrupt: \(error.localizedDescription)") }
  }
  private func receive(_ message: [String: Any]) async {
    if let id = message["id"] as? Int, message["method"] == nil,
      let continuation = replies.removeValue(forKey: id)
    {
      if let error = message["error"] as? [String: Any] {
        continuation.resume(
          throwing: NSError(
            domain: "Codex", code: error["code"] as? Int ?? 1,
            userInfo: [
              NSLocalizedDescriptionKey: error["message"] as? String ?? "Codex rejected the request"
            ]))
      } else {
        continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
      }
      return
    }
    guard let method = message["method"] as? String,
      let params = message["params"] as? [String: Any],
      let threadID = params["threadId"] as? String, let rootID = threads[threadID] != nil ? threadID : childParents[threadID], let thread = threads[rootID]
    else {
      if let id = message["id"] {
        try? send([
          "id": id,
          "error": [
            "code": -32601,
            "message": "Agent Deck does not support this request; no permission was granted.",
          ],
        ])
      }
      return
    }
    // An old completion must not clear a newer root's turn or work ledger.
    let incomingTurn = params["turnId"] as? String ?? (params["turn"] as? [String: Any])?["id"] as? String
    if rootID == threadID, method != "turn/started", let incomingTurn,
      !thread.turn.isEmpty, incomingTurn != thread.turn { return }
    var eventData: [String: Any] = ["session_id": rootID, "cwd": thread.cwd]
    if let turnID = params["turnId"] as? String ?? (params["turn"] as? [String: Any])?["id"] as? String { eventData["turn_id"] = turnID }
    var eventBody: [String: Any] = [
      "data": eventData,
      "env": [
        "bundleId": "com.aiagentdeck.app", "hostInstanceId": "managed-codex",
        "ppid": Int(process?.processIdentifier ?? 0),
      ],
    ]
    if let rpcID = message["id"],
      ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method)
    {
      if upstreamRequests[String(describing: rpcID)] != nil { return }
      let item = items[ItemKey(thread: threadID, item: params["itemId"] as? String ?? "")] ?? [:]
      let changes = item["changes"] as? [[String: Any]] ?? []
      let files = changes.map { change in
        (change["path"] as? String ?? "File") + "\n" + (change["diff"] as? String ?? "")
      }.joined(separator: "\n\n")
      let context =
        method.contains("fileChange")
        ? (files.isEmpty
          ? params["reason"] as? String
            ?? "File-change details were not provided. Deny this request if you cannot verify its scope."
          : files)
        : params["command"] as? String ?? item["command"] as? String ?? params["reason"] as? String
          ?? "The command was not provided. Deny this request if you cannot verify its scope."
      let rid = await engine.registerRequest(
        sessionId: thread.session,
        title: (rootID == threadID ? "" : "Subagent: ") + (method.contains("fileChange") ? "Allow file changes?" : "Allow command execution?"),
        context: context,
        choices: [
          .init(id: "allow", label: "Allow once", requiresHold: true),
          .init(id: "deny", label: "Deny"),
        ], source: "codex-app-server")
      upstreamRequests[String(describing: rpcID)] = rid
      Task {
        let decision = await engine.waitForDecision(rid)
        try? self.send([
          "id": rpcID, "result": ["decision": decision == "allow" ? "accept" : "decline"],
        ])
      }
    } else if method == "serverRequest/resolved", let requestID = params["requestId"],
      let rid = upstreamRequests.removeValue(forKey: String(describing: requestID))
    {
      await engine.upstreamResolved(rid, activeTurn: !(threads[rootID]?.turn.isEmpty ?? true) || childTurns.contains { childParents[$0.key] == rootID && !$0.value.isEmpty })
    } else if method == "item/started", let item = params["item"] as? [String: Any],
      let id = item["id"] as? String
    {
      items[ItemKey(thread: threadID, item: id)] = item
      await updateWork(item, started: true, threadID: threadID, rootID: rootID, body: eventBody)
    } else if method == "turn/started" {
      if let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String {
        threads[threadID]?.turn = id
      }
      if rootID == threadID { _ = await engine.ingest(agent: "codex", event: "UserPromptSubmit", body: eventBody) }
      else {
        childTurns[threadID] = (params["turn"] as? [String: Any])?["id"] as? String ?? ""
        eventData.removeValue(forKey: "turn_id"); eventData["agent_id"] = threadID; eventBody["data"] = eventData
        _ = await engine.ingest(agent: "codex", event: "SubagentStart", body: eventBody)
      }
    } else if method == "turn/completed" {
      if rootID == threadID {
        threads[threadID]?.turn = ""
        if let status = (params["turn"] as? [String: Any])?["status"] as? String, status == "failed" { eventData["error"] = true; eventBody["data"] = eventData }
        _ = await engine.ingest(agent: "codex", event: "Stop", body: eventBody)
      } else {
        childTurns.removeValue(forKey: threadID)
        eventData.removeValue(forKey: "turn_id"); eventData["agent_id"] = threadID; eventBody["data"] = eventData
        _ = await engine.ingest(agent: "codex", event: "SubagentStop", body: eventBody)
      }
    } else if method == "item/completed" {
      if let item = params["item"] as? [String: Any], let id = item["id"] as? String {
        items.removeValue(forKey: ItemKey(thread: threadID, item: id))
        await updateWork(item, started: false, threadID: threadID, rootID: rootID, body: eventBody)
      }
    }
  }
  private func updateWork(_ item: [String: Any], started: Bool, threadID: String, rootID: String, body: [String: Any]) async {
    for change in CodexWorkChanges.changes(item: item, started: started) {
      var envelope = body
      var data = body["data"] as? [String: Any] ?? [:]
      let event: String
      switch change {
      case .toolStarted(let id, let kind), .toolCompleted(let id, let kind):
        if threadID == rootID {
          data["tool_use_id"] = id; data["tool_name"] = kind
          event = started ? "PreToolUse" : "PostToolUse"
        } else {
          data.removeValue(forKey: "turn_id")
          data["work_id"] = threadID + ":" + id; data["work_kind"] = kind == "Bash" ? "shell" : "background"
          event = started ? "BackgroundWorkStarted" : "BackgroundWorkCompleted"
        }
      case .childCreated(let child):
        guard threads[child] == nil, child != rootID else { continue }
        childParents[child] = rootID
        data.removeValue(forKey: "turn_id"); data["agent_id"] = child; event = "SubagentStart"
      case .childState(let child, let status):
        guard childParents[child] == rootID else { continue }
        data.removeValue(forKey: "turn_id"); data["agent_id"] = child
        event = CodexWorkChanges.childTerminal(status) ? "SubagentStop" : "SubagentStart"
      }
      envelope["data"] = data
      _ = await engine.ingest(agent: "codex", event: event, body: envelope)
    }
  }
  private func disconnected() async {
    input = nil
    process = nil
    for continuation in replies.values {
      continuation.resume(throwing: URLError(.networkConnectionLost))
    }
    replies.removeAll()
    for thread in threads.values { await engine.markDisconnected(thread.session) }
    threads.removeAll()
    childParents.removeAll(); childTurns.removeAll()
    items.removeAll()
  }
}
