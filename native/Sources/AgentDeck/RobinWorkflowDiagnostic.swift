import Foundation
import DeckCore

/// Real runtime/command executor with scripted reasoning. No account, mic, or live-model claims.
@MainActor enum RobinWorkflowDiagnostic {
  static func run() async throws {
    func require(_ condition:Bool,_ message:String) throws {if !condition {throw RobinProviderError(message)}}
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("robin-workflow-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:root)}
    let engine=try DeckEngine(database:DeckDatabase(path:":memory:"))
    let deck=DeckModel(previewSnapshot:await engine.snapshot())
    var prompts:[String]=[]
    let runtime=JarvisRuntime(deck:deck,persist:false,reasoningFixture:{ messages in
      let goal=messages.last?["content"] ?? "";prompts.append(goal)
      let step=JarvisStep(kind:prompts.count % 2 == 1 ? .clarify : .respond,reply:prompts.count % 2 == 1 ? "Should we review evidence or prepare the meeting?" : "The selected next step is retained.")
      return String(decoding:try JSONEncoder().encode(step),as:UTF8.self)
    })
    var history:[[String:String]]=[];var pending:RobinConversationQuestion?
    for index in 0..<10 {
      let answer=index % 2 == 0 ? "Workflow turn \(index): help me choose the next step" : "the second one"
      let goal=pending.map {$0.continuing(with:answer)} ?? answer
      let response=try await runtime.run(goal,context:"Approved diagnostic project: "+root.path,lessons:"",history:history)
      if index % 2 == 1 {try require(prompts.last?.contains("Original request:") == true && prompts.last?.contains("the second one") == true,"Follow-up lost original request")}
      pending=runtime.isClarifying ? .init(project:root.path,goal:goal,question:response) : nil
      history += [["role":"user","content":answer],["role":"assistant","content":response]]
    }
    try require(runtime.receipts.isEmpty,"Conversation unexpectedly ran a tool")
    let marker=root.appendingPathComponent("execution-count")
    let runner=Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Jarvis/project-command.py")
    let debug=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Jarvis/project-command.py")
    var calls=0
    let worker=JarvisRuntime(deck:deck,persist:false,commandRunnerURL:FileManager.default.fileExists(atPath:runner.path) ? runner : debug,reasoningFixture:{ _ in
      calls+=1
      let step = calls == 1 ? JarvisStep(kind:.act,action:.projectCommand,arguments:.init(project:root.path,commandID:"diagnostic")) : JarvisStep(kind:.respond,reply:"The command receipt is available.")
      return String(decoding:try JSONEncoder().encode(step),as:UTF8.self)
    })
    worker.grants.projects=[root.path];worker.grants.commandIDs=["diagnostic"]
    worker.commands=[.init(id:"diagnostic",project:root.path,executable:"/usr/bin/python3",arguments:["-c","from pathlib import Path;p=Path('execution-count');p.write_text(str(int(p.read_text())+1) if p.exists() else '1')"])]
    _=try await worker.run("Execute the approved diagnostic command once",context:"",lessons:"")
    try require(worker.receipts.contains {$0.action == .projectCommand && $0.succeeded && $0.verified},"Actual command lacked verified receipt")
    worker.cancel()
    _=try await worker.run("Report the existing result without another action",context:"",lessons:"")
    let count=try String(contentsOf:marker)
    try require(count == "1","Cancellation/reply replayed the command")
    try await AlfredRuntimeDiagnostic.run()
    print("PASS: ten runtime conversation turns retain follow-ups; actual approved local command verified once and not replayed after cancellation. Scripted reasoning; microphone, speaker and external accounts were not exercised.")
  }
}
