import Foundation

private let touchPage = "A1A6E47DEC404F99832ABB851D17F749"
private let pressPage = "A1A6E47DEC724F99832ABB851D17F772"
private let actionPrefix = "$AiAgentDeck___Loupedeck.AiAgentDeckPlugin.AiAgentStatusCommand___"
private func ownedPage(_ page: [String: Any]) -> Bool {
  [touchPage, pressPage].contains(page["name"] as? String ?? "")
}
func configureKeypad() {
  let source = URL(
    fileURLWithPath: option("--plugin-dir")
      ?? selfURL.deletingLastPathComponent().appendingPathComponent("KeypadPlugin").path)
  let roots = [
    home.appendingPathComponent(".local/share/Loupedeck"),
    home.appendingPathComponent("Library/Application Support/Logi/LogiPluginService"),
  ]
  if !remove
    && !FileManager.default.fileExists(
      atPath: source.appendingPathComponent("AiAgentDeckPlugin.dll").path)
  {
    failures += 1
    fputs(
      "Keypad plugin is missing from this build. Build it with the vendor SDK before packaging.\n",
      stderr)
    return
  }
  for root in roots where FileManager.default.fileExists(atPath: root.path) {
    let target = root.appendingPathComponent("Plugins/AiAgentDeck")
    let backup = root.appendingPathComponent("Backups/AgentDeck/Plugin-before-native")
    do {
      if !dryRun {
        try FileManager.default.createDirectory(
          at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
          at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !remove {
          if FileManager.default.fileExists(atPath: target.path)
            && !FileManager.default.fileExists(atPath: backup.path)
          {
            try FileManager.default.copyItem(at: target, to: backup)
          }
          let stage = root.appendingPathComponent("Backups/AgentDeck/Staging-" + UUID().uuidString)
          try FileManager.default.copyItem(at: source, to: stage)
          if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
          }
          try FileManager.default.moveItem(at: stage, to: target)
        } else {
          if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
          }
          if FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: backup, to: target)
          }
        }
      }
      print(
        dryRun
          ? "Would update keypad plugin in \(root.lastPathComponent)"
          : "Keypad plugin updated in \(root.lastPathComponent)")
      let apps = root.appendingPathComponent("Applications")
      guard
        let devices = try? FileManager.default.contentsOfDirectory(
          at: apps, includingPropertiesForKeys: nil)
      else { continue }
      for device in devices {
        let profiles = device.appendingPathComponent("@_defaultmac/Profiles")
        guard
          let ids = try? FileManager.default.contentsOfDirectory(
            at: profiles, includingPropertiesForKeys: nil)
        else { continue }
        for id in ids {
          let file = id.appendingPathComponent("ProfileInfo.json")
          guard FileManager.default.fileExists(atPath: file.path) else { continue }
          do { try configureProfile(file) } catch {
            failures += 1
            fputs(
              "Left keypad profile unchanged: \(file.path): \(error.localizedDescription)\n", stderr
            )
          }
        }
      }
    } catch {
      failures += 1
      fputs("Keypad installation failed: \(error.localizedDescription)\n", stderr)
    }
  }
  if !dryRun && option("--home") == nil {
    let app = "/Applications/Utilities/LogiPluginService.app"
    if FileManager.default.fileExists(atPath: app) {
      let stop = Process()
      stop.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
      stop.arguments = ["LogiPluginService"]
      stop.standardError = FileHandle.nullDevice
      if (try? stop.run()) != nil {
        stop.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.7)
      }
      let start = Process()
      start.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      start.arguments = ["-g", app]
      do {
        try start.run()
        start.waitUntilExit()
        print("Keypad service reloaded.")
      } catch {
        failures += 1
        fputs("Open Logi Options+ to activate the keypad page.\n", stderr)
      }
    }
  }
}
private func configureProfile(_ file: URL) throws {
  guard
    var profile = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
    var layout = profile["layout"] as? [String: Any],
    var modes = layout["layoutModes"] as? [[String: Any]]
  else { throw CocoaError(.propertyListReadCorrupt) }
  var plugins = profile["additionalNativePluginNames"] as? [String] ?? []
  plugins.removeAll { $0 == "AiAgentDeck" }
  if !remove { plugins.append("AiAgentDeck") }
  profile["additionalNativePluginNames"] = plugins
  for index in modes.indices {
    if var pages = modes[index]["touchPages"] as? [[String: Any]] {
      pages.removeAll(where: ownedPage)
      if !remove {
        let controls: [[String: Any]] = (0..<12).map { i in
          [
            "$type": "Loupedeck.Service.ProfileLayoutButton, LoupedeckService",
            "pressAction": i < 9 ? actionPrefix + String(i) : NSNull(), "fnPressAction": NSNull(),
          ]
        }
        pages.insert(
          [
            "$type": "Loupedeck.Service.ProfileLayoutButtonPage, LoupedeckService",
            "name": touchPage, "displayName": "AI Agents", "controls": controls,
            "dynamicPageName": NSNull(), "dynamicPagePluginName": NSNull(), "dynamicPageNumber": 0,
          ], at: 0)
      }
      modes[index]["touchPages"] = pages
    }
    if var workspaces = modes[index]["workspaces"] as? [[String: Any]] {
      for i in workspaces.indices {
        if var pages = workspaces[i]["pressPages"] as? [[String: Any]] {
          pages.removeAll(where: ownedPage)
          if !remove {
            let controls = (0..<9).map { i -> [String: Any] in
              [
                "$type":
                  "Loupedeck.Service.Devices.Loupedeck7Devices.ProfileLayoutControl7, LoupedeckService",
                "controlId": i, "pressAction": actionPrefix + String(i), "rotateAction": NSNull(),
              ]
            }
            pages.insert(
              [
                "$type":
                  "Loupedeck.Service.Devices.Loupedeck7Devices.ProfileLayoutPage7, LoupedeckService",
                "name": pressPage, "displayName": "AI Agents", "controls": controls,
                "dynamicPageName": NSNull(), "dynamicPagePluginName": NSNull(),
                "dynamicPageNumber": 0,
              ], at: 0)
          }
          workspaces[i]["pressPages"] = pages
        }
        if var names = workspaces[i]["touchPageNames"] as? [String] {
          names.removeAll { $0 == touchPage }
          if !remove { names.insert(touchPage, at: 0) }
          workspaces[i]["touchPageNames"] = names
        }
      }
      modes[index]["workspaces"] = workspaces
    }
  }
  layout["layoutModes"] = modes
  profile["layout"] = layout
  try write(
    JSONSerialization.data(
      withJSONObject: profile, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
    to: file)
}
