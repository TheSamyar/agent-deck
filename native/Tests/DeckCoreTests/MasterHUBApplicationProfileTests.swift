import Foundation
import XCTest
@testable import DeckCore

final class MasterHUBApplicationProfileTests: XCTestCase {
  private func library() -> MasterHUBProfileLibrary {
    var config = MasterHUBConfiguration(); config.macKeys[0].label = "Editor tools"
    var value = MasterHUBProfileLibrary(); value.profiles = [.init(name: "Editor", configuration: config)]
    value.assignments["com.apple.Terminal"] = value.profiles[0].id
    return value
  }
  private func fixture() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("masterhub-profiles-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir.appendingPathComponent("profiles.json")
  }
  func testAutomaticResolutionIsOptInAndBundleIDExact() {
    var value = library()
    XCTAssertTrue(value.valid); XCTAssertNil(value.profile(for: "com.apple.Terminal"))
    value.automaticEnabled = true
    XCTAssertEqual(value.profile(for: "com.apple.Terminal")?.name, "Editor")
    for id in ["com.apple.terminal", "com.apple.Terminal.helper", "com.apple", "com.apple.Terminal ", "*"] { XCTAssertNil(value.profile(for: id)) }
    XCTAssertNil(value.profile(for: nil))
  }
  func testLibraryRejectsDanglingAssignmentsDuplicateNamesAndUnsafeConfigurations() throws {
    var value = library(); value.assignments["com.test.app"] = UUID(); XCTAssertFalse(value.valid)
    value = library(); value.profiles.append(.init(name: "ÉDITOR", configuration: .init())); XCTAssertFalse(value.valid)
    value = library(); value.profiles.append(.init(name: "Other", configuration: .init())); value.profiles[1].name = " Editor "; XCTAssertFalse(value.valid)
    value = library(); value.profiles[0].configuration.keypadRotation = 4; XCTAssertFalse(value.valid)
    value = library(); value.assignments["com.*.app"] = value.profiles[0].id; XCTAssertFalse(value.valid)
    XCTAssertThrowsError(try MasterHUBProfileLibrary.decodeImport(JSONEncoder().encode(value)))
    XCTAssertThrowsError(try MasterHUBProfileLibrary.decodeImport(Data(repeating: 0, count: 512 * 1024 + 1)))
  }
  func testPrivateAtomicPersistenceRoundTripsWithoutTouchingDefaultPreference() throws {
    let file = try fixture(), store = MasterHUBProfileStore(file: file)
    let key = "masterhubConfiguration.v2", defaults = UserDefaults(suiteName: "profiles-fixture-" + UUID().uuidString)!
    let original = Data("independent-default-layout".utf8); defaults.set(original, forKey: key)
    var value = library(); value.automaticEnabled = true
    try store.save(value)
    XCTAssertEqual(MasterHUBProfileStore(file: file).library, value)
    XCTAssertEqual(defaults.data(forKey: key), original)
    let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    let dirMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(fileMode?.intValue, 0o600); XCTAssertEqual(dirMode?.intValue, 0o700)
    defaults.removeObject(forKey: key)
  }
  func testCorruptAndSymlinkStorageNeverOverwritesOriginal() throws {
    let file = try fixture(), corrupt = Data("preserve broken saved profiles".utf8)
    try corrupt.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let store = MasterHUBProfileStore(file: file)
    XCTAssertNotNil(store.loadError); XCTAssertThrowsError(try store.save(library()))
    XCTAssertEqual(try Data(contentsOf: file), corrupt)
    let link = file.deletingLastPathComponent().appendingPathComponent("linked.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    let linked = MasterHUBProfileStore(file: link)
    XCTAssertNotNil(linked.loadError); XCTAssertThrowsError(try linked.save(library()))
    XCTAssertEqual(try Data(contentsOf: file), corrupt)
  }
  func testConcurrentOrExternalChangesArePreserved() throws {
    let file = try fixture(), first = MasterHUBProfileStore(file: file), stale = MasterHUBProfileStore(file: file)
    try first.save(library())
    let saved = try Data(contentsOf: file)
    XCTAssertThrowsError(try stale.save(MasterHUBProfileLibrary()))
    XCTAssertEqual(try Data(contentsOf: file), saved)
    let replacement = Data("new external data".utf8); try replacement.write(to: file)
    XCTAssertThrowsError(try first.save(MasterHUBProfileLibrary()))
    XCTAssertEqual(try Data(contentsOf: file), replacement)
  }
  func testBackupRecoveryKeepsCurrentSnapshotsAndAssignmentsWhileRecoveringOlderVersions() throws {
    var current = library(); current.automaticEnabled = true
    var older = current; older.profiles[0].configuration.macKeys[0].label = "Older saved setup"
    older.assignments["com.example.Other"] = older.profiles[0].id
    let recovered = try current.addingRecoveredProfiles(older)
    XCTAssertFalse(recovered.automaticEnabled)
    XCTAssertEqual(recovered.profiles.count, 2)
    XCTAssertEqual(recovered.profiles[0], current.profiles[0])
    let copy = recovered.profiles[1]
    XCTAssertEqual(copy.name, "Editor (Recovered)"); XCTAssertNotEqual(copy.id, current.profiles[0].id)
    XCTAssertEqual(copy.configuration.macKeys[0].label, "Older saved setup")
    XCTAssertEqual(recovered.assignments["com.apple.Terminal"], current.profiles[0].id)
    XCTAssertEqual(recovered.assignments["com.example.Other"], copy.id)
    let same = try current.addingRecoveredProfiles(current)
    XCTAssertEqual(same.profiles, current.profiles)
  }
  func testAllCriticalStatesDeferProfileSwitching() {
    let safe = MasterHUBProfileSwitchContext(identifying: false, checking: false, actionInFlight: false,
      confirmationPending: false, requestPending: false, deviceBusy: false)
    XCTAssertTrue(safe.canSwitch)
    for index in 0..<6 {
      var state = safe
      switch index { case 0: state.identifying = true; case 1: state.checking = true; case 2: state.actionInFlight = true
      case 3: state.confirmationPending = true; case 4: state.requestPending = true; default: state.deviceBusy = true }
      XCTAssertFalse(state.canSwitch)
    }
  }
  func testProfileChangeInvalidatesCapturedMacActionWithoutReorderingAgentState() {
    var surface = MasterHUBSurface(); surface.navigate(.mac)
    let original = MasterHUBConfiguration(), first = surface.layout(snapshot: nil, configuration: original)
    var changed = original; changed.macKeys[0].label = "Changed editor"; changed.macKeys[0].applicationPath = "/Applications/Other.app"
    let next = surface.layout(snapshot: nil, configuration: changed)
    XCTAssertGreaterThan(next.revision, first.revision)
    XCTAssertNotEqual(first.tiles[0].binding, next.tiles[0].binding)
    XCTAssertNotNil(MasterHUBSurface.validatePress(first, current: first, index: 0, heldMs: 0))
    XCTAssertNil(MasterHUBSurface.validatePress(first, current: next, index: 0, heldMs: 700), "An old profile's physical press must not execute a replacement binding")
    XCTAssertEqual(next.page, .mac)
    XCTAssertEqual(original.macKeys[0].label, "Cursor")
  }
}
