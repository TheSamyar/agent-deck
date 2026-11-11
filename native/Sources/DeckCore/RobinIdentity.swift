import AppKit

public enum RobinIdentity {
  public static let instruction = """
  You are Alfred, Agent Deck's capable and friendly sidekick for managing coding agents.
  Be an active teammate: understand the user's goal and help them make useful decisions.
  Ask one focused question when the answer changes the work: desired outcome, success criteria,
  priorities, preferences, or a concrete blocker. Offer a grounded recommendation when helpful.
  Use the conversation's earlier answers; never restart an interview or ask a question already answered.
  Do not append a question to every response. When the request is clear, act and report evidence.
  Keep replies concise, concrete, and useful. Never invent activity to start a conversation.
  Use occasional dry humor when appropriate. Avoid repeated superhero jokes, calling the user Batman,
  and addressing them as sir. Never claim an action succeeded without application evidence.
  """
}
@MainActor public enum RobinArtwork {
  public static func jpeg(state: String, phase: Double) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide:240,pixelsHigh:240,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let context = NSGraphicsContext(bitmapImageRep:rep) else { return nil }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSColor.black.setFill(); NSRect(x:0,y:0,width:240,height:240).fill()
    image(state:state,phase:phase)?.draw(in:NSRect(x:40,y:75,width:160,height:160))
    let p = NSMutableParagraphStyle();p.alignment = .center;p.lineBreakMode = .byTruncatingTail
    for (text,y,size) in [("Alfred",CGFloat(58),CGFloat(20)),(state,CGFloat(35),CGFloat(12))] {
      (text as NSString).draw(in:NSRect(x:35,y:y,width:170,height:26),withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:.semibold),.foregroundColor:NSColor.systemYellow,.paragraphStyle:p])
    }
    return rep.representation(using:.jpeg,properties:[.compressionFactor:0.95])
  }
  public enum Mode: String, CaseIterable, Sendable { case ready, listening, thinking, speaking, needsYou, error, complete }
  public static func mode(for state: String) -> Mode {
    let value = state.lowercased()
    if value.contains("error") || value.contains("unavailable") || value.contains("could not") { return .error }
    if value.contains("waiting for your answer") || value.contains("decision") || value.contains("needs you") || value.contains("needs input") || value == "blocked" { return .needsYou }
    if value == "listening" || value == "wake listening" || value.hasPrefix("listening for") || value == "conversation open" { return .listening }
    if value.contains("speaking") { return .speaking }
    if ["working", "checking", "repairing", "acting"].contains(value) || value.contains("thinking") || value.contains("preparing") || value.contains("processing") || value.contains("submitting") || value.contains("opening") { return .thinking }
    if value == "complete" || value == "done" || value == "finished" { return .complete }
    return .ready
  }
  public static func image(state: String, phase: Double) -> NSImage? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.cgContext.clear(CGRect(x: 0, y: 0, width: 256, height: 256))
    let mode = mode(for: state)
    let p = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : phase.truncatingRemainder(dividingBy: 1)
    let pulse = CGFloat((1 - cos(p * .pi * 2)) / 2)
    let gold = NSColor(calibratedRed: 1, green: 0.79, blue: 0.23, alpha: 1)
    let scarlet = NSColor(calibratedRed: 0.92, green: 0.2, blue: 0.25, alpha: 1)
    let mint = NSColor(calibratedRed: 0.25, green: 0.95, blue: 0.7, alpha: 1)
    let color: NSColor
    switch mode {
    case .ready, .complete: color = mint
    case .listening: color = .systemCyan
    case .thinking: color = gold
    case .speaking: color = .systemPink
    case .needsYou: color = .systemOrange
    case .error: color = .systemRed
    }
    let halo = NSBezierPath(ovalIn: NSRect(x: 19, y: 19, width: 218, height: 218))
    NSGradient(starting: color.withAlphaComponent(0.23 + pulse * 0.08), ending: color.withAlphaComponent(0))?.draw(in: halo, relativeCenterPosition: .zero)
    for segment in 0..<8 {
      let arc = NSBezierPath()
      let rotation = mode == .thinking ? CGFloat(p * 360) : mode == .ready ? CGFloat(p * 45) : 0
      let start = CGFloat(segment * 45) + rotation
      arc.appendArc(withCenter: NSPoint(x: 128, y: 128), radius: 112, startAngle: start, endAngle: start + (mode == .thinking ? 23 : 32))
      arc.lineWidth = mode == .needsYou || mode == .error ? 4 : 2
      color.withAlphaComponent(segment % 2 == 0 ? 0.65 : 0.22).setStroke(); arc.stroke()
    }
    // Wings open, fan, or fold around a stable Alfred shield for each actual state.
    let spread: CGFloat = mode == .listening ? 14 + pulse * 6 : mode == .thinking ? pulse * 12 : mode == .speaking ? 5 + pulse * 8 : mode == .needsYou ? 12 : mode == .complete ? 16 : pulse * 3
    for side in [CGFloat(-1), CGFloat(1)] {
      func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: 128 + side * x, y: y) }
      let wing = NSBezierPath()
      wing.move(to: point(40, 165)); wing.line(to: point(91 + spread, 187 + spread * 0.4))
      wing.line(to: point(76 + spread, 139)); wing.line(to: point(88 + spread * 0.4, 116))
      wing.line(to: point(51, 102)); wing.line(to: point(31, 137)); wing.close()
      scarlet.setFill(); wing.fill()
      let seam = NSBezierPath(); seam.move(to: point(42, 147)); seam.line(to: point(80 + spread, 169))
      seam.lineWidth = 2; gold.withAlphaComponent(0.7).setStroke(); seam.stroke()
      if mode == .listening {
        for wave in 0..<3 {
          let line = NSBezierPath()
          let x = 94 + CGFloat(wave) * 9
          line.move(to: point(x, 110 - CGFloat(wave) * 5))
          line.curve(to: point(x, 147 + CGFloat(wave) * 5), controlPoint1: point(x + 8 + pulse * 3, 119), controlPoint2: point(x + 8 + pulse * 3, 138))
          line.lineWidth = 2; color.withAlphaComponent(0.85 - CGFloat(wave) * 0.2).setStroke(); line.stroke()
        }
      }
    }
    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: 73, y: 188)); shield.line(to: NSPoint(x: 128, y: 207))
    shield.line(to: NSPoint(x: 183, y: 188)); shield.line(to: NSPoint(x: 173, y: 91))
    shield.line(to: NSPoint(x: 128, y: 48)); shield.line(to: NSPoint(x: 83, y: 91)); shield.close()
    NSColor(calibratedRed: 0.035, green: 0.05, blue: 0.055, alpha: 1).setFill(); shield.fill()
    (mode == .error ? color : gold).setStroke(); shield.lineWidth = 4; shield.stroke()
    let inset = shield.copy() as! NSBezierPath
    let transform = NSAffineTransform(); transform.translateX(by: 128, yBy: 128); transform.scale(by: 0.9); transform.translateX(by: -128, yBy: -128)
    inset.transform(using: transform as AffineTransform); color.withAlphaComponent(0.35).setStroke(); inset.lineWidth = 1; inset.stroke()
    ("A" as NSString).draw(at: NSPoint(x: 94, y: 83), withAttributes: [.font: NSFont.systemFont(ofSize: 94, weight: .black), .foregroundColor: gold])
    if mode == .speaking {
      for bar in 0..<7 {
        let height = CGFloat(7 + (1 + sin(p * .pi * 4 + Double(bar) * 0.9)) * 9)
        color.setFill(); NSBezierPath(roundedRect: NSRect(x: 95 + CGFloat(bar) * 10, y: 31 - height / 2, width: 5, height: height), xRadius: 2, yRadius: 2).fill()
      }
    } else if mode == .needsYou || mode == .error {
      let alert = NSBezierPath(ovalIn: NSRect(x: 177, y: 183, width: 35, height: 35)); color.setFill(); alert.fill()
      ((mode == .error ? "×" : "!") as NSString).draw(at: NSPoint(x: mode == .error ? 185 : 190, y: 184), withAttributes: [.font: NSFont.systemFont(ofSize: 27, weight: .black), .foregroundColor: NSColor.black])
    } else if mode == .complete {
      let check = NSBezierPath(); check.move(to: NSPoint(x: 108, y: 27)); check.line(to: NSPoint(x: 121, y: 15)); check.line(to: NSPoint(x: 148, y: 39))
      check.lineWidth = 6; check.lineCapStyle = .round; color.setStroke(); check.stroke()
    } else {
      let dot = NSBezierPath(ovalIn: NSRect(x: 124, y: 22, width: 8, height: 8)); color.setFill(); dot.fill()
    }
    let image = NSImage(size: NSSize(width: 256, height: 256)); image.addRepresentation(rep); return image
  }
}
