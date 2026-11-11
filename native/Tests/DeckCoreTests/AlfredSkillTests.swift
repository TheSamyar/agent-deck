import XCTest
@testable import DeckCore

final class AlfredSkillTests: XCTestCase {
  func testExactAliasesDoNotMatchConversationOrPrefix() {
    let library = AlfredSkillLibrary.defaults
    XCTAssertEqual(library.match("Start my workday!")?.name, "Start my workday")
    XCTAssertEqual(library.match("RUN SKILL Review finished agents")?.name, "Review finished agents")
    for phrase in ["please start my workday", "they said start my workday", "start my workday and send a message", "review finished agent"] {
      XCTAssertNil(library.match(phrase))
    }
  }
  func testConflictsAreRejectedAndUpdatesRetainIdentity() throws {
    var library = AlfredSkillLibrary.defaults
    XCTAssertThrowsError(try library.upsert(.init(name: "Another", aliases: ["Start my workday"], instructions: "Observe")))
    XCTAssertThrowsError(try library.upsert(.init(name: "start my workday", instructions: "Observe")))
    var edited = library.skills[0]; edited.instructions = "Observe only"
    try library.upsert(edited)
    XCTAssertEqual(library.skills.count, 2)
    XCTAssertEqual(library.skills[0].id, edited.id)
    XCTAssertEqual(library.skills[0].instructions, "Observe only")
  }
  func testLibraryRoundTripRemovalAndInvalidVersions() throws {
    var library = AlfredSkillLibrary.defaults
    XCTAssertEqual(try AlfredSkillLibrary.decode(JSONEncoder().encode(library)), library)
    library.remove(id: library.skills[0].id)
    XCTAssertEqual(library.skills.count, 1)
    library.version = 2
    XCTAssertThrowsError(try AlfredSkillLibrary.decode(JSONEncoder().encode(library)))
    XCTAssertThrowsError(try AlfredSkillLibrary.decode(Data("broken".utf8)))
  }
  func testInstructionsGrantNoAuthorityAndScopeMustBeAbsolute() throws {
    var library = AlfredSkillLibrary()
    XCTAssertThrowsError(try library.upsert(.init(name: "Example", instructions: "Observe", project: "relative")))
    try library.upsert(.init(name: "Example", instructions: "Run a check", project: "/tmp/alfred-skill-project"))
    XCTAssertTrue(library.skills[0].goal.contains("grant no permissions"))
    XCTAssertEqual(library.skills[0].project, URL(fileURLWithPath: "/tmp/alfred-skill-project").standardizedFileURL.resolvingSymlinksInPath().path)
    XCTAssertThrowsError(try library.upsert(.init(name: "", instructions: "Observe")))
    XCTAssertThrowsError(try library.upsert(.init(name: "Other", aliases: ["!!!"], instructions: "Observe")))
  }
}
