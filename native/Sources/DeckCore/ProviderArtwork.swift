import AppKit

/// Shared provider artwork for dashboard, keys, and dial.
@MainActor public enum ProviderArtwork {
  private static var images: [String: NSImage] = [:]
  public static func sculpture(provider: String) -> NSImage? {
    let key = "stage-" + provider
    if let cached = images[key] { return cached }
    guard let base = Bundle.main.resourceURL,
      let image = NSImage(contentsOf: base.appendingPathComponent("ProviderSculptures/\(provider).png")) else { return nil }
    images[key] = image
    return image
  }
  public static func image(provider: String, state: String, phase: Double) -> NSImage? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 384, pixelsHigh: 384,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    draw(provider: provider, state: state, in: NSRect(x: 0, y: 0, width: 384, height: 384), phase: phase)
    let image = NSImage(size: NSSize(width: 384, height: 384)); image.addRepresentation(rep)
    return image
  }
  public static func draw(provider: String, state: String, in rect: NSRect, phase: Double) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let moving = ["WORKING", "WAITING"].contains(state) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let t = moving ? phase * .pi * 2 : 0
    let colors: [String: NSColor] = ["claude": .systemOrange, "codex": .systemTeal, "cursor": .white, "gemini": .systemBlue, "antigravity": .systemPurple]
    let color = state == "WAITING" ? NSColor.systemOrange : state == "ERROR" ? .systemRed : colors[provider] ?? .systemGray
    context.saveGState(); defer { context.restoreGState() }
    context.translateBy(x: rect.midX, y: rect.midY)
    let angle = provider == "claude" ? sin(t)*0.08 : provider == "cursor" ? sin(t)*0.05 : 0
    context.rotate(by: angle)
    let bounce = provider == "antigravity" ? sin(t)*rect.height*0.05 : 0
    let box = NSRect(x: -rect.width*0.4, y: -rect.height*0.4+bounce, width: rect.width*0.8, height: rect.height*0.8)
    let ring = NSBezierPath(ovalIn: box.insetBy(dx: -3, dy: -3));ring.lineWidth = 2
    color.withAlphaComponent(moving ? 0.3+0.2*sin(t) : 0.3).setStroke();ring.stroke()
    if images[provider] == nil, let base = Bundle.main.resourceURL {
      for ext in ["icns", "ico", "png"] {
        if let image = NSImage(contentsOf: base.appendingPathComponent("ProviderLogos/\(provider).\(ext)")) { images[provider] = image; break }
      }
    }
    if let image = sculpture(provider: provider) ?? images[provider] {
      // Sculptures have transparent margins; enlarge them to fill the display.
      let shown = sculpture(provider: provider) == nil ? box : box.insetBy(dx: -rect.width * 0.08, dy: -rect.height * 0.08)
      image.draw(in: shown)
      if provider == "codex", moving {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: .zero, radius: rect.width * 0.46,
          startAngle: CGFloat(phase * 360), endAngle: CGFloat(phase * 360 + 35))
        arc.lineWidth = 1.5; NSColor.white.withAlphaComponent(0.8).setStroke(); arc.stroke()
      }
    }
    else {
      let text = provider.isEmpty ? "AGENT" : provider.uppercased()
      let p = NSMutableParagraphStyle();p.alignment = .center
      (text as NSString).draw(in: NSRect(x: box.minX, y: -7, width: box.width, height: 20), withAttributes: [.font:NSFont.monospacedSystemFont(ofSize: max(7,rect.width/7),weight:.bold),.foregroundColor:color,.paragraphStyle:p])
    }
  }
}
