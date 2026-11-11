import Foundation

public struct JarvisStep: Codable, Sendable {
  public enum Kind: String, Codable, Sendable { case respond, act, clarify }
  public var kind: Kind
  public var reply: String
  public var action: JarvisActionKind?
  public var arguments: Arguments
  public init(kind:Kind,reply:String="",action:JarvisActionKind?=nil,arguments:Arguments = .init()) {
    self.kind=kind;self.reply=reply;self.action=action;self.arguments=arguments
  }
  public struct Arguments: Codable, Sendable {
    public var application: String?
    public var project: String?
    public var path: String?
    public var origin: String?
    public var commandID: String?
    public var text: String?
    public var target: String?
    public var revision: String?
    public var provider: String?
    public var criteria: String?
    public init(application:String?=nil,project:String?=nil,path:String?=nil,origin:String?=nil,commandID:String?=nil,text:String?=nil,target:String?=nil,revision:String?=nil,provider:String?=nil,criteria:String?=nil) {
      self.application=application;self.project=project;self.path=path;self.origin=origin;self.commandID=commandID;self.text=text;self.target=target;self.revision=revision;self.provider=provider;self.criteria=criteria
    }
  }
  public static func decode(_ data: Data) throws -> Self {
    let step = try JSONDecoder().decode(Self.self, from: data)
    guard step.kind != .act || step.action != nil else { throw CocoaError(.coderReadCorrupt) }
    guard step.kind == .act || !step.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CocoaError(.coderReadCorrupt) }
    return step
  }
  public var proposal: JarvisActionProposal? {
    guard kind == .act, let action else { return nil }
    return .init(kind: action, application: arguments.application, project: arguments.project, path: arguments.path, origin: arguments.origin, commandID: arguments.commandID)
  }
  public static var schema: [String: Any] {
    let fields = ["application", "project", "path", "origin", "commandID", "text", "target", "revision", "provider", "criteria"]
    let arguments = Dictionary(uniqueKeysWithValues: fields.map { ($0, ["type": ["string", "null"]] as [String: Any]) })
    return ["type": "object", "additionalProperties": false, "required": ["kind", "reply", "action", "arguments"], "properties": [
      "kind": ["type": "string", "enum": ["respond", "act", "clarify"]], "reply": ["type": "string"],
      "action": ["anyOf": [["type": "null"], ["type": "string", "enum": ["observe", "openApplication", "click", "typeText", "scroll", "navigate", "readFile", "writeFile", "projectCommand", "agentPrompt", "stopWork", "deleteFile", "sendMessage", "purchase"]]]],
      "arguments": ["type": "object", "additionalProperties": false, "properties": arguments, "required": fields]]]
  }
  public func normalized(grants:JarvisGrants) -> Self {
    var step=self
    if let application=step.arguments.application {
      let names=["cursor":"com.todesktop.230313mzl4w4u92","chrome":"com.google.Chrome","google chrome":"com.google.Chrome","finder":"com.apple.finder","terminal":"com.apple.Terminal"]
      step.arguments.application=names[application.lowercased()] ?? application
    }
    if let path=step.arguments.path,path.hasPrefix("/") {
      let target=URL(fileURLWithPath:path).resolvingSymlinksInPath().path
      if let project=grants.projects.sorted(by:{$0.count>$1.count}).first(where:{let root=URL(fileURLWithPath:$0).resolvingSymlinksInPath().path;return target==root || target.hasPrefix(root+"/")}) {
        step.arguments.project=project
      }
    }
    switch step.action {
    case .observe:step.arguments.project=nil;step.arguments.path=nil;step.arguments.commandID=nil
    case .openApplication:step.arguments.project=nil;step.arguments.path=nil;step.arguments.origin=nil;step.arguments.commandID=nil
    case .readFile,.writeFile,.deleteFile:step.arguments.application=nil;step.arguments.origin=nil;step.arguments.commandID=nil
    default:break
    }
    return step
  }
}

public struct JarvisReceipt: Codable, Identifiable, Sendable {
  public var id = UUID()
  public var date = Date()
  public var actionEventID: UUID? = nil
  public var action: JarvisActionKind
  public var succeeded: Bool
  public var verified: Bool
  public var detail: String
  public init(action: JarvisActionKind, succeeded: Bool, verified: Bool, detail: String, actionEventID: UUID? = nil) {
    self.action = action; self.succeeded = succeeded; self.verified = verified; self.detail = detail; self.actionEventID = actionEventID
  }
}
