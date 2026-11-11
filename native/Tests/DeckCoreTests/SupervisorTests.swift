import XCTest
@testable import DeckCore

final class SupervisorTests: XCTestCase {
  func testRobinIdentityRetainsActionEvidenceRules() {
    let instruction = SupervisorMemory().instruction
    XCTAssertTrue(instruction.contains(RobinIdentity.instruction))
    XCTAssertTrue(instruction.contains("Never claim an action happened unless the application reports success"))
  }
  func testLegacyActionControllerConfigurationSurvivesRobinRename() throws {
    var configuration = SupervisorConfiguration()
    configuration.jarvisEnabled = true
    let data = try JSONEncoder().encode(configuration)
    XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("jarvisEnabled"))
    XCTAssertEqual(try JSONDecoder().decode(SupervisorConfiguration.self, from: data).jarvisEnabled, true)
  }

  func testSpeechRemovesWholeEmojiSequencesWithoutRemovingNumbers() {
    let text = "Hello👋🏽 👨‍💻 🇺🇸 ❤️ 🙂 ✅ 1️⃣ 1. Check C++ and #123."
    let spoken = SupervisorSpeech.prepared(text)
    XCTAssertEqual(spoken, "Hello 1. Check C++ and #123.")
    XCTAssertEqual(SupervisorSpeech.prepared("Option 2 costs $25.50 in 2026."), "Option 2 costs $25.50 in 2026.")
    XCTAssertEqual(SupervisorSpeech.prepared("☺ ☀ ✨ 🚀"), "")
  }

  func testAgentOverviewIncludesObservedSessionsWithoutManagedTasks() async throws {
    let engine = DeckEngine(database: try DeckDatabase(path: ":memory:"))
    let receipt = await engine.ingest(agent: "claude", event: "UserPromptSubmit", body: ["data": ["session_id": "observed-only", "cwd": "/work/Website"], "env": ["ppid": 123]])
    var snapshot = await engine.snapshot()
    snapshot.sessions[receipt.sessionId]?.agentName = "Claude"
    snapshot.sessions[receipt.sessionId]?.status = .working
    snapshot.sessions[receipt.sessionId]?.detail = "Editing UI"
    let text = SupervisorContext.json(snapshot: snapshot, tasks: [], connected: true, local: true)
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    let agents = try XCTUnwrap(object["observedAgents"] as? [[String: Any]])
    XCTAssertEqual(agents.count, 1)
    XCTAssertEqual(agents.first?["agent"] as? String, "Claude")
    XCTAssertEqual(agents.first?["status"] as? String, "Working")
    XCTAssertEqual(agents.first?["control"] as? String, "observe only")
    XCTAssertEqual((object["managedTasks"] as? [Any])?.count, 0)
    let disconnected = SupervisorContext.json(snapshot: snapshot, tasks: [], connected: false, local: true)
    let offline = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(disconnected.utf8)) as? [String: Any])
    XCTAssertEqual((offline["observedAgents"] as? [Any])?.count, 0)
    snapshot.sessions[receipt.sessionId]?.status = .disconnected
    let ended = SupervisorContext.json(snapshot: snapshot, tasks: [], connected: true, local: true)
    let endedObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ended.utf8)) as? [String: Any])
    XCTAssertEqual((endedObject["observedAgents"] as? [Any])?.count, 0)
  }

  func testLiveLocalAgentOverviewDoesNotAskWhichAgent() async throws {
    guard ProcessInfo.processInfo.environment["AGENT_DECK_TEST_LOCAL_MODEL"] == "1" else { throw XCTSkip("Requires the local model") }
    let engine = DeckEngine(database: try DeckDatabase(path: ":memory:"))
    let receipt = await engine.ingest(agent: "claude", event: "UserPromptSubmit", body: ["data": ["session_id": "observed-only", "cwd": "/work/Website"], "env": ["ppid": 123]])
    var snapshot = await engine.snapshot()
    snapshot.sessions[receipt.sessionId]?.agentName = "Claude"
    snapshot.sessions[receipt.sessionId]?.status = .working
    snapshot.sessions[receipt.sessionId]?.workspace = "Website"
    snapshot.sessions[receipt.sessionId]?.detail = "Editing UI"
    let context = SupervisorContext.json(snapshot: snapshot, tasks: [], connected: true, local: true)
    var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/v1/chat/completions")!)
    request.httpMethod = "POST"; request.timeoutInterval = 90
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "agent-deck-supervisor:latest", "reasoning_effort": "none", "max_tokens": 1200, "stream": false,
      "response_format": SupervisorResponseFormat.conversation.requestValue,
      "messages": [["role": "system", "content": SupervisorMemory().conversationInstruction(taskContext: context)],
        ["role": "assistant", "content": "To see what agents are working on, I need to know which specific agent you mean. Are you looking at the Code Agent?"],
        ["role": "user", "content": "What are my agents working on?"]]])
    let (data, _) = try await URLSession.shared.data(for: request)
    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let choices = try XCTUnwrap(body["choices"] as? [[String: Any]])
    let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
    let text = try XCTUnwrap(message["content"] as? String)
    let reply = try SupervisorConversationReply.decode(text).reply.lowercased()
    XCTAssertTrue(reply.contains("claude"), reply)
    XCTAssertTrue(reply.contains("website"), reply)
    XCTAssertFalse(reply.contains("which agent"), reply)
    XCTAssertFalse(reply.contains("could you clarify"), reply)
    XCTAssertFalse(reply.contains("code agent"), reply)
  }

  func testSpeechPreparationKeepsContentWithoutReadingMarkdownOrCode() {
    let text = "## Choices\n1. **Try Local** using [the guide](https://example.com).\n```sh\necho secret\n```\n- Keep it simple."
    let spoken = SupervisorSpeech.prepared(text)
    XCTAssertTrue(spoken.contains("Try Local"))
    XCTAssertTrue(spoken.contains("the guide"))
    XCTAssertTrue(spoken.contains("Keep it simple"))
    XCTAssertTrue(spoken.contains("code example in the app"))
    XCTAssertFalse(spoken.contains("echo secret"))
    XCTAssertFalse(spoken.contains("https://"))
    XCTAssertFalse(spoken.contains("**"))
    XCTAssertEqual(SupervisorSpeech.prepared(String(repeating: "x", count: 17000)).count, 16000)
  }
  func testSpeechSettingsMigrateWithoutSelectingTheRejectedMacVoice() throws {
    let original = SupervisorConfiguration()
    let migrated = try JSONDecoder().decode(SupervisorConfiguration.self, from: JSONEncoder().encode(original))
    XCTAssertNil(migrated.localSpeechEngine)
    XCTAssertNil(migrated.localSpeechVoice)
    XCTAssertEqual(SupervisorSpeech.voices.first, "af_heart")
    XCTAssertTrue(SupervisorSpeech.voices.contains("am_michael"))
  }

  func testLiveLocalConversationContract() async throws {
    guard ProcessInfo.processInfo.environment["AGENT_DECK_TEST_LOCAL_MODEL"] == "1" else {
      throw XCTSkip("Opt in with AGENT_DECK_TEST_LOCAL_MODEL=1; never downloads or calls a cloud provider.")
    }
    var messages = [["role": "system", "content": SupervisorMemory().conversationInstruction(taskContext: "[]")]]
    for prompt in ["Hello", "Can you hear me?", "Keep answers short and give me multiple choices with a recommendation."] {
      messages.append(["role": "user", "content": prompt])
      var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/v1/chat/completions")!)
      request.httpMethod = "POST"; request.timeoutInterval = 90
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "agent-deck-supervisor:latest",
        "messages": messages, "stream": false, "reasoning_effort": "none", "max_tokens": 1200,
        "response_format": SupervisorResponseFormat.conversation.requestValue])
      let (data, response) = try await URLSession.shared.data(for: request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
      let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      let choices = try XCTUnwrap(body["choices"] as? [[String: Any]])
      let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
      let text = try XCTUnwrap(message["content"] as? String)
      let reply = try SupervisorConversationReply.decode(text)
      XCTAssertFalse(reply.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      messages.append(["role": "assistant", "content": reply.reply])
    }
  }

  func testConversationSchemaRequiresSpeakableReplyAndSeparateProposals() throws {
    let format = SupervisorResponseFormat.conversation.requestValue
    XCTAssertEqual(format["type"] as? String, "json_schema")
    let json = try XCTUnwrap(format["json_schema"] as? [String: Any])
    XCTAssertEqual(json["strict"] as? Bool, true)
    let schema = try XCTUnwrap(json["schema"] as? [String: Any])
    XCTAssertEqual(schema["required"] as? [String], ["draft", "lesson", "reply"])
    XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    XCTAssertEqual(try SupervisorConversationReply.decode("{\"reply\":\"Hello. What should we work on?\",\"lesson\":null,\"draft\":null}").reply, "Hello. What should we work on?")
    XCTAssertThrowsError(try SupervisorConversationReply.decode("{\"message\":\"Hello\"}"))
    XCTAssertThrowsError(try SupervisorConversationReply.decode("{\"reply\":{\"text\":\"Hello\"}}"))
    XCTAssertThrowsError(try SupervisorConversationReply.decode("{\"reply\":\"   \"}"))
  }

  @MainActor func testVoiceSubmissionDoesNotCancelItsOwnRequest() async throws {
    let timer = SupervisorVoiceDebouncer()
    let finished = expectation(description: "Model request remains live after stopping the silence timer")
    timer.schedule(delay: .milliseconds(1)) {
      timer.cancel()
      do {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(10))
        finished.fulfill()
      } catch { XCTFail("Voice submission canceled its own model request: \(error)") }
    }
    await fulfillment(of: [finished], timeout: 2)
  }

  @MainActor func testNewSpeechReplacesPendingSubmission() async {
    let timer = SupervisorVoiceDebouncer()
    let finished = expectation(description: "Only the latest speech is submitted")
    timer.schedule(delay: .seconds(1)) { XCTFail("Old speech should not be submitted") }
    timer.schedule(delay: .milliseconds(1)) { finished.fulfill() }
    await fulfillment(of: [finished], timeout: 2)
    timer.cancel()
  }

  func testApprovedLessonIsSeededAndDuplicateApprovalDoesNotGrowMemory() {
    var memory = SupervisorMemory()
    XCTAssertEqual(memory.lessons.count, 1)
    memory.approveLesson("  " + memory.lessons[0].text + "  ")
    memory.approveLesson("   ")
    XCTAssertEqual(memory.lessons.count, 1)
    memory.approveLesson("Check mobile after UI changes.")
    XCTAssertEqual(memory.lessons.count, 2)
    XCTAssertTrue(memory.instruction.contains("Check mobile"))
  }

  func testTranscriptsAndLessonsSurviveRoundTrip() throws {
    var memory = SupervisorMemory()
    memory.messages.append(.init(role: "user", content: "What should I ask next?"))
    let restored = try JSONDecoder().decode(SupervisorMemory.self, from: JSONEncoder().encode(memory))
    XCTAssertEqual(restored.lessons, memory.lessons)
    XCTAssertEqual(restored.messages.first?.content, memory.messages.first?.content)
    XCTAssertTrue(restored.automaticProjects.isEmpty)
  }

  func testExistingMemoryMigratesWithoutAutoApprovingLessons() throws {
    let old = Data("{\"lessons\":[],\"messages\":[],\"automaticProjects\":[]}".utf8)
    let memory = try JSONDecoder().decode(SupervisorMemory.self, from: old)
    XCTAssertNil(memory.pendingLesson)
    XCTAssertNil(memory.audit)
    XCTAssertTrue(memory.lessons.isEmpty)
  }

  func testLocalModeCannotSendConversationOrKeyToRemoteHost() {
    var config = SupervisorConfiguration()
    XCTAssertNotNil(config.validatedURL)
    config.localEndpoint = "https://example.com/v1/chat/completions"
    XCTAssertNil(config.validatedURL)
    config.localEndpoint = "http://127.0.0.1.example.com/"
    XCTAssertNil(config.validatedURL)
    config.backend = .cloud; config.cloudEndpoint = "http://example.com/"
    XCTAssertNil(config.validatedURL)
    config.cloudEndpoint = "https://user:password@example.com/"
    XCTAssertNil(config.validatedURL)
    config.cloudEndpoint = "https://example.com/v1/chat/completions"
    XCTAssertNotNil(config.validatedURL)
  }

  func testAutopilotRequiresOptInFreshReviewSessionAndBoundedTurns() {
    var task = SupervisedTask(provider: .codex, cwd: "/project", goal: "Fix UI", criteria: "Mobile works")
    task.state = .review; task.session = "thread"
    let decision = SupervisorDecision(action: .followUp, prompt: "Check mobile.", reason: "No mobile evidence.")
    XCTAssertFalse(SupervisorDecision.mayAutomate(task: task, enabledProjects: [], decision: decision))
    XCTAssertTrue(SupervisorDecision.mayAutomate(task: task, enabledProjects: ["/project"], decision: decision))
    task.state = .blocked
    XCTAssertFalse(SupervisorDecision.mayAutomate(task: task, enabledProjects: ["/project"], decision: decision))
    task.state = .review; task.automaticTurns = 5
    XCTAssertFalse(SupervisorDecision.mayAutomate(task: task, enabledProjects: ["/project"], decision: decision))
    task.automaticTurns = 0; task.lastPrompt = decision.prompt
    XCTAssertFalse(SupervisorDecision.mayAutomate(task: task, enabledProjects: ["/project"], decision: decision))
    task.lastPrompt = ""; task.session = nil
    XCTAssertFalse(SupervisorDecision.mayAutomate(task: task, enabledProjects: ["/project"], decision: decision))
  }

  func testDecisionRejectsUnknownActionsEmptyPromptsAndInvalidJSON() throws {
    XCTAssertThrowsError(try SupervisorDecision.decode("looks good"))
    XCTAssertThrowsError(try SupervisorDecision.decode("{\"action\":\"execute\",\"prompt\":\"rm\",\"reason\":\"x\"}"))
    XCTAssertThrowsError(try SupervisorDecision.decode("{\"action\":\"followUp\",\"prompt\":\" \",\"reason\":\"x\"}"))
    XCTAssertEqual(try SupervisorDecision.decode("```json\n{\"action\":\"ask\",\"prompt\":\"\",\"reason\":\"Needs permission\"}\n```").action, .ask)
  }

  func testDocumentedAgentResultsAndPermissionDenials() {
    var claude = SupervisedOutput()
    claude.ingest(Data("{\"type\":\"system\",\"session_id\":\"claude-thread\"}".utf8), provider: .claude)
    claude.ingest(Data("{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"Could not edit\",\"permission_denials\":[{}]}".utf8), provider: .claude)
    XCTAssertEqual(claude.session, "claude-thread"); XCTAssertTrue(claude.failed); XCTAssertTrue(claude.completed)
    var codex = SupervisedOutput()
    for line in ["{\"type\":\"thread.started\",\"thread_id\":\"exact-thread\"}", "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Tests passed\"}}", "{\"type\":\"turn.completed\"}"] {
      codex.ingest(Data(line.utf8), provider: .codex)
    }
    XCTAssertEqual(codex.session, "exact-thread"); XCTAssertTrue(codex.completed); XCTAssertFalse(codex.failed)
    XCTAssertTrue(codex.result.contains("Tests passed"))
  }

  func testResumeUsesExactSessionWithoutPermissionBypass() {
    for provider in SupervisedProvider.allCases {
      let arguments = provider.arguments(session: "specific-thread", prompt: "Check tests")
      XCTAssertTrue(arguments.contains("specific-thread"))
      XCTAssertFalse(arguments.contains("--last")); XCTAssertFalse(arguments.contains("--continue"))
      XCTAssertFalse(arguments.contains("--force")); XCTAssertFalse(arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
    }
  }
}
