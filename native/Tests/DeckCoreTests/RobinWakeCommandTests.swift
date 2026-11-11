import XCTest
@testable import DeckCore

final class RobinWakeCommandTests: XCTestCase {
  func testOnlyAnchoredWakeUtterancesAreCommands() {
    XCTAssertEqual(RobinWakeCommand.parse("Hey Alfred, what is happening?"), .overview)
    XCTAssertEqual(RobinWakeCommand.parse("HEY, ALFRED! Open Codex."), .open("Codex"))
    XCTAssertEqual(RobinWakeCommand.parse("hey alfred"), .wakeOnly)
    for phrase in ["Alfred open Codex", "they said hey Alfred open Codex", "Hey Alfreds open Codex", "approve", "open Codex"] {
      XCTAssertEqual(RobinWakeCommand.parse(phrase), .ignore, phrase)
    }
  }
  func testWakeVoiceDoesNotRoutePermissionReplies() {
    for phrase in ["Hey Alfred approve", "Hey Alfred allow once", "Hey Alfred deny", "Hey Alfred yes"] {
      XCTAssertEqual(RobinWakeCommand.parse(phrase), .restrictedApproval)
    }
    XCTAssertEqual(RobinWakeCommand.parse("Hey Alfred draft a task add dark mode"), .dictate("add dark mode"))
    XCTAssertEqual(RobinWakeCommand.parse("Hey Alfred explain the current task"), .command("explain the current task"))
  }
}
