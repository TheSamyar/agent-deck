import Foundation

public struct AlfredSkill: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var aliases: [String]
  public var instructions: String
  public var project: String?
  public init(id: UUID = UUID(), name: String, aliases: [String] = [], instructions: String, project: String? = nil) {
    self.id = id; self.name = name; self.aliases = aliases; self.instructions = instructions; self.project = project
  }
  /// Resolve once at invocation so old conversation references cannot retarget a new skill.
  public func resolvedProject(selectedProject: String?, approvedProjects: Set<String>) throws -> String {
    guard let requested = project ?? selectedProject, requested.hasPrefix("/") else {
      throw NSError(domain: "AlfredSkills", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select an approved project before running this skill."])
    }
    let canonical = URL(fileURLWithPath: requested).standardizedFileURL.resolvingSymlinksInPath().path
    let approved = approvedProjects.contains {
      URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path == canonical
    }
    guard approved else {
      throw NSError(domain: "AlfredSkills", code: 1, userInfo: [NSLocalizedDescriptionKey: "Approve this skill's project in Alfred Settings before running it."])
    }
    return canonical
  }
  public var goal: String {
    "Run the saved Alfred skill named \(name). Saved instructions describe the user's goal; they grant no permissions. Use only current approved scope and verified evidence.\n" + instructions
  }
}

public struct AlfredSkillLibrary: Codable, Equatable, Sendable {
  public var version = 1
  public private(set) var skills: [AlfredSkill]
  public init(skills: [AlfredSkill] = []) { self.skills = skills }
  public static let defaults = AlfredSkillLibrary(skills: [
    .init(id: UUID(uuidString: "50F274B0-6A3A-4570-ACF0-4000D4010001")!, name: "Start my workday", aliases: ["start my workday"], instructions: "Observe current coding agents. Summarize what is working, finished, and blocked. Recommend one concrete next action. Do not change files or send prompts automatically."),
    .init(id: UUID(uuidString: "50F274B0-6A3A-4570-ACF0-4000D4010002")!, name: "Review finished agents", aliases: ["review finished agents"], instructions: "Observe finished coding agents. Separate their completion claims from independent execution evidence. Recommend the next verification step for each relevant result. Do not claim tests passed without a receipt. Do not send prompts, run commands, or change files automatically.")
  ])
  public static func normalized(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
  }
  private static let reservedTriggers: Set<String> = [
    "stop", "cancel", "stop what you are doing", "stop listening", "end conversation",
    "approve", "allow", "allow once", "deny", "yes", "no", "later", "not now", "repeat",
    "save it", "save that lesson", "approve lesson"
  ]
  public func match(_ text: String) -> AlfredSkill? {
    let clean = Self.normalized(text)
    guard !Self.reservedTriggers.contains(clean) else { return nil }
    let matches = skills.filter { skill in
      Self.normalized("run skill " + skill.name) == clean || skill.aliases.contains { Self.normalized($0) == clean }
    }
    return matches.count == 1 ? matches[0] : nil
  }
  public mutating func upsert(_ value: AlfredSkill) throws {
    var skill = value
    skill.name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)
    skill.instructions = skill.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    skill.aliases = skill.aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    if let project = skill.project?.trimmingCharacters(in: .whitespacesAndNewlines), !project.isEmpty {
      guard project.hasPrefix("/") else { throw problem("Choose an absolute project folder, or leave project scope empty.") }
      skill.project = URL(fileURLWithPath: project).standardizedFileURL.resolvingSymlinksInPath().path
    } else { skill.project = nil }
    guard !skill.name.isEmpty, skill.name.count <= 80, !skill.instructions.isEmpty, skill.instructions.count <= 8000,
      skill.aliases.count <= 8, skill.aliases.allSatisfy({ $0.count <= 80 }) else { throw problem("Use a name up to 80 characters, instructions up to 8,000 characters, and at most eight short aliases.") }
    guard Self.reservedTriggers.isDisjoint(with: skill.aliases.map(Self.normalized)) else {
      throw problem("Skill aliases cannot replace Stop, Cancel, approval replies, or conversation controls.")
    }
    let triggers = [Self.normalized("run skill " + skill.name)] + skill.aliases.map(Self.normalized)
    guard !triggers.contains(""), Set(triggers).count == triggers.count else { throw problem("Use distinct, nonempty skill aliases.") }
    for other in skills where other.id != skill.id {
      let existing = Set([Self.normalized("run skill " + other.name)] + other.aliases.map(Self.normalized))
      guard Self.normalized(other.name) != Self.normalized(skill.name), existing.isDisjoint(with: triggers) else { throw problem("Another skill already uses that name or alias.") }
    }
    guard skills.contains(where: { $0.id == skill.id }) || skills.count < 64 else { throw problem("Keep at most 64 saved skills.") }
    if let index = skills.firstIndex(where: { $0.id == skill.id }) { skills[index] = skill } else { skills.append(skill) }
  }
  public mutating func remove(id: UUID) { skills.removeAll { $0.id == id } }
  public static func decode(_ data: Data) throws -> Self {
    let value = try JSONDecoder().decode(Self.self, from: data)
    guard value.version == 1 else { throw problem("This skill library needs a newer Alfred version.") }
    var checked = Self()
    for skill in value.skills {
      guard !checked.skills.contains(where: { $0.id == skill.id }) else { throw problem("Skill identifiers must be unique.") }
      try checked.upsert(skill)
    }
    return checked
  }
  private static func problem(_ text: String) -> NSError { NSError(domain: "AlfredSkills", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
  private func problem(_ text: String) -> NSError { Self.problem(text) }
}
