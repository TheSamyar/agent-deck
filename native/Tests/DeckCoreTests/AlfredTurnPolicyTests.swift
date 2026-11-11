import XCTest
@testable import DeckCore
final class AlfredTurnPolicyTests: XCTestCase {
  func testStalledTranscriptNeverEndsActiveSpeech() {
    var policy = AlfredTurnPolicy(); policy.update(transcript: "Please inspect the current project", at: 0)
    policy.speech(active: true, at: 5)
    XCTAssertFalse(policy.shouldFinish(at: 30))
    policy.speech(active: false, at: 5.1)
    XCTAssertFalse(policy.shouldFinish(at: 5.5)); XCTAssertTrue(policy.shouldFinish(at: 6))
  }
  func testRenewedSpeechCancelsQuietEndpoint() {
    var policy = AlfredTurnPolicy(); policy.update(transcript: "Please inspect the current project", at: 0)
    policy.speech(active: true, at: 0.8); policy.speech(active: false, at: 0.9)
    XCTAssertFalse(policy.shouldFinish(at: 1)); XCTAssertTrue(policy.shouldFinish(at: 1.8))
  }
  func testIncompleteThoughtAndShortAnswersGetLongerPause() {
    var short = AlfredTurnPolicy(); short.update(transcript: "Actually", at: 0)
    XCTAssertFalse(short.shouldFinish(at: 1)); XCTAssertTrue(short.shouldFinish(at: 1.81))
    var incomplete = AlfredTurnPolicy(); incomplete.update(transcript: "Please inspect this project because", at: 0)
    XCTAssertFalse(incomplete.shouldFinish(at: 1)); XCTAssertTrue(incomplete.shouldFinish(at: 1.81))
  }
  func testTranscriptMustStabilizeAfterLongSilence() {
    var policy = AlfredTurnPolicy(); policy.speech(active: true, at: 0); policy.speech(active: false, at: 0.1)
    policy.update(transcript: "Please inspect the current project", at: 5)
    XCTAssertFalse(policy.shouldFinish(at: 5.2)); XCTAssertTrue(policy.shouldFinish(at: 5.4))
  }
  func testSilenceWithoutTranscriptCannotSubmit() {
    var policy = AlfredTurnPolicy(); policy.speech(active: false, at: 0)
    XCTAssertFalse(policy.shouldFinish(at: 20))
  }
}
