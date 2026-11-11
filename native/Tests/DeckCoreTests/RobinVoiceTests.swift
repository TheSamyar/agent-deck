import XCTest
@testable import DeckCore

final class RobinVoiceTests: XCTestCase {
  func testSpokenApprovalRequiresCompleteUnchangedScope() {
    XCTAssertTrue(RobinVoiceReply.canApprove(context: "printf harmless"))
    for scope in ["", String(repeating: "a", count: 601), "The command was not provided.", "Bash requests permission in project.", "```sh\nrm file\n```", "/tmp/my_file"] {
      XCTAssertFalse(RobinVoiceReply.canApprove(context: scope), scope)
    }
  }
  func testAttentionEligibilityRespectsMuteEnabledAndSupportedChoices() async throws {
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"))
    let receipt = await engine.ingest(agent: "claude", event: "PermissionRequest", body: ["data": ["session_id": "eligibility", "cwd": "/work/quiet"]], decisionChannel: true)
    var snapshot = await engine.snapshot()
    var request = try XCTUnwrap(snapshot.requests.first)
    XCTAssertTrue(RobinVoiceReply.shouldAsk(request, in: snapshot))
    snapshot.preferences.mutedProjects = ["/work/quiet"]
    XCTAssertFalse(RobinVoiceReply.shouldAsk(request, in: snapshot))
    snapshot.preferences.mutedProjects = []; snapshot.preferences.enabledAgents = []
    XCTAssertFalse(RobinVoiceReply.shouldAsk(request, in: snapshot))
    snapshot.preferences.enabledAgents = ["claude"]; request.choices = [.init(id: "always", label: "Always allow")]
    XCTAssertFalse(RobinVoiceReply.shouldAsk(request, in: snapshot))
    await engine.cancelRequest(receipt.requestId!)
  }
  func testRepliesRequireWholeExplicitUtterances() {
    XCTAssertEqual(RobinVoiceReply.parse("Allow once."), .allow)
    XCTAssertEqual(RobinVoiceReply.parse("DENY"), .deny)
    for text in ["do not approve", "don't allow once", "Alfred said approve", "yes approve that and the other one", "", "maybe", "yes", "always allow"] {
      XCTAssertEqual(RobinVoiceReply.parse(text), .unclear, text)
    }
    XCTAssertEqual(RobinVoiceReply.parse("stop listening"), .stop)
    XCTAssertEqual(RobinVoiceReply.parse("later"), .later)
  }
  func testVoiceProofCannotBeUsedForAnotherRequestOrRevision() async throws {
    let engine = try DeckEngine(database: DeckDatabase(path:":memory:"))
    let first = await engine.ingest(agent:"claude",event:"PermissionRequest",body:["data":["session_id":"voice-first","cwd":"/test"]],decisionChannel:true)
    let second = await engine.ingest(agent:"claude",event:"PermissionRequest",body:["data":["session_id":"voice-second","cwd":"/test"]],decisionChannel:true)
    let id = try XCTUnwrap(first.requestId)
    let snapshot = await engine.snapshot()
    let revision = try XCTUnwrap(snapshot.requests.first { $0.id == id }?.revision)
    let tokenValue = await engine.prepareVoiceConfirmation(requestID:id)
    let token = try XCTUnwrap(tokenValue)
    var wrong = ActionCommand(action:"respond",sessionId:second.sessionId,requestId:second.requestId!,choiceId:"allow",revision:revision)
    wrong.voiceConfirmation = token
    let rejected = await engine.resolve(wrong); XCTAssertFalse(rejected.ok)
    let replay = await engine.resolve(wrong); XCTAssertFalse(replay.ok)
    let next = await engine.prepareVoiceConfirmation(requestID:id)
    var stale = ActionCommand(action:"respond",sessionId:first.sessionId,requestId:id,choiceId:"allow",revision:revision+1)
    stale.voiceConfirmation = next
    let result = await engine.resolve(stale); XCTAssertFalse(result.ok)
    await engine.cancelRequest(id); await engine.cancelRequest(second.requestId!)
  }
  func testExactVoiceProofSubmitsWithoutForgingHold() async throws {
    let engine = try DeckEngine(database: DeckDatabase(path:":memory:"))
    let receipt = await engine.ingest(agent:"claude",event:"PermissionRequest",body:["data":["session_id":"voice","cwd":"/test"]],decisionChannel:true)
    let id = try XCTUnwrap(receipt.requestId)
    let snapshot = await engine.snapshot()
    let revision = try XCTUnwrap(snapshot.requests.first { $0.id == id }?.revision)
    let waiter = Task { await engine.waitForDecision(id) }
    try await Task.sleep(for:.milliseconds(20))
    var command = ActionCommand(action:"respond",sessionId:receipt.sessionId,requestId:id,choiceId:"allow",revision:revision)
    command.voiceConfirmation = await engine.prepareVoiceConfirmation(requestID:id)
    XCTAssertEqual(command.heldMs,0)
    let result = await engine.resolve(command); XCTAssertTrue(result.ok)
    let decision = await waiter.value; XCTAssertEqual(decision,"allow")
    var duplicate = command; duplicate.id = UUID().uuidString
    let again = await engine.resolve(duplicate); XCTAssertFalse(again.ok)
  }
}
