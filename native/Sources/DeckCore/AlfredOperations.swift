import Foundation

public struct AlfredOperationSource: Codable, Equatable, Sendable {
  public let provider: String
  public let sourceId: String
  public let threadId: String?
  public let sourceUrl: String?
  public var url: URL? { Self.safeURL(sourceUrl) }
  public static func safeURL(_ text: String?) -> URL? {
    guard let text, let url = URL(string: text), url.scheme == "https", url.host != nil,
      url.user == nil, url.password == nil else { return nil }
    return url
  }
}
public struct AlfredOperationsCase: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let summary: String
  public let status: String
  public let revision: Int
  public let businessId: Int?
  public let linkedTaskId: Int?
  public let sourceRefs: [AlfredOperationSource]
  public let updatedAt: String
  public var displayStatus: String { status.replacingOccurrences(of: "_", with: " ").capitalized }
  public func caseURL(origin: URL) -> URL? {
    guard UUID(uuidString: id) != nil, let approved = try? AlfredOperationsEndpoint.origin(origin.absoluteString) else { return nil }
    var parts = URLComponents(url: approved.appendingPathComponent("operations"), resolvingAgainstBaseURL: false)!
    parts.queryItems = [URLQueryItem(name: "case", value: id)]
    return parts.url
  }
  public static func decodeList(_ data: Data) throws -> [Self] {
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    struct Envelope: Decodable { let cases: [AlfredOperationsCase] }
    let json = try JSONSerialization.jsonObject(with: data)
    var root = json
    for _ in 0..<4 {
      guard let object = root as? [String: Any] else { break }
      if object["success"] as? Bool == false || (object["status"] as? Int ?? 200) >= 400 {
        throw NSError(domain: "AlfredOperations", code: 1, userInfo: [NSLocalizedDescriptionKey: "Alfred server did not authorize or complete this queue read."])
      }
      if object["cases"] != nil { break }
      guard let nested = object["data"] else { break }
      root = nested
    }
    let normalized = try JSONSerialization.data(withJSONObject: root)
    return try decoder.decode(Envelope.self, from: normalized).cases
  }
}

public enum AlfredOperationsEndpoint {
  public static func origin(_ text: String) throws -> URL {
    guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
      parts.query == nil, parts.fragment == nil, ["", "/"].contains(parts.path),
      parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
      throw NSError(domain: "AlfredOperations", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter your Alfred server's HTTPS origin, or a loopback HTTP origin for development."])
    }
    parts.path = ""
    guard let url = parts.url else { throw URLError(.badURL) }
    return url
  }
}
