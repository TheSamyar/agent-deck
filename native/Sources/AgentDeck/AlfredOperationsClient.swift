import Combine
import DeckCore
import Foundation
import Security

private enum AlfredOperationsCredential {
  private static func query(_ origin: String) -> [String: Any] {
    [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"com.aiagentdeck.alfred.operations", kSecAttrAccount as String:origin]
  }
  static func read(_ origin: String) -> String? {
    var q = query(origin); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let bytes = value as? Data else { return nil }
    return String(data: bytes, encoding: .utf8)
  }
  static func save(_ token: String, origin: String) throws {
    let q = query(origin), bytes = Data(token.utf8)
    let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String:bytes] as CFDictionary)
    if status == errSecItemNotFound {
      var new = q; new[kSecValueData as String] = bytes; new[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      guard SecItemAdd(new as CFDictionary, nil) == errSecSuccess else { throw failure() }
    } else if status != errSecSuccess { throw failure() }
  }
  static func remove(_ origin: String) { SecItemDelete(query(origin) as CFDictionary) }
  private static func failure() -> NSError { NSError(domain:"AlfredOperations",code:1,userInfo:[NSLocalizedDescriptionKey:"Could not save the native connection in macOS Keychain."]) }
}

/// An independent Alfred server connection. Native credentials have read-only device scope.
@MainActor final class AlfredOperationsClient: NSObject, ObservableObject, URLSessionTaskDelegate {
  @Published private(set) var cases: [AlfredOperationsCase] = []
  @Published private(set) var status = "Not connected · server monitoring status unknown"
  @Published private(set) var loading = false
  @Published private(set) var lastRefreshed: Date?
  @Published private(set) var snapshotOrigin: URL?
  @Published var serverOrigin = UserDefaults.standard.string(forKey:"alfred.operations.serverOrigin") ?? ""
  @Published var deviceCredential = ""
  private var generation = UUID()
  private var requestTask: Task<Data, Error>?
  private lazy var session = URLSession(configuration:.ephemeral,delegate:self,delegateQueue:nil)
  nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
  var serverURL: URL? { try? AlfredOperationsEndpoint.origin(serverOrigin) }
  func connect() async {
    guard !loading else { return }
    do {
      let origin = try AlfredOperationsEndpoint.origin(serverOrigin).absoluteString
      let token = deviceCredential.trimmingCharacters(in:.whitespacesAndNewlines)
      guard token.hasPrefix("ald_"), token.count >= 32, token.count <= 4096,
        token.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"._~-=")).contains($0) }) else {
        throw problem("Paste a read-only native device credential created in your Alfred server. Worker credentials cannot connect this app.")
      }
      try AlfredOperationsCredential.save(token, origin:origin)
      serverOrigin = origin; UserDefaults.standard.set(origin,forKey:"alfred.operations.serverOrigin"); deviceCredential = ""
      cases = []; lastRefreshed = nil; snapshotOrigin = nil
      await refresh()
    } catch { status = error.localizedDescription }
  }
  func disconnect() {
    cancelRefresh()
    if let origin = serverURL?.absoluteString { AlfredOperationsCredential.remove(origin) }
    deviceCredential = ""; cases = []; lastRefreshed = nil; snapshotOrigin = nil
    status = "Disconnected locally · revoke the device in Alfred server to invalidate its credential"
  }
  func refresh() async {
    guard !loading else { return }
    let id = UUID(); generation = id; loading = true; status = "Reading Alfred Operations…"
    defer { if generation == id { loading = false; requestTask = nil } }
    do {
      let origin = try AlfredOperationsEndpoint.origin(serverOrigin)
      guard let token = AlfredOperationsCredential.read(origin.absoluteString) else { throw problem("Connect a native device credential first. Hub is an optional source, not this server's login.") }
      var request = URLRequest(url:origin.appendingPathComponent("api/operations/cases")); request.timeoutInterval = 30
      request.setValue("Bearer " + token,forHTTPHeaderField:"Authorization"); request.setValue("application/json",forHTTPHeaderField:"Accept")
      let task = Task { () throws -> Data in
        let (data, response) = try await session.data(for:request)
        guard let http = response as? HTTPURLResponse else { throw problem("Alfred returned an invalid response.") }
        guard http.statusCode == 200 else { throw problem(http.statusCode == 401 || http.statusCode == 403 ? "Native connection was rejected. Check the server address and device enrollment; no other account was used." : "Alfred server is unavailable (HTTP \(http.statusCode)).") }
        guard data.count <= 4_000_000 else { throw problem("Alfred response exceeded the display limit.") }
        return data
      }
      requestTask = task
      let data = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
      guard generation == id, !Task.isCancelled else { return }
      cases = try AlfredOperationsCase.decodeList(data); lastRefreshed = Date(); snapshotOrigin = origin
      status = cases.isEmpty ? "Connected · no cases returned" : "Connected · \(cases.count) cases · server authoritative"
    } catch {
      guard generation == id else { return }
      status = "Unavailable · " + error.localizedDescription + (lastRefreshed == nil ? "" : " Showing the previous snapshot.")
    }
  }
  /// Local reads only. Remote jobs are managed by the independent server.
  func cancelRefresh() {
    generation = UUID(); requestTask?.cancel(); requestTask = nil; loading = false
    status = "Refresh stopped locally · server work was not paused"
  }
  private func problem(_ message: String) -> NSError { NSError(domain:"AlfredOperations",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
}
