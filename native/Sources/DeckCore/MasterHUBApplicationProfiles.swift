import Foundation
import Darwin

public struct MasterHUBApplicationProfile: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var configuration: MasterHUBConfiguration
  public init(id: UUID = UUID(), name: String, configuration: MasterHUBConfiguration) {
    self.id = id; self.name = name.trimmingCharacters(in: .whitespacesAndNewlines); self.configuration = configuration
  }
}

/// Snapshots contain device assignments, never application or assistant permission grants.
/// The existing masterhubConfiguration.v2 preference remains the default layout authority.
public struct MasterHUBProfileLibrary: Codable, Equatable, Sendable {
  public var schemaVersion = 1
  public var automaticEnabled = false
  public var profiles: [MasterHUBApplicationProfile] = []
  public var assignments: [String: UUID] = [:]
  public init() {}
  public static func validBundleID(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    return value.utf8.count <= 255 && parts.count >= 2 && parts.allSatisfy { !$0.isEmpty }
      && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }
  }
  public var valid: Bool {
    let ids = Set(profiles.map(\.id))
    let names = profiles.map { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    return schemaVersion == 1 && profiles.count <= 32 && assignments.count <= 128
      && ids.count == profiles.count && Set(names).count == profiles.count
      && profiles.allSatisfy { !$0.name.isEmpty && $0.name == $0.name.trimmingCharacters(in: .whitespacesAndNewlines) && $0.name.count <= 80 && $0.configuration.valid }
      && assignments.allSatisfy { Self.validBundleID($0.key) && ids.contains($0.value) }
  }
  public func profile(for bundleID: String?) -> MasterHUBApplicationProfile? {
    guard automaticEnabled, valid, let bundleID, let id = assignments[bundleID] else { return nil }
    return profiles.first { $0.id == id }
  }
  /// Additive recovery never replaces a saved snapshot or its app assignments.
  /// Conflicting IDs/names become separately named recovered profiles, with remapped IDs.
  public func addingRecoveredProfiles(_ imported: Self) throws -> Self {
    guard valid, imported.valid else { throw MasterHUBProfileFailure("The recovered profile library is invalid.") }
    var result = self; result.automaticEnabled = false
    var recoveredIDs: [UUID: UUID] = [:]
    func folded(_ name: String) -> String { name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    for profile in imported.profiles {
      if let existing = result.profiles.first(where: { $0.id == profile.id }), existing == profile {
        recoveredIDs[profile.id] = existing.id; continue
      }
      let id = result.profiles.contains(where: { $0.id == profile.id }) ? UUID() : profile.id
      var name = profile.name, suffix = 1
      while result.profiles.contains(where: { folded($0.name) == folded(name) }) {
        let ending = suffix == 1 ? " (Recovered)" : " (Recovered \(suffix))"
        name = String(profile.name.prefix(80 - ending.count)) + ending; suffix += 1
      }
      result.profiles.append(.init(id: id, name: name, configuration: profile.configuration))
      recoveredIDs[profile.id] = id
    }
    for (bundle, id) in imported.assignments where result.assignments[bundle] == nil { result.assignments[bundle] = recoveredIDs[id] }
    guard result.valid else { throw MasterHUBProfileFailure("Recovery would exceed the profile or assignment limit. No saved profiles changed.") }
    return result
  }
  public static func decodeImport(_ data: Data) throws -> Self {
    guard data.count <= 512 * 1024 else { throw MasterHUBProfileFailure("Choose a profile library smaller than 512 KB.") }
    let value = try JSONDecoder().decode(Self.self, from: data)
    guard value.valid else { throw MasterHUBProfileFailure("The profile library has invalid or duplicate names, assignments, or configurations.") }
    return value
  }
}

public struct MasterHUBProfileSwitchContext: Sendable {
  public var identifying: Bool
  public var checking: Bool
  public var actionInFlight: Bool
  public var confirmationPending: Bool
  public var requestPending: Bool
  public var deviceBusy: Bool
  public init(identifying: Bool, checking: Bool, actionInFlight: Bool, confirmationPending: Bool, requestPending: Bool, deviceBusy: Bool) {
    self.identifying = identifying; self.checking = checking; self.actionInFlight = actionInFlight
    self.confirmationPending = confirmationPending; self.requestPending = requestPending; self.deviceBusy = deviceBusy
  }
  public var canSwitch: Bool { !identifying && !checking && !actionInFlight && !confirmationPending && !requestPending && !deviceBusy }
}

public struct MasterHUBProfileFailure: LocalizedError {
  public let errorDescription: String?
  public init(_ message: String) { errorDescription = message }
}

/// Private atomic persistence; corrupt or unsafe existing files are preserved rather than reset.
public final class MasterHUBProfileStore {
  public private(set) var library = MasterHUBProfileLibrary()
  public private(set) var loadError: String?
  public let file: URL
  private var expectedData: Data?
  public init(file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Deck/masterhub-profiles.json")) {
    self.file = file
    guard FileManager.default.fileExists(atPath: file.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil else { return }
    do {
      try checkExistingPath(file)
      let data = try Data(contentsOf: file)
      library = try MasterHUBProfileLibrary.decodeImport(data); expectedData = data
    } catch { loadError = "Saved profiles could not be read. Existing file was preserved." }
  }
  public func save(_ value: MasterHUBProfileLibrary) throws {
    guard loadError == nil else { throw MasterHUBProfileFailure(loadError!) }
    guard value.valid else { throw MasterHUBProfileFailure("Check profile names, assignments and device settings before saving.") }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    guard data.count <= 512 * 1024 else { throw MasterHUBProfileFailure("This profile library exceeds the 512 KB limit.") }
    let directory = file.deletingLastPathComponent()
    try ensurePrivateDirectory(directory)
    if FileManager.default.fileExists(atPath: file.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil {
      try checkExistingPath(file)
      guard let expectedData, try Data(contentsOf: file) == expectedData else {
        throw MasterHUBProfileFailure("Profiles changed outside this app. Reopen Agent Deck before saving; the newer file was preserved.")
      }
    } else if expectedData != nil {
      throw MasterHUBProfileFailure("Saved profiles were removed outside this app. Reopen Agent Deck before saving.")
    }
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    library = value; expectedData = data
  }
  private func checkExistingPath(_ url: URL) throws {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attrs[.type] as? FileAttributeType == .typeRegular,
      (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
      ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0,
      (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 512 * 1024 else {
      throw MasterHUBProfileFailure("Profile storage must be a private regular file owned by this user.")
    }
  }
  private func ensurePrivateDirectory(_ directory: URL) throws {
    if FileManager.default.fileExists(atPath: directory.path) {
      let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
      guard attrs[.type] as? FileAttributeType == .typeDirectory,
        (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw MasterHUBProfileFailure("The profile directory is not owned by this user.") }
    } else { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }
}
