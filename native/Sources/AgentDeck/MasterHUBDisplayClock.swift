import AppKit
import SwiftUI
import DeckCore

@MainActor final class MasterHUBKeyClock: ObservableObject { @Published var phase: Double = 0 }

@MainActor final class MasterHUBDisplayClock: ObservableObject {
  let keys = MasterHUBKeyClock()
  @Published var robinState: String?
  @Published var celebration: String?
  @Published var phase: Double = 0
}
@MainActor enum MasterHUBPreviewImage {
  private static let images: NSCache<NSData, NSImage> = { let value = NSCache<NSData, NSImage>(); value.countLimit = 256; return value }()
  static func image(_ data: Data) -> NSImage? {
    let key = data as NSData
    if let image = images.object(forKey: key) { return image }
    guard let image = NSImage(data: data) else { return nil }
    images.setObject(image, forKey: key); return image
  }
}
struct MasterHUBDialFace: View {
  let snapshot: DeckSnapshot?
  let media: NowPlaying
  var handoffsMode: Bool = false
  let mediaMode: Bool
  @ObservedObject var clock: MasterHUBDisplayClock
  var body: some View {
    let data = mediaMode ? MasterHUBArtwork.jpeg(media: media) : MasterHUBArtwork.jpeg(dial: .init(snapshot: snapshot, handoffs: handoffsMode), phase: clock.phase, celebration: clock.celebration, robinState: clock.robinState)
    if let data, let image = MasterHUBPreviewImage.image(data) {
      Image(nsImage: image).resizable().scaledToFit().clipShape(Circle())
    }
  }
}
