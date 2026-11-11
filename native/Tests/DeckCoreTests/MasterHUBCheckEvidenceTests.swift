import XCTest
@testable import DeckCore

final class MasterHUBCheckEvidenceTests: XCTestCase {
  func testConnectionNeverImpliesInputOrActionSuccess() throws {
    let evidence = make(observed: [], actionObserved: [], confirmed: ["Key 1"])
    XCTAssertEqual(evidence.expectedControls.count, 31)
    XCTAssertEqual(Set(evidence.expectedControls).count, 31)
    XCTAssertTrue(evidence.inputObserved.isEmpty)
    XCTAssertTrue(evidence.actionConfirmedByUser.isEmpty)
    let data = try JSONEncoder().encode(evidence)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["appVersion"] as? String, "0.3.6")
    XCTAssertEqual(json["appBuild"] as? String, "10")
    XCTAssertEqual((json["devices"] as? [[String: Any]])?.first?["productID"] as? Int, 0x0200)
  }
  func testIdentificationCannotBecomeActionConfirmation() {
    let evidence = make(observed: ["Key 1", "Key 2", "unknown"], actionObserved: ["Key 2", "Key 3"], confirmed: ["Key 1", "Key 2", "Key 3", "unknown"])
    XCTAssertEqual(evidence.inputObserved, ["Key 1", "Key 2"])
    XCTAssertEqual(evidence.actionInputObserved, ["Key 2"])
    XCTAssertEqual(evidence.actionConfirmedByUser, ["Key 2"])
  }
  private func make(observed: Set<String>, actionObserved: Set<String>, confirmed: Set<String>) -> MasterHUBCheckEvidence {
    .init(appVersion: "0.3.6", appBuild: "10", startedAt: Date(timeIntervalSince1970: 1), macOS: "test",
      devices: [.init(module: "Keypad", connected: true, vendorID: 0x2516, productID: 0x0200)],
      observed: observed, actionObserved: actionObserved, confirmed: confirmed)
  }
}
