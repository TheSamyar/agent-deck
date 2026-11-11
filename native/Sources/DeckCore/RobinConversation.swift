import Foundation

public struct RobinConversationQuestion: Codable, Equatable, Sendable {
  public var project: String
  public var goal: String
  public var question: String
  public init(project: String, goal: String, question: String) { self.project=project; self.goal=goal; self.question=question }
  public func continuing(with answer: String) -> String {
    "Continue this existing request using the answer below. Do not treat it as a separate task.\nOriginal request: \(goal)\nQuestion: \(question)\nUser answer: \(answer)"
  }
}
public enum RobinConversation {
  public static func history(_ messages: [SupervisorMessage], project: String, cloud: Bool, personalScope:String? = nil) -> [[String:String]] {
    messages.filter { ["user","assistant"].contains($0.role) && ($0.project == project || (!cloud && $0.project == nil)) && (!cloud || ($0.personalScope == personalScope && !$0.content.isEmpty && RobinReasoningPolicy.permitsCloud(text:$0.content))) }.suffix(12).map { ["role":$0.role,"content":String($0.content.prefix(2000))] }
  }
  public static let instruction = "Act as an active teammate. When a goal is vague, ask one focused question about the desired result before acting. Ask about meaningful choices, acceptance criteria and conflicting priorities; recommend one option. Do not ask questions whose answers are already in the conversation. Use clarify to ask one question and wait. Resolve answers such as the second one against the pending question. Never interpret an ordinary conversational yes as tool permission. Keep questions short and grounded in actual context."
}
