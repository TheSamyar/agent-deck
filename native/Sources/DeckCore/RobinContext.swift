import Foundation

public struct RobinContextObservation: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var source: String
  public var project: String?
  public var text: String
  public var observedAt: Date
  public var corrected: Bool = false
  public init(id:String,source:String,project:String?=nil,text:String,observedAt:Date=Date()) {
    self.id=id;self.source=source;self.project=project;self.text=String(text.prefix(2000));self.observedAt=observedAt
  }
}
public enum RobinContextPolicy {
  public static func context(_ observations:[RobinContextObservation], now:Date=Date(), project:String?, cloud:Bool, allowedSources:Set<String>=[]) -> String {
    observations.filter { now.timeIntervalSince($0.observedAt) >= 0 && now.timeIntervalSince($0.observedAt) < 120 && (!cloud || allowedSources.contains($0.source)) && ($0.project == nil || $0.project == project) && RobinReasoningPolicy.permitsCloud(text:$0.text) }
      .sorted {$0.observedAt > $1.observedAt}.prefix(12).map { "[source: \($0.source); observed: \(ISO8601DateFormatter().string(from:$0.observedAt)); \($0.corrected ? "user corrected" : "observed, may be incomplete")] \($0.text)" }.joined(separator:"\n")
  }
}
