import Foundation
import CryptoKit

public struct SessionDependency: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable { case shell, subagent, tool }
  public enum State: String, Codable, Sendable { case working, needsInput, unknown }
  public init(id: String, kind: Kind, state: State) { self.id = id; self.kind = kind; self.state = state }
  public let id: String
  public let kind: Kind
  public let state: State
}


public struct SessionWork: Codable, Equatable, Sendable {
  public var dependencies: [SessionDependency]? = nil
  public var subagents: Int
  public var shellJobs: Int
  public var tools: Int
  public var awaitingResults: Bool
  public var scheduledWakeups: Int
  public init(subagents: Int, shellJobs: Int, tools: Int, awaitingResults: Bool, scheduledWakeups: Int, needsInput: Bool? = nil, dependencies: [SessionDependency]? = nil) {
    self.dependencies = dependencies.map { Array($0.prefix(64)) }
    self.subagents = max(0, subagents); self.shellJobs = max(0, shellJobs); self.tools = max(0, tools)
    self.awaitingResults = awaitingResults; self.scheduledWakeups = max(0, scheduledWakeups); self.needsInput = needsInput
  }
  public var needsInput: Bool? = nil
  public var hasOutstanding: Bool { subagents + shellJobs + tools > 0 }
  public var label: String {
    if subagents > 0 && shellJobs > 0 { return "Background work" }
    if subagents > 0 { return "Subagents running" }
    if shellJobs > 0 { return "Shell running" }
    if tools > 0 { return "Tools running" }
    return "Processing results"
  }
}

