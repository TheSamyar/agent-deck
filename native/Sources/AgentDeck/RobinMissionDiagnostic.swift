import AppKit
import DeckCore
import Foundation

@MainActor enum RobinMissionDiagnostic {
  static func run() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("robin-proof-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"))
    let model = DeckModel(previewSnapshot: await engine.snapshot())
    for status in [0, 1] {
      let script = root.appendingPathComponent("test-\(status).sh")
      try "echo 'isolated acceptance check'; exit \(status)\n".write(to: script, atomically: true, encoding: .utf8)
      let runner = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Jarvis/project-command.py")
      let runtime = JarvisRuntime(deck: model, persist: false, commandRunnerURL: runner)
      runtime.grants = .init(); runtime.grants.projects = [root.path]
      let commandID = root.path + ":tests"
      runtime.grants.commandIDs = [commandID]
      runtime.commands = [.init(id: commandID, project: root.path, executable: "/bin/sh", arguments: [script.path, "test"])]
      runtime.receipts = []
      let journal = RobinMissionJournal(file: root.appendingPathComponent("mission-\(status).json"))
      runtime.journal = journal
      runtime.configuration.robinHybridEnabled = false
      runtime.onRouting = { message in fputs("Routing: \(message)\n", stderr) }
      _ = try await runtime.run("run tests", context: "The selected and approved project is \(root.path). Its only approved test command ID is \(commandID). Execute this exact command, then report its actual exit result.", lessons: "Diagnostic: no other files, commands, agents, or applications are approved.")
      let check = journal.current?.checks.contains { $0.succeeded && $0.verified } == true
      guard runtime.receipts.contains(where: { $0.action == .projectCommand }), check == (status == 0), (journal.current?.phase == .done) == (status == 0) else {
        throw NSError(domain: "RobinDiagnostic", code: status+1, userInfo: [NSLocalizedDescriptionKey: "Command verification failed for exit \(status). Mission: \(journal.current?.phase.rawValue ?? "missing")"])
      }
      print("PASS: real isolated command exit \(status); completion correctly \(status == 0 ? "verified" : "withheld").")
      if status == 0 {
        let other = root.appendingPathComponent("selected-other-project").path
        let scoped = JarvisRuntime(deck: model, persist: false, commandRunnerURL: runner)
        scoped.grants.projects = [root.path, other]
        scoped.grants.commandIDs = [commandID]
        scoped.commands = runtime.commands
        scoped.cloudProject = other
        scoped.configuration.robinHybridEnabled = false
        _ = try await scoped.run("run tests", context: "The selected project has no approved test command.", lessons: "No model call is needed.")
        guard !scoped.receipts.contains(where: { $0.action == .projectCommand }) else {
          throw NSError(domain: "RobinDiagnostic", code: 3, userInfo: [NSLocalizedDescriptionKey: "The command from another project was executed."])
        }
        print("PASS: selected project cannot execute another project's sole approved test command.")
      }
    }
  }
}
