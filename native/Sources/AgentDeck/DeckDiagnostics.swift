import DeckCore
import Foundation

/// Collect metadata without launching the GUI, service, devices, or assistant.
enum DeckDiagnostics {
  static func report() -> DeckDiagnosticReport {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let cache = home.appendingPathComponent("Library/Caches/AgentDeck")
    func object(_ name: String) -> [String: Any] {
      guard let data = DeckDiagnosticCache.read(cache.appendingPathComponent(name)),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
      return value
    }
    func verified(_ pid: Int?, suffix: String) -> Int? {
      guard let pid, let process = ProcessWitness.read(pid) else { return nil }
      let paths = [home.appendingPathComponent("Applications/Agent Deck.app/" + suffix).path, "/Applications/Agent Deck.app/" + suffix]
      return paths.contains(process.executable) ? pid : nil
    }
    let gui = verified(object("window-health.json")["pid"] as? Int, suffix: "Contents/MacOS/AgentDeck")
    let service = verified(object("connection.json")["servicePid"] as? Int, suffix: "Contents/Helpers/DeckService.bundle/Contents/MacOS/deck-service")
    return .init(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
      build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
      guiRunning: gui != nil, serviceRunning: service != nil,
      hardware: DeckDiagnosticCache.read(cache.appendingPathComponent("masterhub-diagnostics.json")), verifiedGUI: gui,
      now: Date().timeIntervalSince1970)
  }
}
