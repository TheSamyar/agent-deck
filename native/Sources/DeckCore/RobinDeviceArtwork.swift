import AppKit

/// A status strip leaves the screen-dial's project and button target intact.
@MainActor public enum RobinDeviceArtwork {
  public static func overlay(_ jpeg: Data?, state: String?, completion: String? = nil, phase: Double) -> Data? {
    guard let jpeg else { return nil }
    guard state != nil || completion != nil else { return jpeg }
    guard let image = NSImage(data: jpeg), let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
      pixelsWide: 240, pixelsHigh: 240, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { return jpeg }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    image.draw(in: NSRect(x: 0, y: 0, width: 240, height: 240))
    let visibleCompletion = state == nil ? completion : nil
    let text = visibleCompletion.map { "DONE · " + $0 } ?? "ALFRED · " + (state ?? "Ready").uppercased()
    let ink: NSColor = visibleCompletion != nil ? .systemGreen : (state?.lowercased().contains("listen") == true ? .systemMint : .systemYellow)
    let strip = NSBezierPath(roundedRect: NSRect(x: 33, y: 211, width: 174, height: 22), xRadius: 8, yRadius: 8)
    NSColor.black.withAlphaComponent(0.94).setFill(); strip.fill()
    ink.withAlphaComponent(0.8).setStroke(); strip.lineWidth = 1; strip.stroke()
    let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineBreakMode = .byTruncatingTail
    (text as NSString).draw(in: NSRect(x: 39, y: 214, width: 162, height: 16), withAttributes: [
      .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: ink, .paragraphStyle: p])
    if visibleCompletion != nil {
      let ring = NSBezierPath(ovalIn: NSRect(x: 8, y: 8, width: 224, height: 224))
      ring.lineWidth = 4
      let breath = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0.6 + 0.4 * (1 - cos(phase * .pi * 2)) / 2
      ink.withAlphaComponent(breath).setStroke(); ring.stroke()
    }
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
  }
}
