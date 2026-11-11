import AppKit
import ApplicationServices
import Darwin
import DeckCore
import DeckTransport
import Foundation

actor ServiceRouter {
  let engine: DeckEngine
  let controls = MacControl()
  let token: String
  let port: Int
  let codex: CodexConnection
  let supervised = SupervisedAgents()
  let browser = JarvisBrowserBroker()
  var gui = NativeGUIBroker()
  var guiScanID: String?
  var voiceLeases: [String: String] = [:]
  var executing = false
  var bridges: [String: [String: Any]] = [:]
  var bridgeCommands: [String: [String: Any]] = [:]
  var bridgeResults: [String: ActionResult] = [:]
  init(engine: DeckEngine, token: String, port: Int) {
    self.engine = engine
    self.token = token
    self.port = port
    self.codex = CodexConnection(engine: engine)
  }
  func action(_ command: ActionCommand) async -> ActionResult {
    if let prior = await engine.priorResult(command.id) { return prior }
    guard !executing else { return .failure("Another action is finishing. Try again.") }
    executing = true
    defer { executing = false }
    var result: ActionResult
    switch command.action {
    case "respond":
      if let proof = command.voiceConfirmation {
        guard gui.connected, voiceLeases.removeValue(forKey: proof) == gui.clientID else {
          return .failure("Reconnect Alfred before answering by voice.")
        }
      }
      result = await engine.resolve(command)
    case "focus", "stop":
      guard let session = await engine.session(command.sessionId) else {
        return .failure("This session is no longer available.")
      }
      if session.status == .disconnected { return .failure("This session has ended.") }
      if let birth = session.processBirth, session.hostInstanceId != "managed-codex",
        ProcessWitness.read(session.pid)?.birth != birth {
        await engine.markDisconnected(session.id)
        return .failure("The original agent process has ended. Reconnect its session.")
      }
      if command.action == "stop" && command.heldMs < 700 {
        return .failure("Hold Stop for 0.7 seconds to confirm.")
      }
      if session.hostInstanceId == "managed-codex" {
        if command.action == "stop" {
          var interrupted = await codex.interrupt(sessionId: session.id)
          interrupted.commandId = command.id
          return await engine.remember(interrupted)
        }
        await engine.setSelection(session.id)
        return await actionOpenApp()
      }
      if command.action == "stop" {
        var interrupted = await controls.interrupt(session)
        interrupted.commandId = command.id
        return await engine.remember(interrupted)
      }
      if let bridge = findBridge(session), let instance = bridge["instanceId"] as? String,
        let terminal = bridge["targetTerminalId"] as? String
      {
        if command.action == "focus" {
          let raised = await focusInApp(session)
          guard raised.ok else { return await engine.remember(raised) }
        }
        bridgeCommands[instance] = [
          "id": command.id, "terminalId": terminal, "action": command.action,
        ]
        for _ in 0..<30 {
          if let reply = bridgeResults.removeValue(forKey: command.id) {
            if reply.ok { await engine.setSelection(session.id) }
            return await engine.remember(reply)
          }
          try? await Task.sleep(for: .milliseconds(100))
        }
        bridgeCommands.removeValue(forKey: instance)
        result = .failure("The editor did not acknowledge this action. Reconnect its extension.")
      } else {
        result = await focusInApp(session)
      }
    case "dashboard":
      let app = ProcessInfo.processInfo.environment["AGENT_DECK_APP"] ?? ""
      if !app.isEmpty {
        _ = await MainActor.run { NSWorkspace.shared.open(URL(fileURLWithPath: app)) }
      }
      result = .init(ok: true, state: "acknowledged", message: "Opened Agent Deck")
    default: result = await engine.navigate(command.action, target: command.sessionId)
    }
    if result.ok && command.action == "focus" { await engine.setSelection(command.sessionId) }
    result.commandId = command.id
    return await engine.remember(result)
  }
  func focusInApp(_ session: SessionSnapshot) async -> ActionResult {
    let request = NativeGUIControlRequest(kind: .focus, session: session)
    guard gui.enqueue(request) else {
      return .failure(gui.connected ? "Enable Accessibility for Agent Deck in Mac Permissions." : "Open Agent Deck to focus an agent window.")
    }
    defer { gui.cancel(request.id) }
    for _ in 0..<100 {
      if let reply = gui.take(request.id)?.result { return reply }
      if !gui.connected { break }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return .failure("Agent Deck did not acknowledge window focus. Open the app and try again.")
  }
  func actionOpenApp() async -> ActionResult {
    let app = ProcessInfo.processInfo.environment["AGENT_DECK_APP"] ?? ""
    if !app.isEmpty {
      _ = await MainActor.run { NSWorkspace.shared.open(URL(fileURLWithPath: app)) }
    }
    return .init(ok: true, state: "acknowledged", message: "Opened Agent Deck")
  }
  func findBridge(_ session: SessionSnapshot) -> [String: Any]? {
    let live = bridges.values.filter { DeckClock.now - ($0["updatedAt"] as? Double ?? 0) < 5000 }
    let matches = live.compactMap { bridge -> [String: Any]? in
      let terminals = bridge["terminals"] as? [[String: Any]] ?? []
      let match = terminals.filter { t in
        let pids = t["processTree"] as? [Int] ?? []
        return session.pid > 0 && pids.contains(session.pid)
      }
      guard match.count == 1, let terminal = match[0]["id"] as? String else { return nil }
      var value = bridge
      value["targetTerminalId"] = terminal
      return value
    }
    return matches.count == 1 ? matches[0] : nil
  }
  func handle(_ request: LocalRequest) async -> LocalResponse? {
    let path = URLComponents(string: request.path)?.path ?? request.path
    let parts = path.split(separator: "/").map(String.init)
    if !request.isUnix {
      guard
        ["127.0.0.1", "localhost"].contains(
          (request.headers["host"] ?? "").components(separatedBy: ":")[0]),
        request.headers["origin"] == nil
      else { return .json(ActionResult.failure("Local application access only"), status: 403) }
      guard request.headers["authorization"] == "Bearer \(token)" else {
        return .json(ActionResult.failure("Reconnect Agent Deck to authenticate."), status: 401)
      }
    }
    if request.method == "GET" && path == "/status" { return .json(await engine.snapshot()) }
    if request.method == "GET" && path == "/supervisor/tasks" { return .json(await supervised.list()) }
    if request.method == "GET" && path == "/supervisor/availability" { return .json(await supervised.availability()) }
    if request.method == "GET" && path == "/supervisor/browser" { return LocalResponse(body:(try? JSONSerialization.data(withJSONObject:await browser.status())) ?? Data("{}".utf8)) }
    if request.method == "GET" && path == "/health" {
      return .json(NativeGUIControlHealth(accessibilityGranted: gui.connected && gui.accessibilityGranted, guiConnected: gui.connected))
    }
    if request.method == "GET" && path == "/events" {
      LocalIO.write(
        Data(
          "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
            .utf8), fd: request.fd)
      var previousVersion = -1
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      while !LocalIO.disconnected(request.fd) {
        let version = await engine.version()
        if version != previousVersion {
          var snapshot = await engine.snapshot()
          snapshot.timestamp = 0
          if let encoded = try? encoder.encode(snapshot) {
            guard LocalIO.write(Data("data: ".utf8) + encoded + Data("\n\n".utf8), fd: request.fd)
            else { break }
            previousVersion = version
          }
        }
        try? await Task.sleep(for: .milliseconds(250))
      }
      return nil
    }
    guard request.method == "POST" else {
      return .json(ActionResult.failure("Unknown endpoint"), status: 404)
    }
    if path == "/supervisor/voice/prepare" {
      guard gui.connected, request.json["clientID"] as? String == gui.clientID,
        let id = request.json["requestID"] as? String,
        let proof = await engine.prepareVoiceConfirmation(requestID: id) else {
        return .json(ActionResult.failure("This request is no longer available."), status: 409)
      }
      if voiceLeases.count >= 32 { voiceLeases.removeAll() }
      voiceLeases[proof] = gui.clientID
      return .json(["token": proof])
    }
    if path == "/supervisor/voice/respond", let command = try? JSONDecoder().decode(ActionCommand.self, from: request.body), command.action == "respond", command.voiceConfirmation != nil {
      return .json(await action(command))
    }
    if path == "/gui/control" {
      guard let poll = try? JSONDecoder().decode(NativeGUIControlPoll.self, from: request.body) else {
        return .json(ActionResult.failure("Invalid Mac control message."), status: 400)
      }
      guard let delivery = gui.poll(poll) else {
        return .json(ActionResult.failure("A different app instance owns Mac controls."), status: 409)
      }
      return .json(delivery)
    }
    if parts.first == "hook" {
      guard request.isUnix else {
        return .json(ActionResult.failure("Hooks use the private socket"), status: 403)
      }
      let agent = parts.count > 1 ? parts[1] : "unknown"
      let event = parts.count > 2 ? parts[2] : "activity"
      let channel = request.json["awaitDecision"] as? Bool == true
      let receipt = await engine.ingest(
        agent: agent, event: event, body: request.json, decisionChannel: channel)
      if let id = receipt.requestId {
        let monitor = Task {
          while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            if LocalIO.disconnected(request.fd) {
              await engine.cancelRequest(id, reason: "Permission hook disconnected")
              break
            }
          }
        }
        let decision = await engine.waitForDecision(id)
        monitor.cancel()
        if let decision {
          let output: [String: Any]
          switch agent {
          case "cursor":
            output = ["permission": decision]
          case "gemini":
            output = ["decision": decision]
          default:
            output = [
              "hookSpecificOutput": [
                "hookEventName": "PermissionRequest", "decision": ["behavior": decision],
              ]
            ]
          }
          return LocalResponse(
            body: (try? JSONSerialization.data(withJSONObject: output)) ?? Data("{}".utf8))
        }
        return LocalResponse(
          body: Data((agent == "cursor" ? #"{"permission":"ask"}"# : "{}").utf8))
      }
      if channel {
        return LocalResponse(
          body: Data((agent == "cursor" ? #"{"permission":"ask"}"# : "{}").utf8))
      }
      return .json(["ok": true])
    }
    if path == "/codex/start" {
      return .json(
        await codex.start(
          cwd: request.json["cwd"] as? String ?? "", prompt: request.json["prompt"] as? String ?? ""
        ))
    }
    if path == "/supervisor/start" {
      guard let provider = SupervisedProvider(rawValue: request.json["provider"] as? String ?? "") else {
        return .json(ActionResult.failure("Choose Codex, Claude, Cursor, or Gemini."), status: 400)
      }
      return .json(await supervised.start(provider: provider, cwd: request.json["cwd"] as? String ?? "",
        goal: request.json["goal"] as? String ?? "", criteria: request.json["criteria"] as? String ?? ""))
    }
    if path == "/browser/poll" { return LocalResponse(body:(try? JSONSerialization.data(withJSONObject:await browser.poll(request.json))) ?? Data("{}".utf8)) }
    if path == "/supervisor/browser-command" { return LocalResponse(body:(try? JSONSerialization.data(withJSONObject:await browser.command(request.json))) ?? Data("{}".utf8)) }
    if path == "/supervisor/continue" {
      return .json(await supervised.continueTask(id: request.json["id"] as? String ?? "", revision: request.json["revision"] as? Int ?? -1,
        prompt: request.json["prompt"] as? String ?? "", automatic: request.json["automatic"] as? Bool ?? false,
        command: request.json["command"] as? String ?? ""))
    }
    if path == "/supervisor/state" {
      return .json(await supervised.setState(id: request.json["id"] as? String ?? "", revision: request.json["revision"] as? Int ?? -1,
        done: request.json["done"] as? Bool ?? false))
    }
    if path == "/preferences" {
      do {
        try await engine.updatePreferences(request.body)
        return .json(["ok": true])
      } catch { return .json(ActionResult.failure("Could not save settings"), status: 400) }
    }
    if path == "/bridge" {
      guard request.isUnix, let instance = request.json["instanceId"] as? String else {
        return .json(ActionResult.failure("Private editor connection required"), status: 403)
      }
      var value = request.json
      value["updatedAt"] = DeckClock.now
      bridges[instance] = value
      if let result = value["result"] as? [String: Any], let id = result["id"] as? String {
        bridgeResults[id] = ActionResult(
          ok: result["ok"] as? Bool ?? false,
          state: result["ok"] as? Bool == true ? "acknowledged" : "failed",
          message: result["message"] as? String ?? "Editor action completed", commandId: id)
      }
      let command = bridgeCommands.removeValue(forKey: instance) ?? [:]
      return LocalResponse(
        body: (try? JSONSerialization.data(withJSONObject: ["ok": true, "command": command]))
          ?? Data())
    }
    if path == "/action",
      let command = try? JSONDecoder().decode(ActionCommand.self, from: request.body)
    {
      return .json(await action(command))
    }
    if parts.first == "press" {
      let snapshot = await engine.snapshot()
      guard request.json["revision"] as? Int == snapshot.revision,
        request.json["instanceId"] as? String == snapshot.instanceId
      else {
        return .json(await engine.remember(.failure("The layout changed. Press the updated key.")))
      }
      let key = parts.count > 1 ? parts[1] : ""
      let index = Int(key)
      let tile =
        index.flatMap { snapshot.tiles.indices.contains($0) ? snapshot.tiles[$0] : nil }
        ?? snapshot.tiles.first(where: { $0.key == key })
      guard let tile, tile.enabled else {
        return .json(await engine.remember(.failure("This key is unavailable.")))
      }
      var held = request.json["heldMs"] as? Int ?? 0
      // Tap-only hardware gets an explicit confirmation page instead of an unsafe implicit approval.
      if tile.requiresHold && held < 700 {
        return .json(
          await engine.remember(
            .failure("Hold this key for 0.7 seconds. You can also confirm in the app.")))
      }
      held = min(held, 60_000)
      return .json(
        await action(
          .init(
            id: request.json["commandId"] as? String ?? UUID().uuidString, action: tile.action,
            sessionId: tile.target, requestId: tile.requestId, choiceId: tile.choiceId,
            revision: snapshot.revision, heldMs: held)))
    }
    if path == "/masterhub/turn" {
      let current = await engine.snapshot()
      guard request.json["instanceId"] as? String == current.instanceId,
        let delta = request.json["delta"] as? Int, (-1000...1000).contains(delta) else {
        return .json(ActionResult.failure("Reconnect before choosing an agent."), status: 409)
      }
      guard await engine.turnActive(delta, from: request.json["fromSessionId"] as? String, handoffs: request.json["page"] as? String == "handoffs") else {
        return .json(ActionResult.failure("The displayed agent is no longer active."), status: 409)
      }
      return .json(await engine.snapshot())
    }
    if path == "/dial/turn" {
      let delta =
        URLComponents(string: request.path)?.queryItems?.first(where: { $0.name == "delta" })?.value
        .flatMap(Int.init) ?? 1
      await engine.turn(delta)
      return .json(["ok": true])
    }
    if path == "/dial/press" {
      let snapshot = await engine.snapshot()
      return .json(
        await action(
          .init(
            action: "focus",
            sessionId: request.json["sessionId"] as? String ?? snapshot.selectedSessionId)))
    }
    return .json(ActionResult.failure("Unknown endpoint"), status: 404)
  }
  func scan() async {
    if let id = guiScanID, let reply = gui.take(id) {
      guiScanID = nil
      if let titles = reply.windowTitles { await engine.synchronizeCursorWindows(titles); await engine.setHealthError("") }
      else if let result = reply.result { await engine.setHealthError(result.message) }
    }
    if !gui.connected {
      await engine.setHealthError("Open Agent Deck to connect Mac window controls.")
    } else if !gui.accessibilityGranted {
      await engine.setHealthError("Enable Accessibility for Agent Deck in Mac Permissions.")
    } else {
      if let id = guiScanID { gui.cancel(id) }
      let scan = NativeGUIControlRequest(kind: .scanWindows)
      guiScanID = gui.enqueue(scan) ? scan.id : nil
    }
    let liveSessions = await engine.sessionsForHealth()
    for session in liveSessions {
      if session.hostInstanceId == "managed-codex" {
        await engine.setCapabilities(session.id, focus: true, interrupt: await codex.canInterrupt(sessionId: session.id))
      } else if findBridge(session) != nil {
        await engine.setCapabilities(session.id, focus: true, interrupt: true)
      } else {
        await engine.setCapabilities(
          session.id, focus: session.bundleId == MacControl.cursorBundle || !session.tty.isEmpty,
          interrupt: !session.tty.isEmpty
            && ["com.apple.Terminal", "com.googlecode.iterm2"].contains(session.bundleId))
      }
    }
    for session in liveSessions where session.hostInstanceId != "managed-codex" {
      if session.agentId == "codex" {
        let evidence = CodexThreadEvidence.lookup(session.providerSessionId)
        if evidence == .child || evidence == .archived { await engine.markDisconnected(session.id); continue }
      }
      guard session.pid > 0, session.pid <= Int(Int32.max) else { await engine.markUnverified(session.id); continue }
      guard let current = ProcessWitness.read(session.pid) else {
        if kill(Int32(session.pid), 0) != 0 && errno == ESRCH { await engine.markDisconnected(session.id) }
        else { await engine.markUnverified(session.id) }
        continue
      }
      if session.agentId == "cursor" {
        if let birth = session.processBirth, current.birth != birth { await engine.markDisconnected(session.id) }
        else if DeckClock.now - session.lastHookAt > 120_000 { await engine.markUnverified(session.id) }
        continue
      }
      do {
        if let birth = session.processBirth, current.birth != birth { await engine.markDisconnected(session.id); continue }
        if ProcessWitness.agentOwner(startingAt: session.pid, agent: session.agentId)?.pid != session.pid {
          await engine.markUnverified(session.id); continue
        }
      }

      if kill(Int32(session.pid), 0) != 0 && errno == ESRCH {
        await engine.markDisconnected(session.id)
      } else if kill(Int32(session.pid), 0) == 0 {
        await engine.observeRunningProcess(session.id)
      }
    }
  }
}

// This helper uses AppKit for window discovery, but must never become a foreground
// application competing with the dashboard's Launch Services registration.
NSApplication.shared.setActivationPolicy(.prohibited)

umask(0o077)
let environment = ProcessInfo.processInfo.environment
let support =
  environment["AGENT_DECK_SUPPORT"]
  ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Library/Application Support/Agent Deck"
  ).path
let runtime =
  environment["AGENT_DECK_RUNTIME"]
  ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Library/Caches/AgentDeck"
  ).path
let port = Int(environment["AGENT_DECK_PORT"] ?? "19420") ?? 19420
try FileManager.default.createDirectory(
  atPath: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let token = UUID().uuidString + UUID().uuidString
let database = try DeckDatabase(path: support + "/deck.sqlite")
let engine = DeckEngine(database: database)
let router = ServiceRouter(engine: engine, token: token, port: port)
let server = LocalServer()
do {
  try server.listen(
    port: UInt16(port), unixPath: runtime + "/deck.sock", handler: { await router.handle($0) })
  let endpoint: [String: Any] = [
    "protocolVersion": 2, "port": port, "token": token, "socketPath": runtime + "/deck.sock",
    "serviceBundleIdentifier": Bundle.main.bundleIdentifier ?? "unbundled",
    "servicePid": ProcessInfo.processInfo.processIdentifier,
    "serviceAccessibilityGranted": AXIsProcessTrusted(),
  ]
  let endpointData = try JSONSerialization.data(withJSONObject: endpoint)
  let endpointPath = runtime + "/connection.json"
  try endpointData.write(to: URL(fileURLWithPath: endpointPath), options: .atomic)
  chmod(endpointPath, 0o600)
  print("Agent Deck native service listening on 127.0.0.1:\(port)")
} catch {
  fputs("Agent Deck: \(error.localizedDescription)\n", stderr)
  exit(1)
}
Task {
  let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Library/Caches/ai-agent-deck/sessions.json")
  if environment["AGENT_DECK_DISABLE_SCAN"] != "1", let data = try? Data(contentsOf: legacy) {
    await engine.migrateLegacy(data)
  }
  if environment["AGENT_DECK_DISABLE_SCAN"] == "1" { return }
  while true {
    // A removed Unix socket cannot be recovered by keeping its old descriptor.
    // Exit so launchd (or the dashboard) recreates both endpoints together.
    if !FileManager.default.fileExists(atPath: runtime + "/connection.json")
      || !FileManager.default.fileExists(atPath: runtime + "/deck.sock") {
      fputs("Agent Deck: runtime endpoints disappeared; restarting service.\n", stderr)
      exit(1)
    }
    await router.scan()
    try? await Task.sleep(for: .seconds(2))
  }
}
RunLoop.main.run()
