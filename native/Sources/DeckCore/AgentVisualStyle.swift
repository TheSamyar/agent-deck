import Foundation

public struct AgentVisualStyle: Codable, Equatable, Sendable {
  public static var isolated = false
  public var character: Int
  public var color: Int
  public init(character: Int, color: Int) { self.character = min(3,max(0,character)); self.color = min(3,max(0,color)) }
  public static let names = ["Orbit", "Pip", "Sprout", "Bolt"]
  public static let colors = ["Teal", "Pink", "Purple", "Amber"]
  private static let cacheLock = NSLock()
  private static var cachedData: Data?
  private static var cachedValues: [String: Self] = [:]
  public static func load(project: String) -> Self? {
    guard !isolated, let data = UserDefaults.standard.data(forKey: "agentProjectStyles") else { return nil }
    cacheLock.lock(); defer { cacheLock.unlock() }
    if data != cachedData {
      cachedValues = (try? JSONDecoder().decode([String: Self].self, from: data)) ?? [:]
      cachedData = data
    }
    guard let value = cachedValues[project] else { return nil }
    return .init(character: value.character, color: value.color)
  }
  public func save(project: String) {
    guard !Self.isolated else { return }
    let data = UserDefaults.standard.data(forKey: "agentProjectStyles") ?? Data()
    var values = (try? JSONDecoder().decode([String: Self].self, from: data)) ?? [:]
    values[project] = self
    if let encoded = try? JSONEncoder().encode(values) { UserDefaults.standard.set(encoded, forKey: "agentProjectStyles") }
  }
}
