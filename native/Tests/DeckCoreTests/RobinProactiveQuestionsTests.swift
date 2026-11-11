import XCTest
@testable import DeckCore

final class RobinProactiveQuestionsTests: XCTestCase {
  private func question(_ id: String) -> RobinProactiveQuestion {
    .init(id:id,project:"/project",reason:.blocker,evidence:"Tests failed.",question:"Investigate or pause?",recommendation:"Investigate first.")
  }
  func testOnePendingQuestionAndUnchangedEvidenceNeverRepeats() {
    var policy=RobinProactiveQuestions();let now=Date()
    XCTAssertNotNil(policy.offer(question("one"),now:now,available:true))
    XCTAssertNil(policy.offer(question("two"),now:now.addingTimeInterval(1000),available:true))
    policy.answer(now:now)
    XCTAssertNil(policy.offer(question("one"),now:now.addingTimeInterval(1000),available:true))
    XCTAssertNotNil(policy.offer(question("two"),now:now.addingTimeInterval(1000),available:true))
  }
  func testCooldownBusyGateAndSnooze() {
    var policy=RobinProactiveQuestions();let now=Date()
    XCTAssertNil(policy.offer(question("one"),now:now,available:false))
    XCTAssertNotNil(policy.offer(question("one"),now:now,available:true))
    policy.snooze(now:now)
    XCTAssertNil(policy.resume(now:now.addingTimeInterval(899)))
    XCTAssertEqual(policy.resume(now:now.addingTimeInterval(900))?.id,"one")
    policy.answer(now:now)
    XCTAssertNil(policy.offer(question("two"),now:now.addingTimeInterval(599),available:true))
    XCTAssertNotNil(policy.offer(question("two"),now:now.addingTimeInterval(600),available:true))
  }
  func testObservedBlockerIsNotReplayedAtLaunchAndWaitsForAvailability() async throws {
    let engine=try DeckEngine(database:DeckDatabase(path:":memory:"))
    var snapshot=await engine.snapshot();snapshot.preferences.enabledAgents=["codex"]
    let now=Date();snapshot.timestamp=now.timeIntervalSince1970*1000
    var task=SupervisedTask(provider:.codex,cwd:"/project",goal:"Run tests",criteria:"Tests pass")
    task.state = .working
    var policy=RobinProactiveQuestions()
    XCTAssertNil(policy.update(snapshot:snapshot,tasks:[task],now:now,available:true))
    task.state = .blocked;task.result="Tests failed"
    XCTAssertNil(policy.update(snapshot:snapshot,tasks:[task],now:now,available:false))
    XCTAssertEqual(policy.update(snapshot:snapshot,tasks:[task],now:now,available:true)?.reason,.blocker)
    task.state = .working
    _=policy.update(snapshot:snapshot,tasks:[task],now:now,available:false)
    XCTAssertNil(policy.pending,"Resolved blocker cannot remain unanswered")
    task.state = .blocked
    policy.answer(now:now)
    snapshot.timestamp=now.addingTimeInterval(601).timeIntervalSince1970*1000
    XCTAssertNil(policy.update(snapshot:snapshot,tasks:[task],now:now.addingTimeInterval(601),available:true))
  }
  func testExplicitPriorityAndCriteriaQuestionsUseSameDecisionGate() {
    var policy=RobinProactiveQuestions();let now=Date()
    let priorities=RobinProactiveQuestion(id:"priorities",project:"/project",reason:.priorities,evidence:"Two approved tasks are waiting for a decision.",question:"Which should come first?",recommendation:"Resolve the blocked task first.")
    XCTAssertEqual(policy.offer(priorities,now:now,available:true)?.reason,.priorities)
    policy.answer(now:now)
    let criteria=RobinProactiveQuestion(id:"criteria",project:"/project",reason:.successCriteria,evidence:"The requested improvement has no acceptance criteria.",question:"What result would make this successful?",recommendation:"")
    XCTAssertNil(policy.offer(criteria,now:now,available:true))
    XCTAssertEqual(policy.offer(criteria,now:now.addingTimeInterval(600),available:true)?.reason,.successCriteria)
  }
  func testPersistenceRetainsPendingAndSnooze() throws {
    var policy=RobinProactiveQuestions();let now=Date()
    _=policy.offer(question("one"),now:now,available:true);policy.snooze(now:now)
    let restored=try JSONDecoder().decode(RobinProactiveQuestions.self,from:JSONEncoder().encode(policy))
    XCTAssertEqual(restored.pending?.id,"one")
    XCTAssertEqual(restored.snoozedUntil,policy.snoozedUntil)
  }
}
