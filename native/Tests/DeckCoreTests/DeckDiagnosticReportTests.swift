import Darwin
import XCTest
@testable import DeckCore

final class DeckDiagnosticReportTests: XCTestCase {
  private func report(_ hardware: [String: Any], pid: Int? = 42) throws -> DeckDiagnosticReport {
    .init(version: "0.4.1", build: "16", guiRunning: true, serviceRunning: true,
      hardware: try JSONSerialization.data(withJSONObject: hardware), verifiedGUI: pid, now: 100)
  }
  private var healthy: [String: Any] { ["pid":42, "updatedAt":99.0, "keypadConnected":true,
    "rollerConnected":true, "knobsConnected":true, "screenDialConnected":true,
    "displayFailures":0, "screenDialDisplayFailures":0, "inputErrors":0] }
  func testAllowlistExcludesUntrustedStringsAndCredentials() throws {
    var data = healthy
    data["token"] = "SECRET-TOKEN"; data["lastError"] = "/Users/private/person"; data["prompt"] = "private prompt"
    let value = try report(data)
    XCTAssertEqual(value.checks.last?.state, "ready")
    let text = String(decoding: try value.json(), as: UTF8.self)
    for secret in ["SECRET-TOKEN", "/Users/", "private prompt", "lastError"] { XCTAssertFalse(text.contains(secret)) }
  }
  func testRequiresFreshCompleteReportFromVerifiedProducer() throws {
    for (key, value) in [("pid", 55 as Any), ("updatedAt", 70 as Any), ("updatedAt", 200 as Any),
      ("displayFailures", -1 as Any), ("inputErrors", true as Any), ("keypadConnected", 1 as Any)] {
      var data = healthy; data[key] = value
      XCTAssertEqual(try report(data).checks.last?.state, "unknown", key)
    }
    XCTAssertEqual(try report(healthy, pid: nil).checks.last?.state, "unknown")
    var incomplete = healthy; incomplete.removeValue(forKey: "inputErrors")
    XCTAssertEqual(try report(incomplete).checks.last?.state, "unknown")
  }
  func testHardwareFailureGivesBoundedAction() throws {
    var data = healthy; data["displayFailures"] = 1
    let item = try report(data).checks.last
    XCTAssertEqual(item?.state, "needsAttention")
    XCTAssertTrue(item?.nextAction.contains("Check controls") == true)
  }
  func testSaveNeverOverwritesAndUsesPrivatePermissions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("report.json")
    try DeckDiagnosticReport.saveNew(Data("first".utf8), to: file)
    XCTAssertThrowsError(try DeckDiagnosticReport.saveNew(Data("second".utf8), to: file))
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first")
    let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
    XCTAssertEqual(mode, 0o600)
  }
  func testUnsafeCacheFilesAreRejected() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = directory.appendingPathComponent("cache")
    try Data("{}".utf8).write(to: data)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: data.path)
    XCTAssertNotNil(DeckDiagnosticCache.read(data))
    let link = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: data)
    XCTAssertNil(DeckDiagnosticCache.read(link))
    let fifo = directory.appendingPathComponent("fifo")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    XCTAssertNil(DeckDiagnosticCache.read(fifo))
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: data.path)
    XCTAssertNil(DeckDiagnosticCache.read(data))
  }

}
