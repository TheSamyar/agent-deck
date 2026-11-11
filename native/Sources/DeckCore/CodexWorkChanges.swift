import Foundation

public enum CodexWorkChange: Equatable, Sendable {
  case toolStarted(id: String, kind: String)
  case toolCompleted(id: String, kind: String)
  case childCreated(id: String)
  case childState(id: String, status: String)
}
/// Supports the installed 0.166 schema and the documented collabToolCall shape.
/// A collaboration call completing is not evidence that its child has completed.
public enum CodexWorkChanges {
  public static func changes(item: [String: Any], started: Bool) -> [CodexWorkChange] {
    guard let id = item["id"] as? String, let type = item["type"] as? String else { return [] }
    let workTypes = ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "collabToolCall", "collabAgentToolCall", "webSearch"]
    guard workTypes.contains(type) else { return [] }
    let kind = type == "commandExecution" ? "Bash" : type
    if started { return [.toolStarted(id: id, kind: kind)] }
    var result: [CodexWorkChange] = []
    if ["collabToolCall", "collabAgentToolCall"].contains(type) {
      if let child = item["newThreadId"] as? String { result.append(.childCreated(id: child)) }
      if item["tool"] as? String == "spawnAgent" {
        for child in item["receiverThreadIds"] as? [String] ?? [] { result.append(.childCreated(id: child)) }
      }
      for (child, value) in item["agentsStates"] as? [String: [String: Any]] ?? [:] {
        if let status = value["status"] as? String { result.append(.childState(id: child, status: status)) }
      }
      if let child = item["receiverThreadId"] as? String {
        if let status = item["agentStatus"] as? String { result.append(.childState(id: child, status: status)) }
        else if let object = item["agentStatus"] as? [String: Any], let status = object["type"] as? String ?? object.keys.first { result.append(.childState(id: child, status: status)) }
      }
    }
    if let status = item["status"] as? String, !SessionWorkLedger.terminal(status) { return result }
    result.append(.toolCompleted(id: id, kind: kind))
    return result
  }
  public static func childTerminal(_ status: String) -> Bool {
    SessionWorkLedger.terminal(status) || ["interrupted", "notFound"].contains(status)
  }
}
