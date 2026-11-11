import AppKit
import DeckCore
import ApplicationServices
import IOKit.hid
import SwiftUI
import UniformTypeIdentifiers

struct MasterHUBControls: Codable, Equatable {
  enum Action: String, Codable, CaseIterable {
    case volumeDown, volumeUp, mute, app, shortcut, deck
  }
  struct Binding: Codable, Equatable {
    var label: String
    var action: Action
    var appPath = "/System/Applications/Utilities/Terminal.app"
    var keyCode = 49
    var modifiers: UInt64 = 1 << 20 // Command + Space
  }
  var version = 1
  var bindings: [Binding] = [
    .init(label: "Volume −", action: .volumeDown),
    .init(label: "Volume +", action: .volumeUp),
    .init(label: "Mute", action: .mute),
    .init(label: "Terminal", action: .app),
    .init(label: "Spotlight", action: .shortcut),
    .init(label: "Agent Deck", action: .deck),
  ]
  var valid: Bool {
    version == 1 && bindings.count == 6 && bindings.allSatisfy {
      !$0.label.isEmpty && $0.label.count <= 80 && (0...127).contains($0.keyCode)
        && $0.modifiers & ~UInt64(0x1e0000) == 0
        && ($0.action != .app || ($0.appPath.hasPrefix("/") && $0.appPath.hasSuffix(".app")))
    }
  }
  static func load() -> Self {
    guard let data = UserDefaults.standard.data(forKey: "masterhubControls"),
      let value = try? JSONDecoder().decode(Self.self, from: data), value.valid else { return .init() }
    return value
  }
  func save() {
    guard valid, let data = try? JSONEncoder().encode(self) else { return }
    UserDefaults.standard.set(data, forKey: "masterhubControls")
  }
}

struct MasterHUBSettingsView: View {
  @AppStorage("masterhubVisualTheme") private var visualTheme = "classic"
  @EnvironmentObject private var model: DeckModel
  var body: some View {
    Form {
      Section("Your MasterHUB workspace") {
        Text("Customize the entire device, check physical controls, and manage live agents in one place.")
        Button("Open MasterHUB") { model.section = "MasterHUB"; DeckAppDelegate.revealDashboard() }
          .buttonStyle(.borderedProminent)
      }
      MasterHUBProfilesView()
      Section("Character & style") {
        Picker("Visual theme", selection: $visualTheme) {
          Text("Classic").tag("classic")
          Text("Playful").tag("playful")
        }.onChange(of: visualTheme) { _, _ in model.refreshAppearance() }
        if visualTheme == "playful" { ProjectCharacterSettings() }
        Text("Playful characters reflect real agent status. Dependency waits remain Working.")
      }
      Section("Modules") {
        ForEach(["15-key keypad", "2 rollers", "3 dials", "Screen dial"], id: \.self) { name in
          LabeledContent(name, value: model.masterhubModules[name] ?? "Checking…")
        }
      }
    }.formStyle(.grouped)
  }
}
