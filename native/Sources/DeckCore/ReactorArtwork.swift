import AppKit

@MainActor public enum ReactorArtwork {
  public static func color(_ state: String) -> NSColor {
    switch state {
    case "WAITING": return .systemOrange
    case "ERROR": return .systemRed
    case "DONE": return .systemGreen
    case "DISCONNECTED", "UNKNOWN", "IDLE": return .systemGray
    default: return NSColor(calibratedRed: 0.15, green: 0.88, blue: 1, alpha: 1)
    }
  }
  public static func draw(state: String, in rect: NSRect, phase: Double) {
    let ink = color(state)
    let moving = ["WORKING", "WAITING"].contains(state) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let p = moving ? phase : 0
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let r = min(rect.width, rect.height) / 2
    for layer in 0..<3 {
      let radius = r * (1 - CGFloat(layer) * 0.12)
      for segment in 0..<12 {
        let offset = CGFloat(p * 360) * (layer == 1 ? -1 : 1)
        let start = CGFloat(segment * 30 + (segment % 3) * 3) + offset
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start + (segment == layer ? 23 : 12))
        arc.lineWidth = layer == 1 ? max(1, r * 0.035) : 1
        ink.withAlphaComponent(layer == 1 ? 0.65 : 0.28).setStroke(); arc.stroke()
      }
    }
    for tick in 0..<48 {
      let angle = CGFloat(tick) * .pi / 24
      let inner = r * (tick % 4 == 0 ? 0.64 : 0.68)
      let path = NSBezierPath()
      path.move(to: NSPoint(x: center.x+cos(angle)*inner,y: center.y+sin(angle)*inner))
      path.line(to: NSPoint(x: center.x+cos(angle)*r*0.71,y: center.y+sin(angle)*r*0.71))
      path.lineWidth = 1; ink.withAlphaComponent(0.5).setStroke(); path.stroke()
    }
  }
  public static func image(provider: String, state: String, phase: Double) -> NSImage? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 384, pixelsHigh: 384, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    draw(state: state, in: NSRect(x: 14, y: 14, width: 356, height: 356), phase: phase)
    if let logo = ProviderArtwork.sculpture(provider: provider) ?? ProviderArtwork.image(provider: provider, state: state, phase: 0) {
      logo.draw(in: NSRect(x: 86, y: 86, width: 212, height: 212))
    }
    let image = NSImage(size: NSSize(width: 384, height: 384)); image.addRepresentation(rep); return image
  }
}
