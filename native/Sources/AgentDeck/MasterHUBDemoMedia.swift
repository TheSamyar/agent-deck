import AppKit
import DeckCore

@MainActor enum MasterHUBDemoMedia {
  static let state: NowPlaying = {
    var media = NowPlaying()
    media.title = "Night Shift"; media.artist = "Agent Deck · demo track"
    media.trackID = "synthetic-demo-track"; media.playing = true; media.shuffle = true
    if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 240,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: rep) {
      NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
      NSGradient(starting: .systemPurple, ending: .systemPink)?.draw(in: NSRect(x: 0, y: 0, width: 240, height: 240), angle: 45)
      for index in 0..<12 {
        let height = CGFloat(30 + (index * 37) % 130)
        NSColor.white.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: 20 + CGFloat(index) * 17, y: 120-height/2, width: 8, height: height), xRadius: 4, yRadius: 4).fill()
      }
      NSGraphicsContext.restoreGraphicsState()
      media.artwork = rep.representation(using: .png, properties: [:])
    }
    return media
  }()
}
