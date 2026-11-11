import AppKit
import SwiftUI
import DeckCore

/// Uses the same sliced provider sculptures as the physical keys.
struct RobinProviderGlyph: View {
  let provider: String
  let state: String
  let reducedMotion: Bool
  @Environment(\.scenePhase) private var scenePhase
  private var animated: Bool { !reducedMotion && scenePhase == .active && ["WORKING", "WAITING"].contains(state) }
  var body: some View {
    Group {
      if animated {
        TimelineView(.periodic(from: .distantPast, by: state == "WORKING" ? 0.25 : 0.5)) { context in
          glyph(phase: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4)
        }
      } else { glyph(phase: 0) }
    }.accessibilityHidden(true)
  }
  private func glyph(phase: Double) -> some View {
    Group { if let image = Self.image(provider: provider, state: state, phase: phase) { Image(nsImage: image).resizable().scaledToFit() } }
  }
  @MainActor private static let frames: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>(); cache.countLimit = 96; cache.totalCostLimit = 16 * 1024 * 1024; return cache
  }()
  @MainActor static func image(provider: String, state: String, phase: Double) -> NSImage? {
    let frame = Int((max(0, min(1, phase.isFinite ? phase : 0)) * 16).rounded(.down)) % 16
    let key = "\(provider)|\(state)|\(frame)|\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)|\(NSApp?.effectiveAppearance.name.rawValue ?? "")" as NSString
    if let image = frames.object(forKey: key) { return image }
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 192, pixelsHigh: 192, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.cgContext.clear(CGRect(x: 0, y: 0, width: 192, height: 192))
    ProviderBreakdown.draw(provider: provider, state: state, phase: Double(frame) / 16, in: NSRect(x: 18, y: 18, width: 156, height: 156))
    let image = NSImage(size: NSSize(width: 192, height: 192)); image.addRepresentation(rep)
    frames.setObject(image, forKey: key, cost: 192 * 192 * 4); return image
  }
}
