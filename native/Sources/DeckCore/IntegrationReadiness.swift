import Foundation

/// Configuration readiness is deliberately separate from a currently observed session.
public enum IntegrationConfigurationState: String, Sendable, Equatable {
  case ready, missing, invalid, externalNotify, unsupported
  public var label: String {
    switch self {
    case .ready: "Hooks installed"
    case .missing: "Setup needed"
    case .invalid: "Check configuration"
    case .externalNotify: "Existing notify preserved"
    case .unsupported: "Experimental"
    }
  }
}

public enum IntegrationReadiness {
  public static func configuration(agent: String, text: String?, hookPath: String) -> IntegrationConfigurationState {
    guard agent != "antigravity" else { return .unsupported }
    guard let text else { return .missing }
    if agent == "codex" && !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
      // The installer supports a one-line JSON-compatible notify array only.
      var notifyLine: String?
      for rawLine in text.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        // A TOML table changes the scope for every following key.
        if line.hasPrefix("[") { break }
        guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        if key == "notify" {
          guard notifyLine == nil else { return .invalid }
          notifyLine = line
        }
      }
      guard let line = notifyLine, let equals = line.firstIndex(of: "=") else { return .missing }
      let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
      guard let argv = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String],
        !argv.isEmpty else { return .invalid }
      func nativeCommand(_ command: [String]) -> Bool {
        command.count >= 3 && command[0] == hookPath && command[1] == "codex" && command[2] == "turn-ended"
      }
      if nativeCommand(argv) { return .ready }
      return .externalNotify
    }
    guard let data = text.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any]
    else { return .invalid }
    guard let hooks = root["hooks"] as? [String: Any] else {
      return root["hooks"] == nil ? .missing : .invalid
    }
    let required: [String]
    switch agent {
    case "codex": required = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop", "SessionEnd"]
    case "claude": required = ["SessionStart", "PermissionRequest", "Stop"]
    case "cursor": required = ["beforeSubmitPrompt", "beforeShellExecution", "beforeMCPExecution", "stop"]
    case "gemini": required = ["SessionStart", "BeforeTool", "AfterAgent"]
    default: return .unsupported
    }
    func owns(_ value: Any, event: String) -> Bool {
      if let object = value as? [String: Any] {
        if let command = object["command"] as? String {
          // Match the executable token, not arbitrary text in another hook's arguments.
          let quoted = "\"" + hookPath.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
          if command.trimmingCharacters(in: .whitespacesAndNewlines) == quoted + " " + agent + " " + event { return true }
          if !hookPath.contains(where: { $0.isWhitespace }), command.trimmingCharacters(in: .whitespacesAndNewlines) == hookPath + " " + agent + " " + event { return true }
        }
        return (object["hooks"] as? [Any])?.contains(where: { owns($0, event: event) }) ?? false
      }
      return (value as? [Any])?.contains(where: { owns($0, event: event) }) ?? false
    }
    return required.allSatisfy { event in hooks[event].map { owns($0, event: event) } ?? false } ? .ready : .missing
  }
}
