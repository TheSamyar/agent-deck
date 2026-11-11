import Foundation

public struct MasterHUBKeyBinding: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Sendable {
    case application, browser, shortcut, spotlight, screenshot, mute, lockScreen, volumeUp, volumeDown, dashboard, supervisor
    public var title: String {
      switch self {
      case .application: "Open Application"
      case .browser: "Default Browser"
      case .shortcut: "Keyboard Shortcut"
      case .spotlight: "Spotlight"
      case .screenshot: "Capture a Region"
      case .mute: "Mute Audio"
      case .lockScreen: "Lock Mac"
      case .volumeUp: "Volume Up"
      case .volumeDown: "Volume Down"
      case .dashboard: "Open Agent Deck"
      case .supervisor: "Talk to Alfred"
      }
    }
    public var symbol: String {
      switch self {
      case .application: "app"
      case .browser: "globe"
      case .shortcut: "command"
      case .spotlight: "magnifyingglass"
      case .screenshot: "viewfinder"
      case .mute: "speaker.slash"
      case .lockScreen: "lock"
      case .volumeUp: "speaker.plus"
      case .volumeDown: "speaker.minus"
      case .dashboard: "square.grid.3x3"
      case .supervisor: "waveform"
      }
    }
  }
  public var id: String
  public var label: String
  public var kind: Kind
  public var applicationPath: String
  public var bundleID: String
  public var keyCode: Int
  public var modifiers: UInt64
  public init(id: String, label: String, kind: Kind, applicationPath: String = "", bundleID: String = "",
    keyCode: Int = 49, modifiers: UInt64 = 1 << 20) {
    self.id = id; self.label = label; self.kind = kind
    self.applicationPath = applicationPath; self.bundleID = bundleID
    self.keyCode = keyCode; self.modifiers = modifiers
  }
  public var valid: Bool {
    !id.isEmpty && !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && label.count <= 80
      && (0...127).contains(keyCode) && modifiers & ~UInt64(0x1e0000) == 0
      && (kind != .application || !bundleID.isEmpty || (applicationPath.hasPrefix("/") && applicationPath.hasSuffix(".app")))
  }
}

