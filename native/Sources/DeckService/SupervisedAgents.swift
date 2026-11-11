import DeckCore
import Foundation
import Darwin

private enum SupervisedProcessEvent: Sendable {
  case session(String)
  case finished(SupervisedOutput, Int32)
}

actor SupervisedAgents {
  private var tasks: [SupervisedTask] = []
  private var running: [String: Process] = [:]
  private var commands: [String: ActionResult] = [:]
  private let file: URL
  private var storageError: String?

  init() {
    let support = ProcessInfo.processInfo.environment["AGENT_DECK_SUPPORT"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Deck")
    file = support.appendingPathComponent("supervised-tasks.json")
    do {
      if FileManager.default.fileExists(atPath: file.path) {
        tasks = try JSONDecoder().decode([SupervisedTask].self, from: Data(contentsOf: file))
        for index in tasks.indices where tasks[index].state == .working {
          tasks[index].state = .blocked
          tasks[index].result = "The service restarted. The previous process is not attached. Review before continuing."
          tasks[index].revision += 1
        }
      }
    } catch { storageError = "Could not read supervised tasks: \(error.localizedDescription)" }
  }

  func list() -> [SupervisedTask] { tasks }
  private func originalProcessAlive(_ task: SupervisedTask) -> Bool {
    guard let pid = task.pid else { return false }
    guard let birth = task.processBirth else { return Darwin.kill(Int32(pid), 0) == 0 || errno == EPERM }
    return ProcessWitness.read(pid)?.birth == birth
  }

  private func save() throws {
    if let storageError { throw failure(storageError) }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(tasks).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
  private func failure(_ message: String) -> NSError {
    NSError(domain: "Supervisor", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
  private func binary(_ provider: SupervisedProvider) -> URL? {
    let envName = "AGENT_DECK_SUPERVISOR_" + provider.rawValue.uppercased() + "_BINARY"
    let override = ProcessInfo.processInfo.environment[envName]
    let dirs = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
      "/opt/homebrew/bin", "/usr/local/bin"]
    return (override.map { [$0] } ?? provider.executableNames.flatMap { name in dirs.map { $0 + "/" + name } })
      .first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
  }
  func availability() -> [String: Bool] {
    Dictionary(uniqueKeysWithValues: SupervisedProvider.allCases.map { ($0.rawValue, binary($0) != nil) })
  }
  func start(provider: SupervisedProvider, cwd: String, goal: String, criteria: String) -> ActionResult {
    var isDirectory: ObjCBool = false
    guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue,
      !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, goal.count <= 16000, criteria.count <= 16000 else {
      return .failure("Choose a project folder and enter a task (up to 16,000 characters).")
    }
    let task = SupervisedTask(provider: provider, cwd: cwd, goal: goal, criteria: criteria)
    guard !tasks.contains(where: { $0.cwd == task.cwd && ($0.state == .working || originalProcessAlive($0)) }) else {
      return .failure("Another supervised agent is working in this folder. Wait or stop it first.")
    }
    tasks.append(task)
    let result = launch(id: task.id, prompt: task.initialPrompt)
    if !result.ok { tasks.removeAll { $0.id == task.id }; try? save() }
    return result
  }
  func continueTask(id: String, revision: Int, prompt: String, automatic: Bool, command: String) -> ActionResult {
    if let previous = commands[command] { return previous }
    guard !command.isEmpty, let index = tasks.firstIndex(where: { $0.id == id }),
      tasks[index].revision == revision, tasks[index].state != .working, tasks[index].state != .done,
      tasks[index].session != nil, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      prompt.count <= 16000 else { return .failure("This task changed or cannot continue. Refresh its result.") }
    if automatic && (tasks[index].state != .review || tasks[index].automaticTurns >= 5 || tasks[index].lastPrompt == prompt) {
      return .failure("Autopilot paused. Review the task before sending another prompt.")
    }
    if originalProcessAlive(tasks[index]) { return .failure("The previous agent process is still running. Stop it before continuing.") }
    let result = launch(id: id, prompt: prompt)
    if result.ok && automatic { tasks[index].automaticTurns += 1; try? save() }
    commands[command] = result
    if commands.count > 500 { commands.removeAll(); commands[command] = result }
    return result
  }
  func setState(id: String, revision: Int, done: Bool) -> ActionResult {
    guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].revision == revision else {
      return .failure("The task changed. Refresh before continuing.")
    }
    if done && (tasks[index].state == .working || originalProcessAlive(tasks[index])) { return .failure("Wait for the agent to finish before marking complete.") }
    if !done {
      if let process = running[id] { if process.isRunning { process.terminate() } }
      else if originalProcessAlive(tasks[index]), let pid = tasks[index].pid {
        guard tasks[index].processBirth != nil else { return .failure("The old process identity could not be verified. Inspect it manually before continuing.") }
        Darwin.kill(Int32(pid), SIGTERM)
      }
      running.removeValue(forKey: id)
    }
    tasks[index].state = done ? .done : .stopped; tasks[index].revision += 1
    tasks[index].updatedAt = Date()
    do { try save(); return .init(ok: true, state: "acknowledged", message: done ? "Task marked complete." : "Agent process stopped. Review any external background work separately.") }
    catch { return .failure(error.localizedDescription) }
  }

  private func subscriptionOnly() -> Bool {
    ManagedSubscriptionPolicy.enabled(configurationData: UserDefaults(suiteName: "com.aiagentdeck.app")?.data(forKey: "supervisor.configuration"))
  }
  private func subscriptionTaskHelper() -> URL? {
    var ancestor = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    for _ in 0..<8 {
      if ancestor.pathExtension == "app" {
        let helper = ancestor.appendingPathComponent("Contents/Resources/Jarvis/subscription-task.py")
        return FileManager.default.fileExists(atPath: helper.path) ? helper : nil
      }
      ancestor.deleteLastPathComponent()
    }
    let debug = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Jarvis/subscription-task.py")
    return FileManager.default.fileExists(atPath: debug.path) ? debug : nil
  }

  private func launch(id: String, prompt: String) -> ActionResult {
    guard let index = tasks.firstIndex(where: { $0.id == id }), running[id] == nil else { return .failure("The task is already running.") }
    let task = tasks[index]
    guard !tasks.contains(where: { $0.id != id && $0.cwd == task.cwd && ($0.state == .working || originalProcessAlive($0)) }) else {
      return .failure("Another supervised agent is working in this project.")
    }
    guard let executable = binary(task.provider) else { return .failure("Install and sign in to \(task.provider.title) CLI first.") }
    let onlySubscriptions = subscriptionOnly()
    let helper = onlySubscriptions ? subscriptionTaskHelper() : nil
    if onlySubscriptions && helper == nil { return .failure("Subscription task launcher is missing. Reinstall Agent Deck; no API fallback was used.") }
    let process = Process(), output = Pipe(), errors = Pipe(), input = Pipe()
    // Foundation's waitUntilExit can leave a worker's run loop asleep after
    // termination. Register before launch so even short-lived children signal.
    let terminated = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in terminated.signal() }
    process.executableURL = executable; process.currentDirectoryURL = URL(fileURLWithPath: task.cwd)
    process.arguments = task.provider.arguments(session: task.session, prompt: prompt)
    if let helper {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
      process.arguments = [helper.path]
    }
    process.standardOutput = output; process.standardError = errors; process.standardInput = input
    let inheritedEnvironment = ProcessInfo.processInfo.environment
    var env = onlySubscriptions ? ManagedSubscriptionPolicy.environment(inheritedEnvironment) : inheritedEnvironment
    env["AGENT_DECK_HOST_INSTANCE"] = "supervisor-" + id
    process.environment = env
    do {
      tasks[index].state = .working; tasks[index].revision += 1; tasks[index].turns += 1
      tasks[index].lastPrompt = prompt; tasks[index].updatedAt = Date()
      try save()
      try process.run()
      running[id] = process
      tasks[index].pid = Int(process.processIdentifier)
      tasks[index].processBirth = ProcessWitness.read(Int(process.processIdentifier))?.birth
      try save()
      if onlySubscriptions {
        var payload: [String: Any] = ["provider": task.provider.rawValue, "binary": executable.path, "cwd": task.cwd, "prompt": prompt]
        if let session = task.session { payload["session"] = session }
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: payload))
      } else if task.provider != .cursor && task.provider != .gemini {
        try input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
      }
      try? input.fileHandleForWriting.close()
      let generation = tasks[index].revision
      Task.detached {
        let stderrTask = Task.detached { () -> String in
          await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
              var bounded = Data()
              while true {
                let chunk = errors.fileHandleForReading.availableData
                if chunk.isEmpty { break }; bounded.append(chunk); if bounded.count > 16000 { bounded = Data(bounded.suffix(16000)) }
              }
              continuation.resume(returning: String(decoding: bounded, as: UTF8.self))
            }
          }
        }
        // FileHandle reads and the termination wait block. Keep them off Swift's cooperative
        // executor so waiting agents cannot prevent HTTP handlers or state updates.
        let events = AsyncStream<SupervisedProcessEvent>(bufferingPolicy: .bufferingNewest(32)) { continuation in
          DispatchQueue.global(qos: .utility).async {
            var buffer = Data(), parsed = SupervisedOutput()
            var boundSession: String?
            while true {
              let chunk = output.fileHandleForReading.availableData
              if chunk.isEmpty { break }
              buffer.append(chunk)
              while let newline = buffer.firstIndex(of: 10) {
                parsed.ingest(Data(buffer[..<newline]), provider: task.provider)
                buffer.removeSubrange(...newline)
                if let session = parsed.session, boundSession != session {
                  boundSession = session
                  continuation.yield(.session(session))
                }
              }
              if buffer.count > 2_000_000 { if process.isRunning { process.terminate() }; break }
            }
            if !buffer.isEmpty { parsed.ingest(buffer, provider: task.provider) }
            terminated.wait()
            continuation.yield(.finished(parsed, process.terminationStatus))
            continuation.finish()
          }
        }
        var completed = (SupervisedOutput(), Int32(1))
        for await event in events {
          switch event {
          case .session(let session):
            await self.bindSession(id: id, generation: generation, session: session)
          case .finished(let parsed, let code):
            completed = (parsed, code)
          }
        }
        let stderr = await stderrTask.value
        await self.finished(id: id, generation: generation, parsed: completed.0, code: completed.1, stderr: stderr)
      }
      Task {
        try? await Task.sleep(for: .seconds(1800))
        self.expire(id: id, generation: generation)
      }
      return .init(ok: true, state: "acknowledged", message: "\(task.provider.title) is working on the task.")
    } catch {
      if process.isRunning { process.terminate() }
      running.removeValue(forKey: id)
      tasks[index].state = .blocked; tasks[index].result = error.localizedDescription
      try? save()
      return .failure(error.localizedDescription)
    }
  }
  private func expire(id: String, generation: Int) {
    guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].revision == generation,
      tasks[index].state == .working else { return }
    if let process = running[id], process.isRunning { process.terminate() }; running.removeValue(forKey: id)
    tasks[index].state = .blocked; tasks[index].revision += 1
    tasks[index].result = "The turn exceeded 30 minutes. Review the agent before continuing."
    try? save()
  }
  private func bindSession(id: String, generation: Int, session: String) {
    guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].revision == generation else { return }
    tasks[index].session = session
    do { try save() } catch { storageError = error.localizedDescription }
  }
  private func finished(id: String, generation: Int, parsed: SupervisedOutput, code: Int32, stderr: String) {
    guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].revision == generation else { return }
    running.removeValue(forKey: id)
    tasks[index].session = parsed.session ?? tasks[index].session
    tasks[index].pid = nil; tasks[index].processBirth = nil
    tasks[index].result = parsed.result.isEmpty ? String(stderr.suffix(16000)) : parsed.result
    tasks[index].state = code == 0 && parsed.completed && !parsed.failed && tasks[index].session != nil ? .review : .blocked
    if tasks[index].result.isEmpty { tasks[index].result = "No readable result was returned. Review this agent before continuing."; tasks[index].state = .blocked }
    tasks[index].revision += 1; tasks[index].updatedAt = Date()
    do { try save() } catch { storageError = error.localizedDescription }
  }
}
