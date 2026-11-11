import Foundation

/// Ordinary conversational replies never carry approval authority.
public enum RobinConversationVoiceReply: Equatable, Sendable {
  case answer(String), later, cancel, empty
  public static func parseFinal(_ text: String) -> Self {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch clean.lowercased().trimmingCharacters(in: .punctuationCharacters) {
    case "": return .empty
    case "later", "not now": return .later
    case "cancel", "stop listening", "stop": return .cancel
    default: return .answer(clean)
    }
  }
}
