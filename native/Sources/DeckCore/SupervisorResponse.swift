import Foundation

public struct SupervisorConversationReply: Codable, Sendable {
  public struct Draft: Codable, Sendable {
    public var taskId: String
    public var prompt: String
  }
  public var reply: String
  public var lesson: String?
  public var draft: Draft?
  public static func decode(_ text: String) throws -> Self {
    let result = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
    guard !result.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CocoaError(.coderReadCorrupt) }
    return result
  }
}

/// JSON mode alone permits any object. These schemas constrain the actual contract.
public enum SupervisorResponseFormat: Sendable {
  case conversation, decision
  public var requestValue: [String: Any] {
    let string: [String: Any] = ["type": "string"]
    let nullableString: [String: Any] = ["type": ["string", "null"]]
    let properties: [String: Any]
    switch self {
    case .conversation:
      properties = ["reply": ["type": "string", "minLength": 1], "lesson": nullableString,
        "draft": ["anyOf": [["type": "null"], ["type": "object", "additionalProperties": false,
          "properties": ["taskId": string, "prompt": string], "required": ["taskId", "prompt"]]]]]
    case .decision:
      properties = ["action": ["type": "string", "enum": ["followUp", "done", "ask"]], "prompt": string,
        "reason": ["type": "string", "minLength": 1], "lesson": nullableString]
    }
    return ["type": "json_schema", "json_schema": ["name": self == .conversation ? "supervisor_conversation" : "supervisor_decision",
      "strict": true, "schema": ["type": "object", "additionalProperties": false,
        "properties": properties, "required": properties.keys.sorted()]]]
  }
}
