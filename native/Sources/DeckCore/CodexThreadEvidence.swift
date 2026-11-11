import CSQLite
import Foundation

/// Reads only lifecycle/provenance columns, never prompts, titles, or transcripts.
public enum CodexThreadEvidence {
  public enum Kind: Equatable, Sendable { case root, child, archived, unknown }
  public static func classify(source: String, archived: Bool) -> Kind {
    if archived { return .archived }
    if let data = source.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["subagent"] != nil { return .child }
    return ["cli", "exec", "vscode"].contains(source) ? .root : .unknown
  }
  public static func lookup(_ threadID: String, directory: URL? = nil) -> Kind {
    guard !threadID.isEmpty, threadID.count <= 200 else { return .unknown }
    let home = directory ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
    let candidates = ((try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
      .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
    for file in candidates.prefix(2) {
      var db: OpaquePointer?
      guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
        if let db { sqlite3_close(db) }; continue
      }
      defer { sqlite3_close(db) }
      sqlite3_busy_timeout(db, 50)
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, "SELECT source, archived FROM threads WHERE id = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK, let statement else { continue }
      defer { sqlite3_finalize(statement) }
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      sqlite3_bind_text(statement, 1, threadID, -1, transient)
      if sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
        return classify(source: String(cString: text), archived: sqlite3_column_int(statement, 1) != 0)
      }
    }
    return .unknown
  }
}
