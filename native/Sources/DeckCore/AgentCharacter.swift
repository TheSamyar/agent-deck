import Foundation

public struct AgentCharacter: Equatable, Sendable {
  public enum Expression: String, Sendable { case building, watching, asking, resting, completed, repair, unknown }
  public let variant: Int
  public let color: Int
  public let expression: Expression
  public let shellJobs: Int
  public let subagents: Int
  public init(project: String, state: SessionState, work: SessionWork? = nil) {
    // Stable across launches; Swift's randomized Hasher is unsuitable for identity.
    let seed = project.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    let style = AgentVisualStyle.load(project: project)
    variant = style?.character ?? Int(seed % 4)
    color = style?.color ?? Int(seed % 4)
    shellJobs = max(0, work?.shellJobs ?? 0); subagents = max(0, work?.subagents ?? 0)
    switch state {
    case .working: expression = work?.awaitingResults == true || work?.hasOutstanding == true ? .watching : .building
    case .waiting: expression = .asking
    case .idle: expression = .resting
    case .done: expression = .completed
    case .error: expression = .repair
    default: expression = .unknown
    }
  }
}
