import Foundation

/// Minimize data crossing the local socket. Prompts, outputs, and transcripts
/// are never needed for status; exact Claude permission context is the exception.
public enum HookMetadata {
  public static func filtered(_ payload: [String: Any], permissionContext: Bool) -> [String: Any] {
    let fields: Set<String> = ["session_id", "sessionId", "thread-id", "threadId", "conversation_id", "conversationId",
      "cwd", "workspace", "workspace_roots", "agent_id", "agent_type", "parent_thread_id", "parentThreadId",
      "tool_name", "tool", "tool_use_id", "notification_type", "source", "turn_id", "generation_id", "work_id", "work_kind"]
    var result = payload.filter { fields.contains($0.key) }
    if let transcript = payload["transcript_path"] as? String, transcript.contains("/subagents/") { result["agent_id"] = payload["agent_id"] ?? "nested-subagent" }
    if let error = payload["error"], !(error is NSNull), (error as? Bool) != false { result["error"] = true }
    if let tasks = payload["background_tasks"] as? [[String: Any]] {
      var filtered = tasks.prefix(256).map { $0.filter { ["id", "type", "status"].contains($0.key) } }
      if tasks.count > 256 { filtered.append(["id": "unverified-overflow", "type": "background", "status": "unknown"]) }
      result["background_tasks"] = filtered
    }
    if let crons = payload["session_crons"] as? [[String: Any]] {
      result["session_crons"] = crons.prefix(256).map { $0.filter { ["id", "recurring"].contains($0.key) } }
    }
    let input = payload["tool_input"] as? [String: Any] ?? [:]
    let tool = (payload["tool_name"] as? String ?? payload["tool"] as? String ?? "").lowercased()
    let kind = ["agent", "task"].contains(tool) ? "subagent" : tool == "bash" || tool.contains("shell") || tool.hasSuffix("exec_command") ? "shell" : "background"
    if input["run_in_background"] as? Bool == true { result["background"] = true; result["background_kind"] = kind }
    let response = payload["tool_response"] as? [String: Any] ?? [:]
    if let id = response["backgroundTaskId"] as? String ?? response["background_task_id"] as? String {
      result["background_job"] = ["id": id, "type": kind, "status": response["status"] as? String ?? "running"]
    }
    if permissionContext {
      for key in ["command", "file_path", "reason", "mcp_name"] {
        if let value = payload[key] { result[key] = value }
      }
      if let input = payload["tool_input"] as? [String: Any] {
        let allowedInputKeys: Set<String> = [
          "command", "file_path", "path", "dir_path", "url", "server_name", "reason",
        ]
        result["tool_input"] = input.filter { allowedInputKeys.contains($0.key) }
      }
    }
    return result
  }
}
