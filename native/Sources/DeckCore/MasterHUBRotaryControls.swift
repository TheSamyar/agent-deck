import Foundation

public struct MasterHUBRotaryControls: Codable, Equatable, Sendable {
  public enum Turn: String, Codable, CaseIterable, Sendable {
    case volume = "Volume", pages = "Agent pages", scroll = "Scroll", zoom = "Zoom", sessions = "Choose agent", horizontalScroll = "Horizontal scroll"
  }
  public enum Press: String, Codable, CaseIterable, Sendable {
    case none = "Nothing", mute = "Mute", attention = "Attention", dashboard = "Open Agent Deck", resetZoom = "Reset zoom"
  }
  public struct Binding: Codable, Equatable, Sendable {
    public var turn: Turn
    public var press: Press
    public var reversed: Bool
    public init(turn: Turn, press: Press = .none, reversed: Bool = false) {
      self.turn = turn; self.press = press; self.reversed = reversed
    }
  }
  public var bindings: [Binding] = [
    .init(turn: .volume), .init(turn: .pages),
    .init(turn: .volume, press: .mute), .init(turn: .pages, press: .attention),
    .init(turn: .scroll, press: .dashboard),
  ]
  public init() {}
  public var valid: Bool { bindings.count == 5 }
  public static func load() -> Self {
    guard let data = UserDefaults.standard.data(forKey: "masterhubRotaryControls"),
      let value = try? JSONDecoder().decode(Self.self, from: data), value.valid else { return .init() }
    return value
  }
  public func save() {
    guard valid, let data = try? JSONEncoder().encode(self) else { return }
    UserDefaults.standard.set(data, forKey: "masterhubRotaryControls")
  }
}
