import AppKit
import DeckCore

@MainActor enum MasterHUBAppIcon {
  private static var cache: [String: NSImage] = [:]
  static func image(for binding: MasterHUBKeyBinding?) -> NSImage? {
    if binding?.kind == .supervisor { return RobinArtwork.image(state: "Ready", phase: 0) }
    guard let binding, binding.kind == .application else { return nil }
    let key = binding.bundleID + ":" + binding.applicationPath
    if let image = cache[key] { return image }
    let url = (!binding.bundleID.isEmpty ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: binding.bundleID) : nil)
      ?? (FileManager.default.fileExists(atPath: binding.applicationPath) ? URL(fileURLWithPath: binding.applicationPath) : nil)
    guard let url else { return nil }
    let image = NSWorkspace.shared.icon(forFile: url.path)
    cache[key] = image
    return image
  }
}
