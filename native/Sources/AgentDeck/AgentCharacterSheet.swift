import AppKit
import DeckCore

@MainActor enum AgentCharacterSheet {
  static func render(to path: String) throws {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 1080, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: rep) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSColor(calibratedWhite: 0.04, alpha: 1).setFill(); NSRect(x:0,y:0,width:1280,height:1080).fill()
    for variant in 0..<4 {
      let project = (0..<100).map { "Preview-\($0)" }.first { AgentCharacter(project: $0, state: .working).variant == variant }!
      for (row,state) in [SessionState.working,.waiting,.done,.error].enumerated() {
        let x = CGFloat(variant*320), y = CGFloat(810-row*260)
        let work: SessionWork? = state == .working ? MasterHUBPreviewRenderer.sampleWork : nil
        for size in [72,240] {
          let jpeg = MasterHUBArtwork.jpeg(title: project, subtitle: "Demo agent\n\(state.label)\nSynthetic fixture", state: state.rawValue, size: size, symbol: "gearshape.2", phase: 0.25, work: work, characterProject: project)
          if let jpeg, let image = NSImage(data: jpeg) { image.draw(in: NSRect(x:x+(size == 72 ? 0:76),y:y,width:CGFloat(size),height:CGFloat(size))) }
        }
      }
    }
    ("Synthetic character comparison · keys 72 px · dial 240 px · no live agents" as NSString).draw(at: NSPoint(x:20,y:20),withAttributes:[.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.white])
    guard let png = rep.representation(using:.png,properties:[:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to:URL(fileURLWithPath:path))
  }
}
