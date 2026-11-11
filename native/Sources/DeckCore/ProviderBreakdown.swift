import AppKit

@MainActor public enum ProviderBreakdown {
  public static func draw(provider: String, state: String, phase: Double, in rect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext,
      let image = ProviderArtwork.sculpture(provider: provider) ?? ProviderArtwork.image(provider: provider, state: state, phase: 0) else { return }
    let moving = ["WORKING", "WAITING", "IDLE", "DONE", "CELEBRATE"].contains(state) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let p = moving ? phase.truncatingRemainder(dividingBy: 1) : 0
    func smooth(_ x: Double) -> Double { let t = max(0,min(1,x)); return t*t*(3-2*t) }
    let opened = p < 0.45 ? smooth((p-0.15)/0.3) : 1-smooth((p-0.6)/0.3)
    let quiet = state == "IDLE" || state == "DONE"
    let breath = CGFloat((1 - cos(p * .pi * 2)) / 2)
    let reassembly = state == "CELEBRATE" ? CGFloat(1 - smooth(min(1, max(0, phase)))) * rect.width * 0.16 : nil
    let amount = reassembly ?? (quiet ? breath * rect.width * 0.018 : CGFloat(opened) * rect.width * (state == "WAITING" ? 0.045 : 0.1))
    if quiet {
      let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -rect.width * 0.06, dy: -rect.height * 0.06))
      NSColor.systemMint.withAlphaComponent(0.25 + breath * 0.2).setStroke(); ring.lineWidth = max(1, rect.width * 0.012); ring.stroke()
      let angle = CGFloat(p * .pi * 2)
      NSColor.systemMint.setFill()
      NSBezierPath(ovalIn: NSRect(x: rect.midX + cos(angle) * rect.width * 0.56 - 1.5, y: rect.midY + sin(angle) * rect.height * 0.56 - 1.5, width: 3, height: 3)).fill()
    }
    let count = ["claude":12,"codex":6,"cursor":3,"gemini":4,"antigravity":3][provider] ?? 4
    for i in 0..<count {
      let angle = CGFloat(i) * .pi * 2 / CGFloat(count) - .pi/2
      var x = cos(angle)*amount, y = sin(angle)*amount
      if provider == "cursor" { x = CGFloat(i-1)*amount*0.65; y = i == 0 ? amount*0.7 : -amount*0.25 }
      if provider == "antigravity" { x = CGFloat(i-1)*amount*0.4; y = amount*(1.1-CGFloat(i)*0.22) }
      context.saveGState()
      context.translateBy(x:x,y:y)
      let path = NSBezierPath();path.move(to:NSPoint(x:rect.midX,y:rect.midY))
      for step in 0...20 {
        let a = angle + CGFloat(step)/20 * (.pi*2/CGFloat(count)+0.002)
        path.line(to:NSPoint(x:rect.midX+cos(a)*rect.width*2,y:rect.midY+sin(a)*rect.height*2))
      }
      path.close();path.addClip();image.draw(in:rect)
      context.restoreGState()
    }
  }
}
