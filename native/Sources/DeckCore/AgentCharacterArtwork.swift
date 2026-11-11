import AppKit

@MainActor public enum AgentCharacterArtwork {
  /// Draws into the caller's bitmap context, shared by app and physical displays.
  public static func draw(_ character: AgentCharacter, in rect: NSRect, phase: Double = 0, reducedMotion: Bool = false) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState(); defer { context.restoreGState() }
    context.translateBy(x: rect.minX, y: rect.minY)
    context.scaleBy(x: rect.width / 100, y: rect.height / 100)
    let palette: [NSColor] = [.systemTeal, .systemPink, .systemPurple, .systemOrange]
    let color = palette[character.color]
    let moving = !reducedMotion && [.building, .watching, .asking].contains(character.expression)
    let bounce = moving ? CGFloat(sin(phase * .pi * 2)) * 3 : 0
    color.withAlphaComponent(0.18).setFill()
    NSBezierPath(ovalIn: NSRect(x: 10, y: 4, width: 80, height: 15)).fill()
    color.setStroke()
    let arms = NSBezierPath()
    arms.move(to: NSPoint(x: 17, y: 46+bounce)); arms.line(to: NSPoint(x: 5, y: character.expression == .asking ? 78 : 30+bounce))
    arms.move(to: NSPoint(x: 83, y: 46+bounce)); arms.line(to: NSPoint(x: 95, y: character.expression == .completed ? 80 : 30+bounce))
    arms.lineWidth = 7; arms.lineCapStyle = .round; arms.stroke()
    color.setFill()
    if character.variant == 1 {
      for x: CGFloat in [27, 60] { NSBezierPath(roundedRect: NSRect(x: x, y: 74+bounce, width: 13, height: 25), xRadius: 6, yRadius: 6).fill() }
    } else if character.variant == 2 {
      NSBezierPath(ovalIn: NSRect(x: 46, y: 81+bounce, width: 22, height: 12)).fill()
    } else if character.variant == 3 {
      let bolt = NSBezierPath(); bolt.move(to: NSPoint(x: 48,y: 98+bounce)); bolt.line(to: NSPoint(x: 38,y: 83+bounce)); bolt.line(to: NSPoint(x: 60,y: 87+bounce)); bolt.close(); bolt.fill()
    }
    let body = NSRect(x: 15, y: 20 + bounce, width: 70, height: 62)
    NSGradient(starting: color.blended(withFraction: 0.3, of: .white)!, ending: color)?.draw(in: NSBezierPath(roundedRect: body, xRadius: CGFloat(12 + character.variant * 5), yRadius: CGFloat(12 + character.variant * 5)), angle: -90)
    NSColor(calibratedWhite: 0.06, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 24, y: 39 + bounce, width: 52, height: 31), xRadius: 12, yRadius: 12).fill()
    let eyeColor: NSColor = character.expression == .repair ? .systemRed : .white
    eyeColor.setFill()
    for x: CGFloat in [35, 59] {
      let sleepy = character.expression == .resting
      NSBezierPath(roundedRect: NSRect(x: x, y: 51 + bounce, width: 7, height: sleepy ? 2 : 10), xRadius: 3, yRadius: 3).fill()
    }
    color.setStroke()
    let antenna = NSBezierPath(); antenna.move(to: NSPoint(x: 50, y: 81 + bounce)); antenna.line(to: NSPoint(x: 50, y: 90 + bounce)); antenna.lineWidth = 3; antenna.stroke()
    (character.expression == .asking ? NSColor.systemOrange : color).setFill()
    NSBezierPath(ovalIn: NSRect(x: 45, y: 88 + bounce, width: 10, height: 10)).fill()
    let glyph: String
    switch character.expression { case .asking: glyph = "?"; case .repair: glyph = "!"; case .completed: glyph = "✓"; case .watching: glyph = "···"; case .unknown: glyph = "?"; default: glyph = "" }
    (glyph as NSString).draw(in: NSRect(x: 39, y: 22 + bounce, width: 30, height: 18), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.white])
  }
}
