import Combine
import DeckCore
import Foundation

@MainActor final class AlfredSkillStore: ObservableObject {
  @Published private(set) var library: AlfredSkillLibrary
  @Published private(set) var error = ""
  private let file: URL
  private var storageReadable = true
  var skills: [AlfredSkill] { library.skills }
  init(file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Deck/alfred-skills.json")) {
    self.file = file
    library = .defaults
    guard FileManager.default.fileExists(atPath: file.path) else { return }
    do { library = try AlfredSkillLibrary.decode(Data(contentsOf: file)) }
    catch { storageReadable = false; self.error = "Could not read saved skills. Existing file preserved. " + error.localizedDescription }
  }
  func match(_ text: String) -> AlfredSkill? { library.match(text) }
  @discardableResult func save(_ skill: AlfredSkill) -> Bool {
    do {
      var updated = library; try updated.upsert(skill)
      try persist(updated); library = updated; error = ""; return true
    } catch { self.error = error.localizedDescription; return false }
  }
  func remove(_ skill: AlfredSkill) {
    do {
      var updated = library; updated.remove(id: skill.id)
      try persist(updated); library = updated; error = ""
    } catch { self.error = error.localizedDescription }
  }
  private func persist(_ value: AlfredSkillLibrary) throws {
    guard storageReadable else { throw NSError(domain: "AlfredSkills", code: 1, userInfo: [NSLocalizedDescriptionKey: "Saved skills could not be read. Existing file will not be overwritten."]) }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(value).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}
