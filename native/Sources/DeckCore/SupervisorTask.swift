import Foundation

public enum SupervisedProvider: String, Codable, CaseIterable, Sendable {
  case codex, claude, cursor, gemini
  public var title: String { switch self { case .codex: "Codex"; case .claude: "Claude"; case .cursor: "Cursor"; case .gemini: "Gemini · Antigravity" } }
  public var executableNames: [String] { switch self {
    case .codex: ["codex"]; case .claude: ["claude"]; case .cursor: ["agent", "cursor-agent"]; case .gemini: ["agy"]
  } }
  public func arguments(session: String?, prompt: String) -> [String] {
    switch self {
    case .codex:
      return session.map { ["exec", "resume", "--json", $0, "-"] }
        ?? ["exec", "--json", "--sandbox", "workspace-write", "-"]
    case .claude:
      return ["--print", "--verbose", "--output-format", "stream-json"]
        + (session.map { ["--resume", $0] } ?? [])
    case .gemini:
      return ["--output-format", "stream-json"]
        + (session.map { ["--conversation", $0] } ?? []) + ["--print", prompt]
    case .cursor:
      return ["--print", "--output-format", "stream-json"]
        + (session.map { ["--resume", $0] } ?? []) + [prompt]
    }
  }
}

public enum SupervisedTaskState: String, Codable, Sendable {
  case working, review, blocked, stopped, done
}

public struct SupervisedTask: Codable, Identifiable, Sendable, Equatable {
  public var id = UUID().uuidString
  public var provider: SupervisedProvider
  public var cwd: String
  public var goal: String
  public var criteria: String
  public var session: String?
  public var pid: Int?
  public var processBirth: String?
  public var state: SupervisedTaskState = .working
  public var revision = 0
  public var turns = 0
  public var automaticTurns = 0
  public var result = ""
  public var lastPrompt = ""
  public var updatedAt = Date()
  public init(provider: SupervisedProvider, cwd: String, goal: String, criteria: String) {
    self.provider = provider; self.cwd = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path
    self.goal = goal; self.criteria = criteria
  }
  public var initialPrompt: String {
    "Task: \(goal)\nAcceptance criteria: \(criteria)\nWork until these criteria are met. Verify your work and report evidence, failures, and remaining blockers. Do not bypass tool permissions."
  }
}

public struct SupervisorDecision: Codable, Sendable, Equatable {
  public enum Action: String, Codable, Sendable { case followUp, done, ask }
  public var action: Action
  public var prompt: String
  public var reason: String
  public var lesson: String?
  public init(action: Action, prompt: String = "", reason: String, lesson: String? = nil) {
    self.action = action; self.prompt = prompt; self.reason = reason; self.lesson = lesson
  }
  public static func decode(_ text: String) throws -> Self {
    var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if clean.hasPrefix("```"), let start = clean.firstIndex(of: "\n"), let end = clean.range(of: "```", options: .backwards), start < end.lowerBound {
      clean = String(clean[clean.index(after: start)..<end.lowerBound])
    }
    let result = try JSONDecoder().decode(Self.self, from: Data(clean.utf8))
    guard !result.reason.isEmpty, result.prompt.count <= 16000,
      result.action != .followUp || !result.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CocoaError(.coderReadCorrupt)
    }
    return result
  }
  public static func mayAutomate(task: SupervisedTask, enabledProjects: Set<String>, decision: Self) -> Bool {
    task.state == .review && task.session != nil && enabledProjects.contains(task.cwd)
      && task.automaticTurns < 5 && decision.action == .followUp
      && !decision.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && decision.prompt != task.lastPrompt
  }
}

/// Parses only documented result/session events; never interprets arbitrary output as commands.
public struct SupervisedOutput: Sendable {
  public var session: String?
  public var result = ""
  public var failed = false
  public var completed = false
  public init() {}
  public mutating func ingest(_ line: Data, provider: SupervisedProvider) {
    guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
    if provider == .gemini {
      // Antigravity's current headless protocol uses event/result envelopes.
      // Legacy Gemini CLI output is not accepted as a completed agy task.
      let kind = event["event"] as? String ?? ""
      if kind == "init", let id = event["conversation_id"] as? String, !id.isEmpty { session = id }
      if kind == "step_update", let step = event["step_update"] as? [String: Any] {
        if step["step_type"] as? String == "agent_response", let text = step["text_delta"] as? String {
          result = String((result + text).suffix(60000))
        }
        if let tool = step["tool_info"] as? [String: Any], tool["error"] != nil { failed = true }
      }
      if kind == "result", let terminal = event["result"] as? [String: Any] {
        completed = true
        failed = failed || terminal["status"] as? String != "SUCCESS" || terminal["error"] != nil
        if let id = terminal["conversation_id"] as? String, !id.isEmpty { session = id }
        if let text = terminal["response"] as? String { result = String(text.suffix(60000)) }
        if result.isEmpty, let error = terminal["error"] as? String { result = String(error.suffix(60000)) }
      }
      return
    }
    let type = event["type"] as? String ?? ""
    if let id = event["session_id"] as? String, !id.isEmpty { session = id }
    if type == "thread.started" { session = event["thread_id"] as? String }
    if type == "result" {
      completed = true
      failed = failed || event["is_error"] as? Bool == true || (event["subtype"] as? String ?? "success") != "success"
      if let text = event["result"] as? String { result = String(text.suffix(60000)) }
      if let denials = event["permission_denials"] as? [Any], !denials.isEmpty { failed = true }
      if result.isEmpty, let errors = event["errors"] as? [String] { result = errors.joined(separator: "\n") }
    }
    if type == "item.completed", let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message", let text = item["text"] as? String {
      result = String((result + "\n" + text).suffix(60000))
    }
    if type == "turn.completed" { completed = true }
    if type == "turn.failed" || type == "error" {
      failed = true
      if let error = event["error"] as? [String: Any], let message = error["message"] as? String { result = message }
      else if let message = event["message"] as? String { result = message }
    }
  }
}
