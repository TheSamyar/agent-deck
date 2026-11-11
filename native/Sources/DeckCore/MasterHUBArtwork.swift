import AppKit
import Foundation

@MainActor public enum MasterHUBArtwork {
  private static func deviceColor(_ state: String) -> NSColor {
    switch state {
    case "WORKING": return NSColor(calibratedRed: 0.44, green: 0.81, blue: 1, alpha: 1)
    case "WAITING": return .systemOrange
    case "ERROR": return .systemRed
    case "DONE", "CELEBRATE": return .systemGreen
    case "IDLE", "CLEAR": return .systemMint
    case "UNKNOWN", "DISCONNECTED": return .systemGray
    default: return NSColor(calibratedRed: 0.8, green: 0.32, blue: 0.29, alpha: 1)
    }
  }
  public static var playful: Bool { AgentVisualStyle.isolated || UserDefaults.standard.string(forKey: "masterhubVisualTheme") == "playful" }
  private static let cache: NSCache<NSString, NSData> = { let cache = NSCache<NSString, NSData>(); cache.countLimit = 256; return cache }()
  private static var mediaImage: (state: NowPlaying, data: Data)?
  public static func jpeg(media: NowPlaying) -> Data? {
    if let cached = mediaImage, cached.state == media { return cached.data }
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 240,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 240, height: 240).fill()
    context.cgContext.saveGState()
    let circle = NSBezierPath(ovalIn: NSRect(x: 20, y: 20, width: 200, height: 200)); circle.addClip()
    NSGradient(starting: .systemPurple, ending: .systemPink)?.draw(in: circle, angle: 90)
    if let artwork = media.artwork, let image = NSImage(data: artwork), image.size.width > 0, image.size.height > 0 {
      let side = min(image.size.width, image.size.height)
      image.draw(in: NSRect(x: 20, y: 20, width: 200, height: 200), from: NSRect(x: (image.size.width-side)/2, y: (image.size.height-side)/2, width: side, height: side), operation: .sourceOver, fraction: 1)
    }
    NSGradient(starting: .black.withAlphaComponent(0.85), ending: .black.withAlphaComponent(0.15))?.draw(in: circle, angle: 90)
    context.cgContext.restoreGState()
    let ring = NSBezierPath(ovalIn: NSRect(x: 13, y: 13, width: 214, height: 214)); ring.lineWidth = 3
    NSColor.systemPink.setStroke(); ring.stroke()
    func text(_ value: String, y: CGFloat, height: CGFloat, width: CGFloat, size: CGFloat, secondary: Bool = false) {
      let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
      paragraph.lineBreakMode = height > 25 ? .byWordWrapping : .byTruncatingTail
      (value as NSString).draw(with: NSRect(x: (240-width)/2, y: y, width: width, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(secondary ? 0.75 : 1), .paragraphStyle: paragraph], context: nil)
    }
    text("Spotify", y: 187, height: 16, width: 100, size: 12)
    NSColor.black.withAlphaComponent(0.5).setFill(); NSBezierPath(ovalIn: NSRect(x: 84, y: 111, width: 72, height: 72)).fill()
    if let icon = NSImage(systemSymbolName: media.trackID.isEmpty ? "music.note" : media.playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 38, weight: .semibold))?.withSymbolConfiguration(.init(paletteColors: [.white])) {
      icon.draw(in: NSRect(x: 98, y: 125, width: 44, height: 44))
    }
    text(media.title, y: 65, height: 42, width: 162, size: 17)
    text(media.artist, y: 49, height: 14, width: 128, size: 10, secondary: true)
    text("Turn for volume", y: 33, height: 12, width: 100, size: 9, secondary: true)
    guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else { return nil }
    mediaImage = (media, data)
    return data
  }
  public static func jpeg(dial: MasterHUBDialPresentation, phase: Double = 0, celebration: String? = nil, robinState: String? = nil) -> Data? {
    RobinDeviceArtwork.overlay(dial.sessionID.isEmpty && dial.project == "All quiet" ? quietJPEG() : jpeg(title: dial.project, subtitle: "\(celebration.map { "✓ " + $0 } ?? dial.identity)\n\(dial.status)\n\(dial.position)\n\(dial.summary)", state: dial.state, size: 240, phase: phase, work: dial.work, characterProject: dial.projectKey, agentId: dial.agentId), state: robinState, completion: celebration, phase: phase)
  }
  private static func quietJPEG() -> Data? {
    let key = "quiet-dial-v1" as NSString
    if let cached = cache.object(forKey: key) { return cached as Data }
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 240,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 240, height: 240).fill()
    let ink = NSColor.systemMint
    let ring = NSBezierPath(ovalIn: NSRect(x: 18, y: 18, width: 204, height: 204))
    ring.lineWidth = 1; ink.withAlphaComponent(0.45).setStroke(); ring.stroke()
    let check = NSBezierPath()
    check.move(to: NSPoint(x: 103, y: 151)); check.line(to: NSPoint(x: 115, y: 139))
    check.line(to: NSPoint(x: 139, y: 165)); check.lineWidth = 4
    check.lineCapStyle = .round; check.lineJoinStyle = .round; ink.setStroke(); check.stroke()
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
    for (value, y, size, color) in [
      ("All quiet", CGFloat(96), CGFloat(24), NSColor.white),
      ("No active work", CGFloat(72), CGFloat(13), NSColor.lightGray)
    ] {
      (value as NSString).draw(in: NSRect(x: 36, y: y, width: 168, height: 30),
        withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium),
          .foregroundColor: color, .paragraphStyle: paragraph])
    }
    let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
    if let data { cache.setObject(data as NSData, forKey: key) }
    return data
  }
  public static func jpeg(title: String, subtitle: String, state: String, size: Int, symbol: String = "", rotation: Int = 0, enabled: Bool = true, appIcon: NSImage? = nil, phase: Double = 0, work: SessionWork? = nil, characterProject: String? = nil, agentId: String = "", highlighted: Bool = false) -> Data? {
    guard (1...512).contains(size) else { return nil }
    let animatedPhase = (["WORKING", "WAITING", "CLEAR", "CELEBRATE"].contains(state) || (!agentId.isEmpty && ["IDLE", "DONE"].contains(state))) ? phase : 0
    let playful = Self.playful || !agentId.isEmpty
    let characterProject = characterProject ?? title
    let style = AgentVisualStyle.load(project: characterProject)
    let dependencyVisuals = work?.dependencies?.map { $0.kind.rawValue + ":" + $0.state.rawValue }.joined(separator: ",") ?? ""
    let cacheKey = "\(highlighted)|\(agentId)|\(dependencyVisuals)|\(characterProject)|\(String(describing: style))|\(work?.shellJobs ?? 0):\(work?.subagents ?? 0):\(work?.tools ?? 0):\(work?.awaitingResults ?? false)|\(playful)|\(title)|\(subtitle)|\(state)|\(size)|\(symbol)|\(rotation)|\(enabled)|\(appIcon.map { String(describing: ObjectIdentifier($0)) } ?? "")|\(animatedPhase)" as NSString
    if let data = cache.object(forKey: cacheKey) { return data as Data }

    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    if size == 240 {
      let data = dial(title: title, subtitle: subtitle, state: state, rep: rep, context: context, phase: phase, work: work, characterProject: characterProject, agentId: agentId)
      if let data { cache.setObject(data as NSData, forKey: cacheKey) }
      return data
    }
    let scale = CGFloat(size) / 72
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.cgContext.scaleBy(x: scale, y: scale)
    if rotation != 0 {
      context.cgContext.translateBy(x: 36, y: 36)
      context.cgContext.rotate(by: -CGFloat(rotation) * .pi / 2)
      context.cgContext.translateBy(x: -36, y: -36)
    }
    if state == "CLEAR" {
      let ink = NSColor.systemMint
      NSColor(calibratedRed: 0.025, green: 0.07, blue: 0.065, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 72, height: 72).fill()
      let pulse = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : CGFloat((1 - cos(phase * .pi * 2)) / 2)
      ink.withAlphaComponent(0.55 + pulse * 0.25).setStroke()
      let frame = NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 64, height: 64), xRadius: 10, yRadius: 10)
      frame.lineWidth = 2; frame.stroke()
      ink.withAlphaComponent(0.14 + pulse * 0.08).setFill()
      NSBezierPath(roundedRect: NSRect(x: 12, y: 24, width: 48, height: 40), xRadius: 10, yRadius: 10).fill()
      let check = NSBezierPath()
      check.move(to: NSPoint(x: 20, y: 44)); check.line(to: NSPoint(x: 31, y: 33)); check.line(to: NSPoint(x: 52, y: 57))
      check.lineWidth = 6.5; check.lineCapStyle = .round; check.lineJoinStyle = .round
      ink.setStroke(); check.stroke()
      let p = NSMutableParagraphStyle(); p.alignment = .center
      ("ALL CLEAR" as NSString).draw(in: NSRect(x: 4, y: 8, width: 64, height: 13), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .heavy), .foregroundColor: NSColor.white, .paragraphStyle: p])
      let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
      if let data { cache.setObject(data as NSData, forKey: cacheKey) }
      return data
    }
    if !agentId.isEmpty {
      let ink = deviceColor(state)
      NSColor(calibratedRed: 0.025, green: 0.07, blue: 0.065, alpha: 1).setFill(); NSRect(x:0,y:0,width:72,height:72).fill()
      ink.withAlphaComponent(0.14).setFill(); NSBezierPath(roundedRect:NSRect(x:12,y:24,width:48,height:40),xRadius:10,yRadius:10).fill()
      ProviderBreakdown.draw(provider:agentId,state:state,phase:phase,in:NSRect(x:12,y:22,width:48,height:46))
      let p = NSMutableParagraphStyle();p.alignment = .center;p.lineBreakMode = .byTruncatingMiddle
      let ordinal = subtitle.split(separator:"·").last.map { $0.trimmingCharacters(in:.whitespaces) } ?? ""
      let label = ["WORKING":"WORKING","WAITING":"INPUT","DONE":"DONE","CELEBRATE":"DONE","ERROR":"ERROR","IDLE":"READY","UNKNOWN":"UNKNOWN","DISCONNECTED":"OFFLINE"][state] ?? state
      (label + (Int(ordinal) == nil ? "" : " · " + ordinal) as NSString).draw(in:NSRect(x:4,y:8,width:64,height:13),withAttributes:[.font:NSFont.systemFont(ofSize:11,weight:.heavy),.foregroundColor:NSColor.white,.paragraphStyle:p])
      (highlighted ? NSColor.white : ink.withAlphaComponent(0.7)).setStroke()
      let border = NSBezierPath(roundedRect:NSRect(x:4,y:4,width:64,height:64),xRadius:10,yRadius:10);border.lineWidth = highlighted ? 3 : 2;border.stroke()
      let data = rep.representation(using:.jpeg,properties:[.compressionFactor:0.92]);if let data { cache.setObject(data as NSData,forKey:cacheKey) };return data
    }
    NSColor(calibratedRed: 0.025, green: 0.07, blue: 0.065, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 72, height: 72).fill()
    let color: NSColor = state == "TOOLS" ? .systemTeal : state == "MEDIA" ? .systemPink : state == "DONE" ? .systemGreen : state == "WORKING" ? deviceColor(state)
      : state == "ERROR" || state == "DISCONNECTED" ? .systemRed
      : state == "WAITING" ? .systemOrange : .systemGray
    let pulse = (enabled && (state == "WORKING" || state == "WAITING") && phase != 0) ? CGFloat((1 - cos(phase * .pi * 2)) / 2) : 0
    let tint = enabled ? color : NSColor.systemGray.withAlphaComponent(0.3)
    let attention = enabled && state == "WAITING"
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let attentionPulse: CGFloat = attention ? (reduceMotion ? 1 : CGFloat((1 - cos(phase * .pi * 4)) / 2)) : 0
    (attention ? NSColor.systemOrange.blended(withFraction: attentionPulse, of: .systemYellow) ?? tint : tint).withAlphaComponent(attention ? 0.75 + attentionPulse * 0.25 : 0.55 + pulse * 0.25).setStroke()
    let tileFrame = NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 64, height: 64), xRadius: 10, yRadius: 10)
    tileFrame.lineWidth = attention ? 3 + attentionPulse * 1.5 : 2; tileFrame.stroke()
    tint.withAlphaComponent(attention ? 0.22 + attentionPulse * 0.18 : 0.14 + pulse * 0.08).setFill()
    NSBezierPath(roundedRect: NSRect(x: 12, y: 24, width: 48, height: 40), xRadius: 10, yRadius: 10).fill()
    if let appIcon {
      appIcon.draw(in: NSRect(x: 18, y: 28, width: 36, height: 36), from: .zero,
        operation: .sourceOver, fraction: enabled ? 1 : 0.3)
    } else if playful && ["gearshape.2", "hourglass", "hand.raised", "checkmark.circle", "exclamationmark.triangle", "terminal"].contains(symbol) {
      if let image = ProviderArtwork.sculpture(provider: agentId) ?? ProviderArtwork.image(provider: agentId, state: state, phase: 0) {
        image.draw(in: NSRect(x: 10, y: 22, width: 52, height: 52))
      }
    } else if !symbol.isEmpty, let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
      let configured = icon.withSymbolConfiguration(.init(pointSize: 30, weight: .heavy))?
        .withSymbolConfiguration(.init(paletteColors: [NSColor.white.withAlphaComponent(enabled ? 1 : 0.28)])) ?? icon
      configured.draw(in: NSRect(x: 18, y: 28, width: 36, height: 36))
    }
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
    paragraph.lineBreakMode = .byTruncatingTail
    let shortNames = ["Play / Pause": "Play", "Agent actions": "Actions", "Previous": "Back", "Your Mac": "Mac", "No pending request": "All clear", "Open session": "Open"]
    let ordinal = subtitle.split(separator: "·").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    let label = (shortNames[title] ?? title) + (Int(ordinal) == nil ? "" : " · " + ordinal)
    paragraph.lineBreakMode = .byTruncatingMiddle
    (label as NSString).draw(with: NSRect(x: 4, y: 8, width: 64, height: 13),
      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .heavy),
        .foregroundColor: NSColor.white.withAlphaComponent(enabled ? 1 : 0.35), .paragraphStyle: paragraph], context: nil)
    if highlighted {
      NSColor.systemYellow.withAlphaComponent(0.7).setStroke()
      let border = NSBezierPath(roundedRect: NSRect(x:4,y:4,width:64,height:64),xRadius:10,yRadius:10)
      border.lineWidth = 2; border.stroke()
    }
    let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    if let data { cache.setObject(data as NSData, forKey: cacheKey) }
    return data
  }
  private static func wrapped(_ value: String, width: CGFloat, font: NSFont) -> String {
    if (value as NSString).size(withAttributes: [.font: font]).width <= width { return value }
    var first = "", rest = value
    while let character = rest.first {
      let candidate = first + String(character)
      if (candidate as NSString).size(withAttributes: [.font: font]).width > width { break }
      first = candidate; rest.removeFirst()
    }
    if let split = first.lastIndex(where: { $0 == " " || $0 == "-" }), first.distance(from: first.startIndex, to: split) > 2 {
      let after = first.index(after: split)
      rest = String(first[after...]) + rest; first = String(first[...split]).trimmingCharacters(in: .whitespaces)
    }
    return first + "\n" + rest.trimmingCharacters(in: .whitespaces)
  }
  private static func dial(title: String, subtitle: String, state: String, rep: NSBitmapImageRep, context: NSGraphicsContext, phase: Double, work: SessionWork?, characterProject: String, agentId: String) -> Data? {
    let playful = Self.playful || !agentId.isEmpty
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    if !agentId.isEmpty {
      NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 240, height: 240).fill()
      ProviderBreakdown.draw(provider:agentId,state:state,phase:phase,in:NSRect(x:64,y:110,width:112,height:112))
      func label(_ value: String, y: CGFloat, width: CGFloat, size: CGFloat, color: NSColor) {
        let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: NSRect(x: (240-width)/2, y: y, width: width, height: 22),
          withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color, .paragraphStyle: p])
      }
      let lines = subtitle.components(separatedBy: "\n")
      let stateLabel = ["WORKING":"↻ Working","WAITING":"! Needs input","DONE":"✓ Done","ERROR":"× Error","IDLE":"● Ready","UNKNOWN":"? Unknown","DISCONNECTED":"× Offline"][state] ?? state
      let ink = deviceColor(state);ink.withAlphaComponent(0.18).setFill()
      NSBezierPath(roundedRect:NSRect(x:30,y:78,width:180,height:29),xRadius:7,yRadius:7).fill()
      label(stateLabel,y:81,width:174,size:18,color:ink)
      label(title, y: 54, width: 174, size: 15, color: .white)

      label(lines.first ?? agentId, y: 28, width: 140, size: 10, color: .lightGray)
      if lines.count > 3 { label(lines[3], y: 8, width: 180, size: 9, color: .lightGray) }
      return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
    }
    NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 240, height: 240).fill()
    let color = deviceColor(state)
    let wash = NSGradient(starting: color.withAlphaComponent(0.22), ending: .black)
    wash?.draw(in: NSBezierPath(ovalIn: NSRect(x: 20, y: 20, width: 200, height: 200)), angle: 90)
    ReactorArtwork.draw(state: state, in: NSRect(x: 14, y: 14, width: 212, height: 212), phase: phase)
    let ring = NSBezierPath(ovalIn: NSRect(x: 13, y: 13, width: 214, height: 214)); ring.lineWidth = 1
    color.withAlphaComponent(0.25).setStroke(); ring.stroke()
    for index in 0..<36 {
      let angle = CGFloat(index) * 10 + (state == "WORKING" ? CGFloat(phase) * 360 : 0)
      let arc = NSBezierPath()
      arc.appendArc(withCenter: NSPoint(x: 120, y: 120), radius: 107, startAngle: angle, endAngle: angle + 6)
      arc.lineWidth = 4
      let intensity: CGFloat = state == "WORKING" ? (index < 7 ? 1 : 0.25) : state == "WAITING" ? 0.65 + 0.35 * CGFloat(cos(phase * .pi * 2)) : 1
      color.withAlphaComponent(intensity).setStroke(); arc.stroke()
    }
    func text(_ value: String, _ rect: NSRect, _ size: CGFloat, _ weight: NSFont.Weight, _ ink: NSColor) {
      let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = rect.height > 30 ? .byWordWrapping : .byTruncatingTail
      (value as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: ink, .paragraphStyle: paragraph], context: nil)
    }
    if playful, let work {
      let projectColor = [NSColor.systemTeal,.systemPink,.systemPurple,.systemOrange][AgentCharacter(project:characterProject,state:.working).color]
      for (index,node) in AgentWorkNode.nodes(for:work).enumerated() {
        let centers: [(Double,Double)] = [(42,137),(198,137),(88,204),(152,204)]
        let (x,y) = centers[index]
        let ink: NSColor = node.state == .unknown ? .systemGray : node.state == .needsInput ? .systemOrange : projectColor
        let link = NSBezierPath(); link.move(to:NSPoint(x:120,y:137)); link.line(to:NSPoint(x:x,y:y)); link.lineWidth = 2
        ink.withAlphaComponent(0.35).setStroke(); link.stroke()
        if node.state == .working {
          ink.withAlphaComponent(0.9).setFill()
          NSBezierPath(ovalIn:NSRect(x:120+(x-120)*phase-2,y:137+(y-137)*phase-2,width:4,height:4)).fill()
        }
        let shape: NSBezierPath
        switch node.kind {
        case .shell: shape = NSBezierPath(roundedRect:NSRect(x:x-17,y:y-14,width:34,height:28),xRadius:6,yRadius:6)
        case .subagent: shape = NSBezierPath(ovalIn:NSRect(x:x-17,y:y-17,width:34,height:34))
        case .tool:
          shape = NSBezierPath()
          for side in 0..<6 { let angle = Double(side)*Double.pi/3; let point = NSPoint(x:x+17*cos(angle),y:y+17*sin(angle)); if side == 0 { shape.move(to:point) } else { shape.line(to:point) } }
          shape.close()
        }
        ink.withAlphaComponent(0.25).setFill(); shape.fill()
        ink.withAlphaComponent(0.7).setStroke(); shape.lineWidth = 1; shape.stroke()
        let symbol = node.state == .unknown ? "questionmark" : node.state == .needsInput ? "hand.raised.fill" : node.kind == .shell ? "terminal" : node.kind == .subagent ? (node.count > 1 ? "person.2.fill" : "person.fill") : "wrench.fill"
        let icon = NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.withSymbolConfiguration(.init(paletteColors:[.white]))
        icon?.draw(in:NSRect(x:x-(node.count > 1 ? 12:9),y:y-8,width:18,height:18))
        if node.count > 1 { text(node.count > 99 ? "99+" : String(node.count),NSRect(x:x+3,y:y-7,width:14,height:16),9,.bold,.white) }
      }
    }
    let parts = subtitle.components(separatedBy: "\n")
    text(parts.first ?? "Agent Deck", NSRect(x: 44, y: playful ? 27 : 171, width: 152, height: 19), 14, .medium, .lightGray)
    if playful {
      if let image = ReactorArtwork.image(provider: agentId, state: state, phase: phase) {
        image.draw(in: NSRect(x: 46, y: 88, width: 148, height: 132))
      }
      let titleStyle = NSMutableParagraphStyle(); titleStyle.alignment = .center; titleStyle.lineBreakMode = .byTruncatingTail
      (title as NSString).draw(in: NSRect(x: 35, y: 77, width: 170, height: 25), withAttributes: [.font:NSFont.systemFont(ofSize:16,weight:.semibold),.foregroundColor:NSColor.white,.paragraphStyle:titleStyle])
    } else {
    text(title, NSRect(x: 35, y: 102, width: 170, height: 60), 24, .semibold, .white)
    }
    text(parts.count > 1 ? parts[1] : subtitle, NSRect(x: 40, y: playful ? 55 : 72, width: 160, height: 21), 16, .semibold, color)
    if !playful { text(parts.count > 2 ? parts[2] : "", NSRect(x: 48, y: playful ? 34 : 43, width: 144, height: 16), 11, .medium, .lightGray) }
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
  }

}
