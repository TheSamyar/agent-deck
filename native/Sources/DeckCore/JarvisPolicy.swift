import Foundation

/// Authority is checked by the application, never granted by model output.
public enum JarvisActionKind: String, Codable, Sendable {
  case observe, openApplication, click, typeText, scroll, navigate, readFile, writeFile, projectCommand, agentPrompt, stopWork
  case deleteFile, sendMessage, purchase
}
public struct JarvisActionProposal: Codable, Sendable {
  public var id: UUID
  public var kind: JarvisActionKind
  public var application: String?
  public var project: String?
  public var path: String?
  public var origin: String?
  public var commandID: String?
  public init(kind: JarvisActionKind, application: String? = nil, project: String? = nil, path: String? = nil, origin: String? = nil, commandID: String? = nil) {
    id = UUID(); self.kind = kind; self.application = application; self.project = project
    self.path = path; self.origin = origin; self.commandID = commandID
  }
}
public struct JarvisGrants: Codable, Sendable {
  public var applications = Set<String>()
  public var projects = Set<String>()
  public var origins = Set<String>()
  public var commandIDs = Set<String>()
  public init() {}
}
public enum JarvisAuthorization: Equatable, Sendable {
  case allowed, confirmationRequired, denied(String)
}
public enum JarvisPolicy {
  private static func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }
  public static func authorize(_ proposal: JarvisActionProposal, grants: JarvisGrants) -> JarvisAuthorization {
    if [.readFile, .writeFile, .deleteFile].contains(proposal.kind), proposal.path == nil { return .denied("A file path is required.") }
    if let app = proposal.application, !grants.applications.contains(app) { return .denied("Application is not approved.") }
    if let origin = proposal.origin, !grants.origins.contains(origin) { return .denied("Website is not approved.") }
    if let project = proposal.project {
      guard project.hasPrefix("/"), grants.projects.contains(where: { canonical($0) == canonical(project) }) else { return .denied("Project is not approved.") }
      if let path = proposal.path {
        let root = canonical(project), target = canonical(path)
        guard path.hasPrefix("/"), target == root || target.hasPrefix(root + "/") else { return .denied("File is outside the approved project.") }
      }
    } else if [.readFile, .writeFile, .projectCommand, .agentPrompt, .deleteFile].contains(proposal.kind) {
      return .denied("An approved project is required.")
    }
    if [.openApplication, .click, .typeText, .scroll, .navigate].contains(proposal.kind), proposal.application == nil {
      return .denied("An approved target application is required.")
    }
    if proposal.kind == .navigate, proposal.origin == nil { return .denied("An approved website is required.") }
    if proposal.kind == .projectCommand {
      guard let command = proposal.commandID, grants.commandIDs.contains(command) else { return .denied("Project command is not approved.") }
    }
    if [.deleteFile, .sendMessage, .purchase].contains(proposal.kind) { return .confirmationRequired }
    return .allowed
  }
}
