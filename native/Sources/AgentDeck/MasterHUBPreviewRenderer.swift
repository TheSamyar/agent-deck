import AppKit
import ImageIO
import DeckCore
import SwiftUI

/// Renders owned fixture views for development. Does not open the user's windows,
/// connect hardware, register hooks, read screens, or request permissions.
@MainActor enum MasterHUBPreviewRenderer {
  static var sampleWork: SessionWork {
    .init(subagents:2,shellJobs:1,tools:0,awaitingResults:true,scheduledWakeups:0,dependencies:[
      .init(id:"sample-child-1",kind:.subagent,state:.working),
      .init(id:"sample-child-2",kind:.subagent,state:.working),
      .init(id:"sample-shell",kind:.shell,state:.working)])
  }
  static func fixture() async throws -> DeckSnapshot {
    let engine = try DeckEngine(database: DeckDatabase(path: ":memory:"), codexEvidenceLookup: { _ in .unknown })
    let fixtures: [(String, String, SessionState)] = [
      ("claude", "agent-deck", .working), ("cursor", "storefront", .waiting),
      ("codex", "api-gateway", .done), ("claude", "design-system", .idle),
      ("gemini", "docs-site", .working),
    ]
    var ids: [String] = []
    for (index, fixture) in fixtures.enumerated() {
      let receipt = await engine.ingest(agent: fixture.0, event: "SessionStart", body: [
        "data": ["session_id": "preview-\(index)", "cwd": "/Preview/\(fixture.1)"],
        "env": ["bundleId": "com.apple.Terminal", "ppid": 90000 + index, "tty": "/dev/preview\(index)"],
      ])
      await engine.setCapabilities(receipt.sessionId, focus: true, interrupt: fixture.0 != "cursor")
      ids.append(receipt.sessionId)
    }
    _ = await engine.registerRequest(sessionId: ids[1], title: "Run the test suite", context: "pnpm test — storefront",
      choices: [.init(id: "allow", label: "Allow once", requiresHold: true), .init(id: "deny", label: "Deny")], source: "preview")
    await engine.setSelection(ids[0])
    var snapshot = await engine.snapshot()
    snapshot.preferences.showIdleSessions = true
    for (index, id) in ids.enumerated() {
      snapshot.sessions[id]?.status = fixtures[index].2
      snapshot.sessions[id]?.startedAt = DeckClock.now - Double((fixtures.count-index)*60000)
    }
    snapshot.sessions[ids[0]]?.work = sampleWork
    return snapshot
  }
  static func render(to path: String, arguments: [String]) async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    if arguments.contains("--character-sheet") { try AgentCharacterSheet.render(to: path); return }
    var snapshot = try await fixture()
    if arguments.contains("--actions-page"), let request = snapshot.requests.first { snapshot.selectedSessionId = request.sessionId }
    let model = DeckModel(previewSnapshot: snapshot)
    if arguments.contains("--handoffs-page") { model.navigateMasterHUB(.handoffs) }
    if arguments.contains("--media-page") { model.navigateMasterHUB(.media) }
    if arguments.contains("--tools-page") { model.navigateMasterHUB(.tools) }
    if arguments.contains("--mac-page") { model.navigateMasterHUB(.mac) }
    if arguments.contains("--attention-page") { model.navigateMasterHUB(.attention) }
    if arguments.contains("--actions-page") { model.navigateMasterHUB(.actions) }
    let dark = arguments.contains("--dark")
    let width: CGFloat = arguments.contains("--compact") ? 760 : 1000
    let content = arguments.contains("--robin-preview") ? AnyView(RobinIdentityPreview()) : arguments.contains("--checks")
      ? AnyView(MasterHUBControlChecks())
      : AnyView(MasterHUBWorkspace(previewEditing: arguments.contains("--editing")))
    let view = content.environmentObject(model)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
      .overlay(alignment: .bottom) {
        Text("Synthetic preview · No real approvals or playback")
          .font(.caption).padding(10).background(.regularMaterial, in: Capsule()).padding(12)
      }
      .environment(\.colorScheme, dark ? .dark : .light)
      .environment(\.locale, Locale(identifier: "en_US"))
      .environment(\.scenePhase, arguments.contains("--motion-preview") ? .active : .inactive)
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
    host.layoutSubtreeIfNeeded()
    // Yield for SwiftUI's owned layout transaction, without reading desktop UI.
    try await Task.sleep(for: .milliseconds(300))
    host.layoutSubtreeIfNeeded()
    if arguments.contains("--motion-preview") {
      let url = URL(fileURLWithPath: path + ".gif")
      guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 24, nil) else { throw Failure() }
      CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
      for _ in 0..<24 {
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        guard let frame = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure() }
        host.cacheDisplay(in: host.bounds, to: frame)
        guard let image = frame.cgImage else { throw Failure() }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
      }
      guard CGImageDestinationFinalize(destination) else { throw Failure() }
    }
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure() }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure() }
    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    print("Rendered MasterHUB fixture to \(path)")
  }
  private struct Failure: Error {}
}
