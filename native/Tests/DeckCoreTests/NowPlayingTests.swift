import XCTest
import AppKit
@testable import DeckCore
final class NowPlayingTests: XCTestCase {
  func testArtworkAllowsOnlySecureSpotifyImageHosts() {
    for value in ["https://i.scdn.co/image/example", "https://image.spotifycdn.com/art"] {
      XCTAssertTrue(NowPlaying.allowedArtworkURL(URL(string: value)!))
    }
    for value in ["http://i.scdn.co/image", "https://evil.example/image", "https://i.scdn.co.evil.example/image",
      "https://scdn.co/image", "https://user:password@i.scdn.co/image", "https://i.scdn.co:8443/image", "file:///tmp/art.png"] {
      XCTAssertFalse(NowPlaying.allowedArtworkURL(URL(string: value)!))
    }
  }
  @MainActor func testMediaWithoutArtworkStillRendersAtHardwareSize() throws {
    var state = NowPlaying(); state.title = String(repeating: "A long track ", count: 20)
    state.artist = "Artist"; state.playing = true
    let data = try XCTUnwrap(MasterHUBArtwork.jpeg(media: state))
    let image = try XCTUnwrap(NSBitmapImageRep(data: data))
    XCTAssertEqual(image.pixelsWide, 240); XCTAssertEqual(image.pixelsHigh, 240)
  }
}
