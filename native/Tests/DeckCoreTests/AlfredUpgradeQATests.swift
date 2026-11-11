import XCTest
@testable import DeckCore

final class AlfredUpgradeQATests: XCTestCase {
  func testUnchangedRecognitionCannotFinalizeOngoingSpeechOrExtendQuietIndefinitely() {
    var policy = AlfredTurnPolicy()
    policy.update(transcript: "Inspect the selected project now", at: 0)
    for time in 1...20 {
      policy.speech(active: true, at: Double(time))
      policy.update(transcript: "Inspect the selected project now", at: Double(time))
      XCTAssertFalse(policy.shouldFinish(at: Double(time)))
    }
    policy.speech(active: false, at: 20.1)
    policy.update(transcript: "Inspect the selected project now", at: 20.8)
    XCTAssertFalse(policy.shouldFinish(at: 20.8))
    XCTAssertTrue(policy.shouldFinish(at: 21.1))
  }
  func testTranscriptCorrectionRestartsStabilityButRetainsAcousticSilence() {
    var policy = AlfredTurnPolicy()
    policy.update(transcript: "Inspect the current project now", at: 0)
    policy.speech(active: true, at: 0.1); policy.speech(active: false, at: 0.2)
    policy.update(transcript: "Inspect the selected project now", at: 2)
    XCTAssertFalse(policy.shouldFinish(at: 2.2))
    XCTAssertTrue(policy.shouldFinish(at: 2.4))
  }
  func testLibraryDecodeCannotBypassAliasValidationOrScopeValidation() throws {
    let invalid = AlfredSkillLibrary(skills: [
      .init(name: "First", aliases: ["same"], instructions: "Observe"),
      .init(name: "Second", aliases: ["SAME"], instructions: "Observe")
    ])
    XCTAssertThrowsError(try AlfredSkillLibrary.decode(JSONEncoder().encode(invalid)))
    let relative = AlfredSkillLibrary(skills: [.init(name: "Relative", instructions: "Observe", project: "../../private")])
    XCTAssertThrowsError(try AlfredSkillLibrary.decode(JSONEncoder().encode(relative)))
  }
  func testSkillAliasesCannotShadowStopApprovalOrPendingReplies() throws {
    for alias in ["STOP!", " cancel ", "stop what you are doing", "stop listening", "approve", "allow once", "yes", "no", "later", "not now", "repeat", "save it"] {
      var library = AlfredSkillLibrary()
      XCTAssertThrowsError(try library.upsert(.init(name: "Control hijack", aliases: [alias], instructions: "Open an app")), alias)
      let unchecked = AlfredSkillLibrary(skills: [.init(name: "Control hijack", aliases: [alias], instructions: "Open an app")])
      XCTAssertNil(unchecked.match(alias), alias)
      XCTAssertThrowsError(try AlfredSkillLibrary.decode(JSONEncoder().encode(unchecked)), alias)
    }
    var explicit = AlfredSkillLibrary()
    try explicit.upsert(.init(name: "Stop", instructions: "Describe stopping safely"))
    XCTAssertNotNil(explicit.match("run skill Stop"))
    XCTAssertNil(explicit.match("stop"))
  }
  func testActionMetadataRetainsExactOpaqueTargetAndRevisionWithoutTypedText() {
    let revision = UUID().uuidString
    let event = AlfredActionEvent(turnID: UUID(), step: .init(kind: .act, action: .typeText,
      arguments: .init(application: "com.example.Editor", text: "PRIVATE-TYPED-CONTENT", target: "element-12", revision: revision)))
    XCTAssertEqual(event.targetID, "element-12")
    XCTAssertEqual(event.observationRevision, revision)
    XCTAssertTrue(event.target.contains("element-12"))
    XCTAssertFalse(String(reflecting: event).contains("PRIVATE-TYPED-CONTENT"))
    let command = AlfredActionEvent(turnID: UUID(), step: .init(kind: .act, action: .projectCommand,
      arguments: .init(project: "/private/example/project", commandID: "/private/example/project:tests")))
    XCTAssertEqual(command.commandID, "/private/example/project:tests")
    XCTAssertFalse(command.target.contains("/private/"))
  }
  func testSkillInvocationPinsCurrentApprovedScopeBeforeConversationResolution() throws {
    let selected = "/tmp/alfred-selected"
    let previous = "/tmp/alfred-old-conversation"
    let pinned = "/tmp/alfred-pinned"
    let canonical: (String) -> String = { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
    let unpinned = AlfredSkill(name: "Review", instructions: "Review finished agents")
    XCTAssertEqual(try unpinned.resolvedProject(selectedProject: selected, approvedProjects: [selected, previous]), canonical(selected))
    XCTAssertThrowsError(try unpinned.resolvedProject(selectedProject: selected, approvedProjects: [previous]))
    XCTAssertThrowsError(try unpinned.resolvedProject(selectedProject: nil, approvedProjects: [previous]))
    let explicit = AlfredSkill(name: "Pinned", instructions: "Observe", project: pinned)
    XCTAssertEqual(try explicit.resolvedProject(selectedProject: selected, approvedProjects: [selected, pinned]), canonical(pinned))
    XCTAssertThrowsError(try explicit.resolvedProject(selectedProject: selected, approvedProjects: [selected]))
    XCTAssertThrowsError(try AlfredSkill(name: "Bad", instructions: "Observe", project: "relative").resolvedProject(selectedProject: selected, approvedProjects: [selected]))
  }
  func testDeferredQuestionPersistsIndependentlyOfNewTask() throws {
    var memory = SupervisorMemory()
    let old = RobinConversationQuestion(project: "/old", goal: "Review result", question: "Inspect tests or logs?")
    memory.deferredConversationQuestions = [old]
    memory.conversationQuestion = .init(project: "/new", goal: "Start workday", question: "Which project?")
    let restored = try JSONDecoder().decode(SupervisorMemory.self, from: JSONEncoder().encode(memory))
    XCTAssertEqual(restored.deferredConversationQuestions, [old])
    XCTAssertEqual(restored.conversationQuestion?.project, "/new")
    XCTAssertTrue(restored.deferredConversationQuestions![0].continuing(with: "the second one").contains("Inspect tests or logs?"))
  }
}
