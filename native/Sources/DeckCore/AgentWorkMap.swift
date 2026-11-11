import Foundation

public struct AgentWorkNode: Equatable, Sendable, Identifiable {
  public let id: String
  public let kind: SessionDependency.Kind
  public let state: SessionDependency.State
  public let count: Int
  public static func nodes(for work: SessionWork) -> [Self] {
    let counts: [(SessionDependency.Kind,Int)] = [(.shell,work.shellJobs),(.subagent,work.subagents),(.tool,work.tools)]
    let total = counts.reduce(0) { $0+$1.1 }
    let dependencies = work.dependencies ?? []
    let complete = dependencies.count == total && counts.allSatisfy { kind,count in dependencies.filter { $0.kind == kind }.count == count }
    if total > 0 && total <= 4 && complete {
      return dependencies.map { .init(id:$0.id,kind:$0.kind,state:$0.state,count:1) }
    }
    return counts.filter { $0.1 > 0 }.map { kind,count in
      let evidence = dependencies.filter { $0.kind == kind }
      let state: SessionDependency.State = evidence.contains { $0.state == .needsInput } ? .needsInput : evidence.contains { $0.state == .unknown } ? .unknown : .working
      return .init(id:kind.rawValue,kind:kind,state:state,count:count)
    }
  }
}
