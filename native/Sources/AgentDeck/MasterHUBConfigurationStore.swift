import Foundation
import DeckCore

@MainActor enum MasterHUBConfigurationStore {
  private static let key = "masterhubConfiguration.v2"
  private static let previous = "masterhubConfiguration.previous"
  static func load() -> MasterHUBConfiguration {
    if let data = UserDefaults.standard.data(forKey: key),
      let value = try? JSONDecoder().decode(MasterHUBConfiguration.self, from: data), value.valid { return value }
    return .migrating(legacyKeys: UserDefaults.standard.data(forKey: "masterhubControls"),
      legacyRotaries: UserDefaults.standard.data(forKey: "masterhubRotaryControls"))
  }
  static var hasUndo: Bool { UserDefaults.standard.data(forKey: previous) != nil }
  static func save(_ value: MasterHUBConfiguration) -> Bool {
    guard value.valid, let data = try? JSONEncoder().encode(value),
      let old = try? JSONEncoder().encode(load()) else { return false }
    UserDefaults.standard.set(old, forKey: previous)
    UserDefaults.standard.set(data, forKey: key)
    return true
  }
  static func undo() -> MasterHUBConfiguration? {
    guard let data = UserDefaults.standard.data(forKey: previous),
      let value = try? JSONDecoder().decode(MasterHUBConfiguration.self, from: data), value.valid else { return nil }
    UserDefaults.standard.set(data, forKey: key)
    UserDefaults.standard.removeObject(forKey: previous)
    return value
  }
  static func decodeImport(_ data: Data) throws -> MasterHUBConfiguration {
    guard data.count <= 65536 else { throw ImportFailure("Choose a settings file smaller than 64 KB.") }
    if let value = try? JSONDecoder().decode(MasterHUBConfiguration.self, from: data), value.valid { return value }
    if let legacy = try? JSONDecoder().decode(MasterHUBControls.self, from: data), legacy.valid {
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      var rotaryData: Data?
      if let rotaries = object?["rotaries"] {
        rotaryData = try JSONSerialization.data(withJSONObject: rotaries)
        guard let rotaryData, let value = try? JSONDecoder().decode(MasterHUBRotaryControls.self, from: rotaryData), value.valid
        else { throw ImportFailure("This file contains invalid dial settings.") }
      }
      return .migrating(legacyKeys: data, legacyRotaries: rotaryData)
    }
    throw ImportFailure("This is not a supported MasterHUB settings file. Your current setup is unchanged.")
  }
  private struct ImportFailure: LocalizedError {
    var errorDescription: String?
    init(_ description: String) { errorDescription = description }
  }
}
