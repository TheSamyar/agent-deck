import Foundation

/// Wake capture never resolves permission requests. Only finalized utterances with
/// an anchored wake phrase may reach the assistant's normal command path.
public enum RobinWakeCommand: Equatable, Sendable {
  case ignore, wakeOnly, restrictedApproval, overview, open(String), dictate(String), command(String)

  public static func parse(_ utterance: String) -> Self {
    let clean = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let prefix = clean.range(of: #"^hey[\s,!.]+alfred\b[\s,!.?:;—-]*"#, options: [.regularExpression, .caseInsensitive]) else { return .ignore }
    let command = String(clean[prefix.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else { return .wakeOnly }
    let normalized = command.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    if ["approve", "allow", "allow once", "deny", "yes", "no", "approve that", "approve it"].contains(normalized) { return .restrictedApproval }
    if ["what is happening", "what's happening", "what’s happening", "what are my agents doing", "what are the agents doing", "status", "give me a status update"].contains(normalized) { return .overview }
    if normalized.hasPrefix("open ") {
      let target = String(command.dropFirst(5)).trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
      return target.isEmpty ? .wakeOnly : .open(target)
    }
    for prefix in ["dictate a task ", "draft a task ", "new task "] where normalized.hasPrefix(prefix) {
      let text = String(command.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? .wakeOnly : .dictate(text)
    }
    return .command(command)
  }
}
