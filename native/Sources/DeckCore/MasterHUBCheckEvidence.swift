import Foundation

public struct MasterHUBCheckDevice: Codable, Equatable, Sendable {
  public let module: String
  public let connected: Bool
  public let vendorID: Int?
  public let productID: Int?
  public let locationID: Int?
  public init(module: String, connected: Bool, vendorID: Int? = nil, productID: Int? = nil, locationID: Int? = nil) {
    self.module = module; self.connected = connected
    self.vendorID = vendorID; self.productID = productID; self.locationID = locationID
  }
}

/// A candidate-specific manual check, never an automatic hardware certification.
public struct MasterHUBCheckEvidence: Encodable, Sendable {
  public static let groups: [(String, [String])] = [
    ("Keypad", (1...15).map { "Key \($0)" }),
    ("Rollers", (1...2).flatMap { index in ["Turn forward", "Turn backward"].map { "Roller \(index) · \($0)" } }),
    ("Small dials", (1...3).flatMap { index in ["Turn left", "Turn right", "Press"].map { "Dial \(index) · \($0)" } }),
    ("Screen dial", ["Turn left", "Turn right", "Press"].map { "Screen dial · \($0)" })
  ]
  public static var controls: [String] { groups.flatMap(\.1) }
  public let schemaVersion = 1
  public let appVersion: String
  public let appBuild: String
  public let startedAt: Date
  public let exportedAt: Date
  public let macOS: String
  public let devices: [MasterHUBCheckDevice]
  public let expectedControls: [String]
  public let inputObserved: [String]
  public let actionInputObserved: [String]
  public let actionConfirmedByUser: [String]
  public let actionConfirmationMeaning = "User-reported visible outcome during this check; not automated verification. Locking, approvals and interruption are disabled."
  public init(appVersion: String, appBuild: String, startedAt: Date, exportedAt: Date = Date(), macOS: String,
    devices: [MasterHUBCheckDevice], observed: Set<String>, actionObserved: Set<String>, confirmed: Set<String>) {
    self.appVersion = appVersion; self.appBuild = appBuild; self.startedAt = startedAt
    self.exportedAt = exportedAt; self.macOS = macOS; self.devices = devices
    expectedControls = Self.controls
    let allowed = Set(Self.controls)
    inputObserved = observed.intersection(allowed).sorted()
    actionInputObserved = actionObserved.intersection(observed).intersection(allowed).sorted()
    actionConfirmedByUser = confirmed.intersection(actionObserved).intersection(observed).intersection(allowed).sorted()
  }
}
