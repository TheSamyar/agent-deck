import Darwin
import Foundation
import XCTest
@testable import DeckCore

final class ProcessWitnessBirthTests: XCTestCase {
  func testBirthMatchesFullWitnessAndRejectsInvalidPIDs() throws {
    let pid = Int(getpid())
    let witness = try XCTUnwrap(ProcessWitness.read(pid))
    XCTAssertEqual(ProcessWitness.readBirth(pid), witness.birth)
    XCTAssertNil(ProcessWitness.readBirth(0))
    XCTAssertNil(ProcessWitness.readBirth(-1))
    XCTAssertNil(ProcessWitness.readBirth(Int.max))
  }

  func testBirthSurvivesUnlinkingRunningExecutable() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deck-unlinked-process-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let executable = directory.appendingPathComponent("sleep")
    let process = Process()
    defer {
      if process.isRunning { process.terminate(); process.waitUntilExit() }
      try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
    process.executableURL = executable
    process.arguments = ["30"]
    try process.run()
    let pid = Int(process.processIdentifier)
    let before = try XCTUnwrap(ProcessWitness.read(pid))
    XCTAssertEqual(ProcessWitness.readBirth(pid), before.birth)

    // Sparkle removes the old bundle while its helper can still own a live process.
    try FileManager.default.removeItem(at: executable)
    XCTAssertFalse(FileManager.default.fileExists(atPath: executable.path))
    XCTAssertTrue(process.isRunning)
    XCTAssertEqual(ProcessWitness.readBirth(pid), before.birth)

    process.terminate(); process.waitUntilExit()
    XCTAssertNotEqual(ProcessWitness.readBirth(pid), before.birth)
  }
}
