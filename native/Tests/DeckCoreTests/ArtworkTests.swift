import Foundation
import AppKit

#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
@testable import DeckCore

final class ArtworkTests: XCTestCase {
  func testUntrustedLabelsProduceValidInertXML() {
    let tile = TileSnapshot(key: "unsafe", label: "<script>&\u{0001}",
      sublabel: "\"provider\"\u{0002}", detail: "<image href='https://example.test'>")
    let artwork = TileArtwork.render(tile)
    XCTAssertTrue(XMLParser(data: Data(artwork.utf8)).parse())
    XCTAssertFalse(artwork.contains("<script>"))
    XCTAssertFalse(artwork.contains("<image"))
    XCTAssertFalse(artwork.contains("\u{0001}"))
    XCTAssertTrue(artwork.contains("&lt;"))
  }
  func testStatusesHaveSymbolsAndDoNotDependOnlyOnColor() {
    for (status, marker) in [("WORKING", "•"), ("WAITING", "!"), ("DONE", "✓"), ("DISCONNECTED", "×")] {
      let tile = TileSnapshot(key: status, label: "Project", detail: status, status: status)
      XCTAssertTrue(TileArtwork.render(tile).contains(">\(marker)</text>"), status)
    }
  }
  func testConfirmationAndLongCaptionsStayExplicit() {
    let tile = TileSnapshot(key: "confirm", label: "Allow", sublabel: String(repeating: "A", count: 80),
      detail: "Allow once", status: "WAITING", requiresHold: true)
    let artwork = TileArtwork.render(tile)
    XCTAssertTrue(artwork.contains("HOLD TO CONFIRM"))
    XCTAssertTrue(artwork.contains("…"))
    XCTAssertFalse(artwork.contains(String(repeating: "A", count: 20)))
  }
  func testWideCaptionsFitWithinTheTile() throws {
    let font = try XCTUnwrap(NSFont(name: "HelveticaNeue-Medium", size: 7.5))
    for text in [String(repeating: "W", count: 80), String(repeating: "漢", count: 80)] {
      let artwork = TileArtwork.render(.init(key: "wide", label: "Project", sublabel: text, detail: text))
      let expression = try NSRegularExpression(pattern: "<text[^>]*font-size=\"7.5\"[^>]*>([^<]*)</text>")
      let range = NSRange(artwork.startIndex..., in: artwork)
      let captions = expression.matches(in: artwork, range: range)
      XCTAssertEqual(captions.count, 2)
      for match in captions {
        let caption = (artwork as NSString).substring(with: match.range(at: 1))
        XCTAssertTrue(caption.hasSuffix("…"))
        XCTAssertLessThanOrEqual((caption as NSString).size(withAttributes: [.font: font]).width, 88)
      }
    }
  }
  func testNavigationKeysRetainDistinctSymbols() {
    for (action, marker) in [("previous", "←"), ("next", "→"), ("dashboard", "↗"), ("stop", "■")] {
      XCTAssertTrue(TileArtwork.render(.init(key: action, label: action, action: action)).contains(">\(marker)</text>"))
    }
  }
  func testXMLNoncharactersAreRemoved() {
    XCTAssertEqual(TileArtwork.escape("safe\u{FFFE}\u{FFFF}name"), "safename")
  }

}
