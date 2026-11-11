import XCTest
@testable import DeckCore
final class RobinVoiceSessionTests:XCTestCase {
  func testIncompleteThoughtGetsMoreTimeThanFinishedSentence() {
    XCTAssertGreaterThan(RobinVoiceSession.endOfTurnDelay(for:"I want to do this because"),RobinVoiceSession.endOfTurnDelay(for:"Please run the project tests"))
  }
  func testInterruptRequiresEchoControlledSpeech() {
    XCTAssertTrue(RobinVoiceSession.shouldInterrupt(speaking:true,echoControlled:true,sustainedSpeech:true))
    XCTAssertFalse(RobinVoiceSession.shouldInterrupt(speaking:true,echoControlled:false,sustainedSpeech:true))
    XCTAssertFalse(RobinVoiceSession.shouldInterrupt(speaking:false,echoControlled:true,sustainedSpeech:true))
  }
}
