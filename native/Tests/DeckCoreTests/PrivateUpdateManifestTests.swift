import CryptoKit
import Foundation
import XCTest
@testable import DeckCore

final class PrivateUpdateManifestTests: XCTestCase {
  private let key = Curve25519.Signing.PrivateKey()
  private let archive = Data("archive fixture".utf8)

  func testSignedFeedAndArchiveRoundTrip() throws {
    let manifest = try verify(signed(xml()))
    XCTAssertEqual(manifest.build, "10")
    XCTAssertEqual(manifest.version, "0.3.6")
    XCTAssertEqual(manifest.archiveLength, archive.count)
    XCTAssertEqual(manifest.downloadURL.lastPathComponent, "AgentDeck.zip")
    try manifest.verify(archive: archive, publicKey: key.publicKey.rawRepresentation)
  }
  func testTamperedFeedAndMissingSignatureFail() throws {
    let feed = try signed(xml())
    var tampered = feed; tampered[10] ^= 1
    XCTAssertThrowsError(try verify(tampered))
    XCTAssertThrowsError(try verify(Data(xml().utf8)))
    XCTAssertThrowsError(try PrivateUpdateManifest.verify(feed: feed, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, repository: "owner/repo", tag: "v0.3.6"))
    XCTAssertThrowsError(try verify(feed + Data("trailing injection".utf8)))
  }
  func testTamperedArchiveAndWrongLengthFail() throws {
    let manifest = try verify(signed(xml()))
    var changed = archive; changed[0] ^= 1
    XCTAssertThrowsError(try manifest.verify(archive: changed, publicKey: key.publicKey.rawRepresentation))
    XCTAssertThrowsError(try manifest.verify(archive: archive + Data([0]), publicKey: key.publicKey.rawRepresentation))
  }
  func testSignedButUntrustedArchiveLocationsFail() throws {
    for url in ["http://github.com/owner/repo/releases/download/v0.3.6/AgentDeck.zip",
      "https://evil.example/owner/repo/releases/download/v0.3.6/AgentDeck.zip",
      "https://github.com/owner/other/releases/download/v0.3.6/AgentDeck.zip",
      "https://github.com/owner/repo/releases/download/other/AgentDeck.zip",
      "https://github.com/owner/repo/releases/download/v0.3.6/../AgentDeck.zip",
      "https://github.com/owner/repo/releases/download/v0.3.6/%2e%2e.zip",
      "https://user@github.com/owner/repo/releases/download/v0.3.6/AgentDeck.zip",
      "https://github.com/owner/repo/releases/download/v0.3.6/AgentDeck.zip?token=x"] {
      XCTAssertThrowsError(try verify(signed(xml(url: url))), url)
    }
  }
  func testMalformedBuildLengthAndExtraItemsFail() throws {
    for build in ["", "0", "-1", "1.2", "9999999999999999999999999", "10<script>"] {
      XCTAssertThrowsError(try verify(signed(xml(build: build))))
    }
    XCTAssertThrowsError(try verify(signed(xml().replacingOccurrences(of: "length=\"\(archive.count)\"", with: "length=\"0\""))))
    XCTAssertThrowsError(try verify(signed(xml().replacingOccurrences(of: "</channel>", with: "<item></item></channel>"))))
    XCTAssertThrowsError(try verify(signed(xml().replacingOccurrences(of: "</item>", with: "<sparkle:releaseNotesLink>https://evil.example</sparkle:releaseNotesLink></item>"))))
    XCTAssertThrowsError(try verify(signed("<!DOCTYPE rss [<!ENTITY x SYSTEM 'file:///etc/passwd'>]>" + xml())))
  }
  func testRealExistingReleaseSignaturesWhenFixturePresent() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent("dist/release-20261106-build9/release")
    let feedURL = directory.appendingPathComponent("appcast.xml")
    guard FileManager.default.fileExists(atPath: feedURL.path) else { throw XCTSkip("Local signed build9 fixture not present") }
    let publicKey = try XCTUnwrap(Data(base64Encoded: "36e+YL+QV0SmoAHLtJqnqk564nD8+DxmOghuIzOTC74="))
    let manifest = try PrivateUpdateManifest.verify(feed: Data(contentsOf: feedURL), publicKey: publicKey,
      repository: "TheSamyar/ai-agent-deck", tag: "v0.3.5")
    XCTAssertEqual(manifest.build, "9")
    try manifest.verify(archive: Data(contentsOf: directory.appendingPathComponent(manifest.downloadURL.lastPathComponent)), publicKey: publicKey)
  }
  private func verify(_ feed: Data) throws -> PrivateUpdateManifest {
    try .verify(feed: feed, publicKey: key.publicKey.rawRepresentation, repository: "owner/repo", tag: "v0.3.6")
  }
  private func signed(_ xml: String) throws -> Data {
    let body = Data(xml.utf8)
    let signature = try key.signature(for: body).base64EncodedString()
    return body + Data("<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: \(body.count)\n-->\n".utf8)
  }
  private func xml(url: String = "https://github.com/owner/repo/releases/download/v0.3.6/AgentDeck.zip", build: String = "10") -> String {
    """
    <?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>Updates</title><item><title>Update</title><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion><enclosure url="\(url)" sparkle:version="\(build)" sparkle:shortVersionString="0.3.6" sparkle:edSignature="\((try! key.signature(for: archive)).base64EncodedString())" length="\(archive.count)" type="application/octet-stream"></enclosure></item></channel></rss>
    """
  }
}
