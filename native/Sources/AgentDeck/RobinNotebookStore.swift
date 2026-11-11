import Foundation
import DeckCore
import SwiftUI

@MainActor final class RobinNotebookStore: ObservableObject {
  @Published private(set) var notebook = RobinNotebook()
  @Published private(set) var error = ""
  private let url: URL
  private var readable = true
  init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Deck")) {
    url = directory.appendingPathComponent("robin-notebook.json")
    if FileManager.default.fileExists(atPath: url.path) {
      do { notebook = try JSONDecoder().decode(RobinNotebook.self, from: Data(contentsOf: url)) }
      catch { readable = false; self.error = "Notebook could not be read. Existing data was preserved." }
    }
  }
  func record(project: String, kind: RobinNoteKind, text: String, approved: Bool = false, sourcePath: String? = nil, verified: Bool = false) {
    guard readable else { return }
    notebook.record(.init(project: project, kind: kind, text: text, approved: approved, sourcePath: sourcePath, verified: verified)); save()
  }
  func approve(_ id: UUID) { guard let i = notebook.notes.firstIndex(where: { $0.id == id }) else { return }; notebook.notes[i].approved = true; notebook.notes[i].updatedAt = Date(); save() }
  func correct(_ id: UUID, text: String) { guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let i = notebook.notes.firstIndex(where: { $0.id == id }) else { return }; notebook.notes[i].text = String(text.prefix(4000)); notebook.notes[i].approved = true; notebook.notes[i].verified = false; if notebook.notes[i].kind == .verifiedResult { notebook.notes[i].kind = .decision }; notebook.notes[i].updatedAt = Date(); save() }
  func forget(_ id: UUID) { notebook.notes.removeAll { $0.id == id }; save() }
  func context(project: String, query: String, cloud: Bool, limit: Int = 6000) -> String {
    notebook.relevant(project: project, query: query, limit: limit) { !cloud || Self.cloudEligible($0) }
  }
  private func save() {
    guard readable else { return }
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(notebook).write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch { self.error = "Notebook could not be saved." }
  }
  static func safeCloudFile(project: String, path: String, text: String) -> String? {
    guard text.count <= 16000, RobinReasoningPolicy.permitsCloud(text: text),
      cloudEligible(.init(project: project, kind: .observation, text: "Source access check", sourcePath: path)) else { return nil }
    return text
  }
  private static func cloudEligible(_ note: RobinNote) -> Bool {
    let value = note.text.lowercased()
    if ["api_key", "api key:", "password:", "password=", "authorization:", "bearer ", "private key", "sk-", "ghp_", "gsk_"].contains(where: value.contains) { return false }
    guard let path = note.sourcePath else { return true }
    let root = URL(fileURLWithPath: note.project).resolvingSymlinksInPath().path
    let source = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    guard source.hasPrefix(root + "/") else { return false }
    let relative = String(source.dropFirst(root.count + 1))
    if relative.split(separator: "/").contains(where: { $0 == ".git" || $0.hasPrefix(".env") || $0.lowercased().contains("secret") || $0.hasSuffix(".pem") || $0.hasSuffix(".key") }) { return false }
    // Git owns ignore semantics, including nested rules and negation. Fail closed on errors.
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root, "check-ignore", "--no-index", "-q", "--", relative]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 1 } catch { return false }
  }
}
