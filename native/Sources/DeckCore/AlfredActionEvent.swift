import Foundation

/// UI-only execution metadata. Never stores typed text, screenshots, or observation bodies.
public struct AlfredActionEvent: Identifiable, Equatable, Sendable {
  public enum State: String, Sendable {
    case running = "Running", waiting = "Needs approval", attempted = "Attempted"
    case verified = "Verified", failed = "Failed", blocked = "Blocked", cancelled = "Cancelled"
  }
  public let id: UUID
  public let turnID: UUID
  public let action: JarvisActionKind
  public let target: String
  public let observationRevision: String?
  public let targetID: String?
  public let commandID: String?
  public let purpose: String
  public let startedAt: Date
  public var finishedAt: Date?
  public var state: State
  public init(id: UUID = UUID(), turnID: UUID, step: JarvisStep, state: State = .running, now: Date = Date()) {
    self.id = id; self.turnID = turnID; self.action = step.action ?? .observe
    self.observationRevision = step.arguments.revision.flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
    let safeTarget = step.arguments.target.flatMap { value in
      value.range(of: #"^(?:element-)?[0-9]{1,6}$"#, options: .regularExpression) == nil ? nil : value
    }
    self.targetID = safeTarget
    self.commandID = step.arguments.commandID
    self.target = Self.target(for: step, targetID: safeTarget); self.purpose = Self.purpose(for: step.action ?? .observe)
    self.startedAt = now; self.state = state
    self.finishedAt = [.running, .waiting].contains(state) ? nil : now
  }
  public mutating func finish(succeeded: Bool, verified: Bool, now: Date = Date()) {
    guard state == .running else { return }
    state = !succeeded ? .failed : verified ? .verified : .attempted
    finishedAt = now
  }
  public mutating func cancel(now: Date = Date()) {
    guard state == .running || state == .waiting else { return }
    state = .cancelled; finishedAt = now
  }
  private static func target(for step: JarvisStep, targetID: String?) -> String {
    let value: String
    if let path = step.arguments.path { value = URL(fileURLWithPath: path).lastPathComponent }
    else if let origin = step.arguments.origin, let host = URL(string: origin)?.host { value = host }
    else if let app = step.arguments.application { value = app + (targetID.map { " · " + $0 } ?? "") }
    else if let project = step.arguments.project { value = URL(fileURLWithPath: project).lastPathComponent + (step.arguments.commandID.map { " · " + URL(fileURLWithPath: $0).lastPathComponent } ?? "") }
    else { value = "Approved workspace" }
    return String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(120))
  }
  private static func purpose(for kind: JarvisActionKind) -> String {
    switch kind {
    case .observe: "Inspect current state"
    case .openApplication: "Open the requested app"
    case .click: "Press the observed control"
    case .typeText: "Enter requested text"
    case .scroll: "Find the requested content"
    case .navigate: "Open the approved website"
    case .readFile: "Inspect the project file"
    case .writeFile: "Apply the requested file change"
    case .projectCommand: "Run the approved command"
    case .agentPrompt: "Dispatch the requested agent work"
    case .stopWork: "Stop the current work"
    case .deleteFile: "Move the confirmed item to Trash"
    case .sendMessage: "Prepare the requested message"
    case .purchase: "Review the requested purchase"
    }
  }
}
