import CSQLite
import Foundation

public final class DeckDatabase {
  private var handle: OpaquePointer?
  public init(path: String) throws {
    if path != ":memory:" {
      try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: path).deletingLastPathComponent(),
        withIntermediateDirectories: true)
    }
    guard sqlite3_open(path, &handle) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
    sqlite3_busy_timeout(handle, 1500)
    try execute(
      "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS documents (key TEXT PRIMARY KEY, payload BLOB NOT NULL);"
    )
    if path != ":memory:" {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
  }
  deinit { sqlite3_close(handle) }
  private func execute(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw NSError(
        domain: "DeckDatabase", code: 1,
        userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
    }
  }
  public func save<T: Encodable>(_ value: T, key: String) throws {
    let data = try JSONEncoder().encode(value)
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        handle,
        "INSERT INTO documents(key,payload) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload",
        -1, &statement, nil) == SQLITE_OK
    else { throw CocoaError(.fileWriteUnknown) }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, key, -1, transient)
    _ = data.withUnsafeBytes {
      sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient)
    }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
  }
  public func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(handle, "SELECT payload FROM documents WHERE key=?", -1, &statement, nil)
        == SQLITE_OK
    else { return nil }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0)
    else { return nil }
    return try? JSONDecoder().decode(
      type, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
  }
}
