import XCTest
@testable import DeckCore

final class JarvisStreamTests: XCTestCase {
  func testSpeechArrivesBeforeTheResponseHasCompleted() {
    var stream=JarvisReplyStream()
    XCTAssertTrue(stream.append("{\"kind\":\"respond\",\"reply\":\"I can see your agents working. ").contains("I can see your agents working."))
    XCTAssertTrue(stream.append("One needs your input.\",\"action\":null,\"arguments\":{}}").joined().contains("One needs your input."))
    XCTAssertTrue(stream.finish().isEmpty)
  }
  func testActionArgumentsAreNeverReadAloud() {
    var stream=JarvisReplyStream()
    XCTAssertTrue(stream.append("{\"kind\":\"act\",\"reply\":\"Opening Cursor.\",\"arguments\":{\"text\":\"secret\"}}").isEmpty)
    XCTAssertTrue(stream.finish().isEmpty)
  }
  func testSplitEscapesAndShortReplies() {
    var stream=JarvisReplyStream()
    XCTAssertTrue(stream.append("{\"kind\":\"respond\",\"reply\":\"Hello \\u00").isEmpty)
    XCTAssertEqual(stream.append("e9.\"}"),["Hello é."])
  }
  func testMissingActionIsRejected() {
    XCTAssertThrowsError(try JarvisStep.decode(Data("{\"kind\":\"act\",\"reply\":\"x\",\"action\":null,\"arguments\":{}}".utf8)))
  }
}
