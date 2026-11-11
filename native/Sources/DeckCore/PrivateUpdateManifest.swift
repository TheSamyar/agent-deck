import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct PrivateUpdateManifest: Sendable {
  public let build: String
  public let version: String
  public let downloadURL: URL
  public let archiveLength: Int
  public let archiveSignature: Data

  public enum Failure: String, Error, LocalizedError {
    case invalidFeed = "The update feed is malformed or unsupported."
    case invalidSignature = "The update signature could not be verified."
    case untrustedURL = "The update archive is outside the selected repository and release."
    case invalidArchive = "The update archive length does not match the signed feed."
    public var errorDescription: String? { rawValue }
  }

  public static func verify(feed: Data, publicKey: Data, repository: String, tag: String) throws -> Self {
    guard feed.count <= 4 * 1024 * 1024,
      let prefix = feed.range(of: Data("<!-- sparkle-signatures:\n".utf8), options: .backwards),
      let block = String(data: feed[prefix.upperBound...], encoding: .utf8),
      block.hasSuffix("-->\n") || block.hasSuffix("-->") else { throw Failure.invalidFeed }
    let body = Data(feed[..<prefix.lowerBound])
    let lines = block.components(separatedBy: .newlines).filter { !$0.isEmpty }
    guard lines.count == 3, lines[0].hasPrefix("edSignature: "), lines[1].hasPrefix("length: "), lines[2] == "-->",
      let signature = Data(base64Encoded: String(lines[0].dropFirst("edSignature: ".count))), signature.count == 64,
      let length = Int(lines[1].dropFirst("length: ".count)), length == body.count else { throw Failure.invalidFeed }
    try verifySignature(signature, data: body, publicKey: publicKey)
    guard let text = String(data: body, encoding: .utf8), !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
      !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw Failure.invalidFeed }
    let reader = ManifestReader()
    let parser = XMLParser(data: body); parser.shouldResolveExternalEntities = false; parser.delegate = reader
    guard parser.parse(), !reader.invalid, reader.items == 1, reader.enclosures.count == 1,
      let enclosure = reader.enclosures.first,
      let build = enclosure["sparkle:version"], validNumber(build),
      let version = enclosure["sparkle:shortVersionString"], version.range(of: #"^[0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil,
      let lengthText = enclosure["length"], let archiveLength = Int(lengthText), archiveLength > 0, archiveLength <= 250 * 1024 * 1024,
      let encoded = enclosure["sparkle:edSignature"], let archiveSignature = Data(base64Encoded: encoded), archiveSignature.count == 64,
      let urlText = enclosure["url"], let url = URL(string: urlText) else { throw Failure.invalidFeed }
    let repoParts = repository.split(separator: "/", omittingEmptySubsequences: false)
    guard repoParts.count == 2, repoParts.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil && $0 != "." && $0 != ".." }),
      !tag.isEmpty, tag.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme == "https", components.host == "github.com",
      components.user == nil, components.password == nil, components.port == nil, components.query == nil, components.fragment == nil else { throw Failure.untrustedURL }
    let expectedPrefix = "/\(repository)/releases/download/\(tag)/"
    let path = components.percentEncodedPath
    guard path.hasPrefix(expectedPrefix), !path.contains("%"),
      String(path.dropFirst(expectedPrefix.count)).range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$"#, options: .regularExpression) != nil else { throw Failure.untrustedURL }
    return .init(build: build, version: version, downloadURL: url, archiveLength: archiveLength, archiveSignature: archiveSignature)
  }

  public func verify(archive: Data, publicKey: Data) throws {
    guard archive.count == archiveLength else { throw Failure.invalidArchive }
    try Self.verifySignature(archiveSignature, data: archive, publicKey: publicKey)
  }
  private static func validNumber(_ value: String) -> Bool {
    value.range(of: #"^[1-9][0-9]{0,17}$"#, options: .regularExpression) != nil && Int(value) != nil
  }
  private static func verifySignature(_ signature: Data, data: Data, publicKey: Data) throws {
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey), key.isValidSignature(signature, for: data) else { throw Failure.invalidSignature }
  }
}

private final class ManifestReader: NSObject, XMLParserDelegate {
  var invalid = false
  var items = 0
  var enclosures: [[String: String]] = []
  private var path: [String] = []
  func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
    path.append(name)
    let location = path.joined(separator: "/")
    let allowed = ["rss", "rss/channel", "rss/channel/title", "rss/channel/link", "rss/channel/item", "rss/channel/item/title", "rss/channel/item/sparkle:minimumSystemVersion", "rss/channel/item/enclosure"]
    if !allowed.contains(location) { invalid = true }
    if name == "rss", attributes["xmlns:sparkle"] != "http://www.andymatuschak.org/xml-namespaces/sparkle" { invalid = true }
    if location == "rss/channel/item" { items += 1 }
    if location == "rss/channel/item/enclosure" { enclosures.append(attributes) }
  }
  func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if !path.isEmpty { path.removeLast() } }
  func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { invalid = true; return nil }
}