/// A stop is final only if the root itself stops with no outstanding work.
/// Dependency completion alone never finishes the root: it may need to consume results.
public struct SessionWorkLedger: Sendable {
  private var children = Set<String>()
  private var background: [String: String] = [:]
  private var foreground: [String: String] = [:]
  private var anonymous: [String: Int] = [:]
  private var paused = false
  private var scheduled = 0
  private var turnID: String?
  private var blockedChildren = Set<String>()
  private var rootNeedsInput = false
  public init() {}
  public var summary: SessionWork {
    let registryChildren = background.values.filter { $0 == "subagent" }.count
    let foregroundShells = foreground.values.filter(Self.shellTool).count + anonymous.filter { Self.shellTool($0.key) }.values.reduce(0,+)
    let shells = background.values.filter { $0 == "shell" }.count + foregroundShells
    func dependency(_ id: String, _ kind: SessionDependency.Kind, blocked: Bool = false) -> SessionDependency {
      let digest = SHA256.hash(data: Data((kind.rawValue + ":" + id).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
      return .init(id: digest, kind: kind, state: blocked ? .needsInput : id.hasPrefix("unverified-") || id.hasPrefix("unidentified-") ? .unknown : .working)
    }
    var dependencies = children.sorted().map { dependency($0, .subagent, blocked: blockedChildren.contains($0)) }
    dependencies += background.sorted { $0.key < $1.key }.map { dependency($0.key, $0.value == "shell" ? .shell : $0.value == "subagent" ? .subagent : .tool) }
    dependencies += foreground.sorted { $0.key < $1.key }.map { dependency($0.key, Self.shellTool($0.value) ? .shell : .tool) }
    return .init(subagents: max(children.count, registryChildren), shellJobs: shells,
      tools: foreground.count + anonymous.values.reduce(0,+) + background.count - registryChildren - shells,
      awaitingResults: paused, scheduledWakeups: scheduled, needsInput: rootNeedsInput || !blockedChildren.isEmpty, dependencies: dependencies)
  }
  public mutating func observe(_ event: String, data: [String: Any]) -> Bool {
    let key = event.lowercased().filter(\.isLetter)
    let incomingTurn = data["turn_id"] as? String ?? data["generation_id"] as? String
    if ["stop", "turnended", "afteragent", "posttooluse", "posttoolusefailure", "aftertool", "aftermcpexecution", "aftershellexecution", "afterfileedit"].contains(key), let turnID, let incomingTurn, incomingTurn != turnID { return false }
    if ["userpromptsubmit", "beforesubmitprompt", "beforeagent"].contains(key) {
      turnID = incomingTurn; paused = false; rootNeedsInput = false; foreground.removeAll(); anonymous.removeAll()
    }
    if let tasks = data["background_tasks"] as? [[String: Any]] {
      background.removeAll(); children.removeAll()
      if !tasks.contains(where: { ($0["type"] as? String) == "subagent" && !Self.terminal($0["status"] as? String ?? "running") }) { blockedChildren.removeAll() }
      for (index, task) in tasks.enumerated() where !Self.terminal(task["status"] as? String ?? "running") {
        background[String((task["id"] as? String ?? "unidentified-\(index)").prefix(200))] = task["type"] as? String ?? "background"
      }
    }
    if let crons = data["session_crons"] as? [[String: Any]] { scheduled = crons.count }
    let childID = data["agent_id"] as? String ?? ""
    if key == "subagentstart", !childID.isEmpty { children.insert(String(childID.prefix(200))) }
    if key == "subagentstop", !childID.isEmpty { children.remove(childID); blockedChildren.remove(childID) }
    let tool = data["tool_name"] as? String ?? data["tool"] as? String ?? "tool"
    let toolID = data["tool_use_id"] as? String ?? ""
    if ["pretooluse", "beforetool", "preinvocation"].contains(key) {
      paused = false; rootNeedsInput = false
      if toolID.isEmpty { anonymous[tool, default: 0] += 1 } else { foreground[toolID] = tool }
    }
    if ["posttooluse", "posttoolusefailure", "aftertool", "aftermcpexecution", "aftershellexecution", "afterfileedit"].contains(key) {
      rootNeedsInput = false
      if toolID.isEmpty { anonymous[tool] = max(0, (anonymous[tool] ?? 0)-1) } else { foreground.removeValue(forKey: toolID) }
      if data["background"] as? Bool == true {
        background["tool:" + (toolID.isEmpty ? tool : toolID)] = data["background_kind"] as? String ?? "background"
      }
    }
    if let job = data["background_job"] as? [String: Any], let id = job["id"] as? String {
      if Self.terminal(job["status"] as? String ?? "running") {
        background.removeValue(forKey: id)
        if !toolID.isEmpty { background.removeValue(forKey: "tool:" + toolID) }
      } else {
        background[id] = job["type"] as? String ?? "shell"
        if !toolID.isEmpty { background.removeValue(forKey: "tool:" + toolID) }
      }
    }
    if key == "backgroundworkstarted", let id = data["work_id"] as? String { background[id] = data["work_kind"] as? String ?? "background" }
    if key == "backgroundworkcompleted", let id = data["work_id"] as? String { background.removeValue(forKey: id) }
    if ["stop", "turnended", "afteragent"].contains(key) { paused = summary.hasOutstanding }
    if key == "permissionrequest" || (key == "notification" && ["permission_prompt", "elicitation_dialog"].contains(data["notification_type"] as? String ?? "")) { rootNeedsInput = true }
    if key == "interrupt" { rootNeedsInput = false; foreground.removeAll(); anonymous.removeAll(); paused = summary.hasOutstanding }
    return true
  }
  public mutating func observeChild(_ event: String, data: [String: Any]) {
    let id = data["agent_id"] as? String ?? "unidentified-child"
    let key = event.lowercased().filter(\.isLetter)
    if key == "permissionrequest" || (key == "notification" && ["permission_prompt", "elicitation_dialog"].contains(data["notification_type"] as? String ?? "")) { blockedChildren.insert(id) }
    if ["pretooluse", "posttooluse", "posttoolusefailure", "stop", "subagentstop"].contains(key) { blockedChildren.remove(id) }
  }
  public mutating func inputResolved() { rootNeedsInput = false }
  private static func shellTool(_ name: String) -> Bool {
    let value = name.lowercased()
    return value == "bash" || value.contains("shell") || value.hasSuffix("exec_command")
  }
  public static func terminal(_ status: String) -> Bool {
    ["completed", "complete", "done", "failed", "error", "errored", "cancelled", "canceled", "killed", "stopped", "shutdown", "declined", "interrupted"].contains(status.lowercased())
  }
}
