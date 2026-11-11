import CryptoKit
import Foundation

public enum SessionState: String, Codable, Sendable, CaseIterable {
  case working = "WORKING"
  case waiting = "WAITING"
  case done = "DONE"
  case idle = "IDLE"
  case disconnected = "DISCONNECTED"
  case unknown = "UNKNOWN"
  case error = "ERROR"
  public var label: String {
    switch self {
    case .working: "Working"
    case .waiting: "Needs input"
    case .done: "Finished"
    case .idle: "Idle"
    case .disconnected: "Disconnected"
    case .unknown: "Unknown"
    case .error: "Error"
    }
  }
}
public struct Capabilities: Codable, Sendable, Equatable {
  public var focus = false
  public var approve = false
  public var answer = false
  public var interrupt = false
  public var reason = "This integration reports status only."
  public init() {}
}
public struct SessionSnapshot: Codable, Identifiable, Sendable, Equatable {
  public var id: String
  public var agentId: String
  public var agentName: String
  public var workspace: String
  public var cwd: String
  public var providerSessionId: String
  public var hostInstanceId: String
  public var bundleId: String
  public var pid: Int
  public var processBirth: String? = nil
  public var work: SessionWork? = nil
  public var tty: String
  public var terminalId: String
  public var status: SessionState
  public var detail: String
  public var tool: String
  public var updatedAt: Double
  public var startedAt: Double
  public var lastHookAt: Double
  public var capabilities: Capabilities
  public var projectKey: String { cwd.isEmpty ? "session:" + id : cwd }
  public var shortName: String { agentId.uppercased() }
  public var instanceLabel: String { workspace }
  public static func identity(
    agent: String, providerID: String, cwd: String, host: String, pid: Int
  ) -> String {
    let canonical = URL(fileURLWithPath: cwd).standardizedFileURL.path
    let source = providerID.isEmpty ? "\(canonical)|\(host)|\(pid)" : "\(host)|\(providerID)"
    let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    return "\(agent):\(digest)"
  }
}
public struct RequestChoice: Codable, Identifiable, Sendable, Equatable {
  public var id: String
  public var label: String
  public var requiresHold: Bool
  public init(id: String, label: String, requiresHold: Bool = false) {
    self.id = id
    self.label = label
    self.requiresHold = requiresHold
  }
}
public struct PendingRequest: Codable, Identifiable, Sendable, Equatable {
  public var id: String
  public var sessionId: String
  public var title: String
  public var context: String
  public var choices: [RequestChoice]
  public var createdAt: Double
  public var expiresAt: Double
  public var state: String
  public var revision: Int
  public var source: String
  public var toolUseId: String? = nil
}
public struct ActivityEvent: Codable, Identifiable, Sendable {
  public var id = UUID().uuidString
  public var timestamp: Double
  public var sessionId: String
  public var title: String
  public var outcome: String
}
public struct DeckPreferences: Codable, Sendable, Equatable {
  public var pinnedSessionIds: [String] = []
  public var projectNames: [String: String] = [:]
  public var mutedProjects: [String] = []
  public var showIdleSessions: Bool? = nil
  public var toolHookApprovals: Bool? = nil
  public var automaticSingleAgent = false
  public var reduceMotion = false
  public var notifications = false
  public var showSensitiveNotifications = false
  public var enabledAgents = ["claude", "codex", "cursor", "gemini", "antigravity"]
  public init() {}
}
public struct TileSnapshot: Codable, Identifiable, Sendable, Equatable {
  public var id: String { key }
  public var key: String
  public var type: String
  public var label: String
  public var sublabel: String
  public var detail: String
  public var status: String
  public var action: String
  public var target: String
  public var requestId: String
  public var choiceId: String
  public var enabled: Bool
  public var requiresHold: Bool
  public var svg: String
  public init(
    key: String, type: String = "action", label: String, sublabel: String = "", detail: String = "",
    status: String = "IDLE", action: String = "none", target: String = "", requestId: String = "",
    choiceId: String = "", enabled: Bool = true, requiresHold: Bool = false
  ) {
    self.key = key
    self.type = type
    self.label = label
    self.sublabel = sublabel
    self.detail = detail
    self.status = status
    self.action = action
    self.target = target
    self.requestId = requestId
    self.choiceId = choiceId
    self.enabled = enabled
    self.requiresHold = requiresHold
    self.svg = ""
  }
}
public struct ActionCommand: Codable, Sendable {
  public var id: String
  public var action: String
  public var sessionId: String
  public var requestId: String
  public var choiceId: String
  public var revision: Int?
  public var voiceConfirmation: String? = nil
  public var heldMs: Int
  public init(
    id: String = UUID().uuidString, action: String, sessionId: String = "", requestId: String = "",
    choiceId: String = "", revision: Int? = nil, heldMs: Int = 0
  ) {
    self.id = id
    self.action = action
    self.sessionId = sessionId
    self.requestId = requestId
    self.choiceId = choiceId
    self.revision = revision
    self.heldMs = heldMs
  }
}
public struct ActionResult: Codable, Sendable, Equatable {
  public var ok: Bool
  public var state: String
  public var message: String
  public var error: String?
  public var commandId: String
  public init(ok: Bool, state: String, message: String, commandId: String = "") {
    self.ok = ok
    self.state = state
    self.message = message
    self.error = ok ? nil : message
    self.commandId = commandId
  }
  public static func failure(_ text: String, id: String = "") -> Self {
    .init(ok: false, state: "rejected", message: text, commandId: id)
  }
}
public struct DeckSummary: Codable, Sendable {
  public var workingCount: Int
  public var waitingCount: Int
  public var doneCount: Int
  public var headline: String
}
public struct DeckSnapshot: Codable, Sendable {
  public var handoffs: [AgentHandoff]? = nil
  public var instanceId: String? = nil
  public var stateVersion: Int? = nil
  public var protocolVersion = 2
  public var ok = true
  public var timestamp: Double
  public var revision: Int
  public var layoutMode: String
  public var selectedSessionId: String
  public var sessionCount: Int
  public var page: Int
  public var pageCount: Int
  public var summary: DeckSummary
  public var sessions: [String: SessionSnapshot]
  public var requests: [PendingRequest]
  public var tiles: [TileSnapshot]
  public var dial: TileSnapshot
  public var recentEvents: [ActivityEvent]
  public var lastAction: ActionResult?
  public var lastError: String
  public var preferences: DeckPreferences
}
public enum DeckClock { public static var now: Double { Date().timeIntervalSince1970 * 1000 } }
public func agentName(_ id: String) -> String {
  switch id {
  case "claude": "Claude Code"
  case "codex": "Codex"
  case "cursor": "Cursor"
  case "gemini": "Gemini CLI"
  case "antigravity": "Antigravity"
  default: id.capitalized
  }
}
public func workspaceName(_ title: String) -> String {
  let trimmed =
    title.components(separatedBy: " — The following extensions want to relaunch").first ?? title
  let pieces = trimmed.components(separatedBy: " — ")
  return pieces.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
}
