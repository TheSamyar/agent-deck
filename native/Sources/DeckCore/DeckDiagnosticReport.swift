import CoreFoundation
import Darwin
import Foundation

/// A fixed schema: raw cache values, sessions, prompts and connection secrets never serialize.
public struct DeckDiagnosticReport: Codable, Sendable {
  public struct Check: Codable, Sendable {
    public let id: String
    public let state: String
    public let detail: String
    public let nextAction: String
    public init(_ id: String, _ state: String, _ detail: String, _ nextAction: String) {
      self.id = id; self.state = state; self.detail = detail; self.nextAction = nextAction
    }
  }
  public let schemaVersion: Int
  public let application: String
  public let version: String
  public let build: String
  public let checks: [Check]
  public let scope: String
  public init(version: String, build: String, guiRunning: Bool, serviceRunning: Bool,
              hardware: Data?, verifiedGUI: Int?, now: TimeInterval) {
    schemaVersion = 1; application = "Agent Deck"
    self.version = Self.numeric(version); self.build = Self.numeric(build)
    scope = "Local process and cached hardware checks only. No physical input test, permission request, agent command or network request. No prompts, paths, account details or credentials."
    var rows: [Check] = [
      .init("dashboard", guiRunning ? "ready" : "unavailable", guiRunning ? "Installed dashboard process is running" : "Installed dashboard process is not running", guiRunning ? "No action needed" : "Open Agent Deck"),
      .init("service", serviceRunning ? "ready" : "unavailable", serviceRunning ? "Installed service process is running; authentication not tested here" : "Installed service process is not running", serviceRunning ? "Use Check setup if controls do not respond" : "Open Agent Deck; use Check setup if the service stays disconnected")]
    let unknown = Check("hardware", "unknown", "No fresh hardware report from the installed dashboard", "Open Agent Deck; check the USB cable, then run this check again")
    if let hardware, hardware.count <= 65_536,
      let values = try? JSONSerialization.jsonObject(with: hardware) as? [String: Any],
      let expected = verifiedGUI, expected > 0, Self.integer(values["pid"]) == expected,
      let updated = values["updatedAt"] as? NSNumber, CFGetTypeID(updated) != CFBooleanGetTypeID(),
      updated.doubleValue.isFinite, now.isFinite, now - updated.doubleValue >= -5, now - updated.doubleValue <= 10 {
      let fields = ["keypadConnected", "rollerConnected", "knobsConnected", "screenDialConnected"]
      let connected = fields.compactMap { key -> Bool? in
        guard let value = values[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }; return value.boolValue
      }
      let counts = ["displayFailures", "screenDialDisplayFailures", "inputErrors"].compactMap { Self.integer(values[$0]) }
      if connected.count == 4 && counts.count == 3 {
        let count = connected.filter { $0 }.count
        let healthy = count == 4 && counts.allSatisfy { $0 == 0 }
        rows.append(.init("hardware", healthy ? "ready" : "needsAttention", "\(count) of 4 modules connected; keypad display errors: \(counts[0]); dial display errors: \(counts[1]); input errors: \(counts[2])", healthy ? "Use Check controls for a safe physical button test" : "Check the USB cable; open MasterHUB → Check controls"))
      } else { rows.append(unknown) }
    } else { rows.append(unknown) }
    checks = rows
  }
  public func json() throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(self)
  }
  public static func saveNew(_ data: Data, to url: URL) throws {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw CocoaError(.fileWriteFileExists) }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    try file.write(contentsOf: data)
    try file.synchronize()
  }
  private static func numeric(_ text: String) -> String {
    !text.isEmpty && text.utf8.count <= 32 && text.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") } ? text : "development"
  }
  private static func integer(_ value: Any?) -> Int? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
      n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue < 9_007_199_254_740_992,
      n.doubleValue.rounded(.towardZero) == n.doubleValue else { return nil }
    return n.intValue
  }
}

public enum DeckDiagnosticCache {
  public static func read(_ file: URL) -> Data? {
    let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
      info.st_mode & 0o022 == 0, info.st_size > 0, info.st_size <= 65_536,
      let data = try? handle.read(upToCount: 65_537), data.count <= 65_536 else { return nil }
    return data
  }
}