/// Complete, portable device configuration. Geometry belongs to this surface, not the legacy keypad.
public struct MasterHUBConfiguration: Codable, Equatable, Sendable {
  public var motion: Bool? = nil
  public var version = 2
  public var macKeys: [MasterHUBKeyBinding]
  public var rotaries: MasterHUBRotaryControls
  public var keypadRotation = 0
  public init() {
    macKeys = [
      .init(id: "editor", label: "Cursor", kind: .application, applicationPath: "/Applications/Cursor.app", bundleID: "com.todesktop.230313mzl4w4u92"),
      .init(id: "terminal", label: "Terminal", kind: .application, applicationPath: "/System/Applications/Utilities/Terminal.app", bundleID: "com.apple.Terminal"),
      .init(id: "browser", label: "Browser", kind: .browser),
      .init(id: "finder", label: "Finder", kind: .application, applicationPath: "/System/Library/CoreServices/Finder.app", bundleID: "com.apple.finder"),
      .init(id: "claude", label: "Claude", kind: .application, applicationPath: "/Applications/Claude.app"),
      .init(id: "antigravity", label: "Antigravity", kind: .application, applicationPath: "/Applications/Antigravity.app"),
      .init(id: "spotlight", label: "Spotlight", kind: .spotlight),
      .init(id: "screenshot", label: "Screenshot", kind: .screenshot),
      .init(id: "mute", label: "Mute", kind: .mute),
      .init(id: "lock", label: "Lock Mac", kind: .lockScreen),
    ]
    rotaries = .init()
    rotaries.bindings[0].turn = .scroll
    rotaries.bindings[1].turn = .horizontalScroll
    rotaries.bindings[2] = .init(turn: .volume, press: .mute)
    rotaries.bindings[3] = .init(turn: .zoom, press: .resetZoom)
    rotaries.bindings[4] = .init(turn: .scroll, press: .attention)
  }
  public var valid: Bool {
    version == 2 && macKeys.count == 10 && macKeys.allSatisfy(\.valid)
      && Set(macKeys.map(\.id)).count == 10 && rotaries.valid && (0..<4).contains(keypadRotation)
  }
  public static var utilityKeys: [MasterHUBKeyBinding] {
    [ .init(id: "copy", label: "Copy", kind: .shortcut, keyCode: 8),
      .init(id: "paste", label: "Paste", kind: .shortcut, keyCode: 9),
      .init(id: "undo", label: "Undo", kind: .shortcut, keyCode: 6),
      .init(id: "redo", label: "Redo", kind: .shortcut, keyCode: 6, modifiers: (1 << 20) | (1 << 17)),
      .init(id: "find", label: "Find", kind: .shortcut, keyCode: 3),
      .init(id: "save", label: "Save", kind: .shortcut, keyCode: 1),
      .init(id: "switch", label: "Switch", kind: .shortcut, keyCode: 48),
      .init(id: "capture", label: "Capture", kind: .screenshot),
      .init(id: "search", label: "Search", kind: .spotlight),
      .init(id: "deck", label: "Deck", kind: .dashboard) ]
  }
  public var columns: Int { keypadRotation % 2 == 0 ? 5 : 3 }
  public func wireIndex(for logical: Int) -> Int? { MasterHUBGeometry.wireIndex(logical: logical, rotation: keypadRotation) }
  public func logicalIndex(forWire wire: Int) -> Int? { MasterHUBGeometry.logicalIndex(wire: wire, rotation: keypadRotation) }
  /// Legacy six-key bindings are preserved on the Mac page; unknown/corrupt settings are rejected.
  public static func migrating(legacyKeys data: Data?, legacyRotaries: Data?) -> Self {
    var configuration = Self()
    if let data, let legacy = try? JSONDecoder().decode(LegacyKeys.self, from: data), legacy.version == 1,
      legacy.bindings.count == 6, !legacy.isOriginalPreset {
      for (index, value) in legacy.bindings.enumerated() {
        let kind: MasterHUBKeyBinding.Kind?
        switch value.action {
        case "app": kind = .application
        case "shortcut": kind = .shortcut
        case "deck": kind = .dashboard
        default: kind = MasterHUBKeyBinding.Kind(rawValue: value.action)
        }
        if let kind {
          let binding = MasterHUBKeyBinding(id: configuration.macKeys[index].id, label: value.label,
            kind: kind, applicationPath: value.appPath, keyCode: value.keyCode, modifiers: value.modifiers)
          if binding.valid { configuration.macKeys[index] = binding }
        }
      }
    }
    if let legacyRotaries, let rotaries = try? JSONDecoder().decode(MasterHUBRotaryControls.self, from: legacyRotaries), rotaries.valid, rotaries != MasterHUBRotaryControls() {
      configuration.rotaries = rotaries
    }
    return configuration
  }
  private struct LegacyKeys: Decodable {
    var version: Int
    var bindings: [LegacyBinding]
    var isOriginalPreset: Bool {
      let names = ["Volume −", "Volume +", "Mute", "Terminal", "Spotlight", "Agent Deck"]
      let actions = ["volumeDown", "volumeUp", "mute", "app", "shortcut", "deck"]
      return bindings.count == 6 && bindings.enumerated().allSatisfy { index, binding in
        binding.label == names[index] && binding.action == actions[index]
          && binding.appPath == "/System/Applications/Utilities/Terminal.app"
          && binding.keyCode == 49 && binding.modifiers == 1 << 20
      }
    }
  }
  private struct LegacyBinding: Decodable {
    var label: String; var action: String; var appPath: String; var keyCode: Int; var modifiers: UInt64
  }
}

public enum MasterHUBGeometry {
  public static func wireIndex(logical: Int, rotation: Int) -> Int? {
    guard (0..<15).contains(logical), (0..<4).contains(rotation) else { return nil }
    let columns = rotation % 2 == 0 ? 5 : 3
    let x = logical % columns, y = logical / columns
    switch rotation {
    case 0: return logical
    case 1: return (2 - x) * 5 + y
    case 2: return 14 - logical
    default: return x * 5 + 4 - y
    }
  }
  public static func logicalIndex(wire: Int, rotation: Int) -> Int? {
    (0..<15).first { wireIndex(logical: $0, rotation: rotation) == wire }
  }
}
