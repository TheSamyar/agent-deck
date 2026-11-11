import AppKit
import DeckCore
import SwiftUI

/// Isolated showcase: no DeckModel, device owners, service client, or settings store.
struct MasterHUBDemoApp: App {
  var body: some Scene {
    Window("Agent Deck · Demo", id: "showcase") { MasterHUBDemoView().frame(minWidth: 760, minHeight: 600) }
      .defaultSize(width: 900, height: 700)
  }
}
private struct MasterHUBDemoView: View {
  @State private var clock = MasterHUBDisplayClock()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var snapshot: DeckSnapshot?
  @State private var media = MasterHUBDemoMedia.state
  @State private var surface = MasterHUBSurface()
  @State private var page = MasterHUBPage.agents
  @State private var scenario = 0
  @State private var feedback = "Sample agents only. No hardware, permissions, or accounts needed."
  var body: some View {
    let layout = currentLayout
    VStack(alignment: .leading, spacing: 24) {
      HStack { Text("Agent Deck").font(.largeTitle.bold()); Spacer(); Label("Demo", systemImage: "play.rectangle.fill").foregroundStyle(.purple) }
      Picker("Page", selection: $page) {
        ForEach([MasterHUBPage.agents, .mac, .media, .tools, .attention, .handoffs], id: \.self) { Text($0.title).tag($0) }
      }.pickerStyle(.segmented).onChange(of: page) { _, value in surface.navigate(value) }
      HStack(spacing: 32) {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(72)), count: 5), spacing: 8) {
          ForEach(Array(layout.tiles.enumerated()), id: \.offset) { _, item in
            Button { activate(item) } label: {
              MasterHUBKeyFace(clock: clock, item: item, selected: false, identified: false, ordinal: nil)
            }.buttonStyle(.plain).disabled(!item.tile.enabled).accessibilityLabel(item.tile.label)
          }
        }.frame(width: 400)
        MasterHUBDialFace(snapshot: snapshot, media: media, handoffsMode: page == .handoffs, mediaMode: page == .media, clock: clock).frame(width:200,height:200)
      }.padding(24).background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 24))
      if let request = snapshot?.requests.first(where: { $0.id == layout.selectedRequestID }) {
        Text("Sample request: \(request.title)").font(.headline)
        Text(request.context).font(.system(.body, design: .monospaced))
      }
      HStack {
        Button("Play work → wait → input → completion") {
          resetSamples(); page = .agents; scenario += 1
        }
        Button("Rest sample agents") { restSamples() }
      }
      Label(feedback, systemImage: "info.circle").font(.callout).textSelection(.enabled)
      Spacer()
    }.padding(32).task {
      do { snapshot = try await MasterHUBPreviewRenderer.fixture(); if CommandLine.arguments.contains("--demo-idle") { restSamples() } }
      catch { feedback = "Demo could not load: \(error.localizedDescription)" }
    }.task {
      var tick = 0
      while !Task.isCancelled {
        let active = page != .media && snapshot?.sessions.values.contains { [.working,.waiting].contains($0.status) } == true
        let keyPhase = active && !reduceMotion ? Double((tick % 16)/2)/8 : 0
        if clock.keys.phase != keyPhase { clock.keys.phase = keyPhase }
        let phase = active && !reduceMotion ? Double(tick % 16)/16 : 0
        if (tick % 2 == 0 || phase == 0) && clock.phase != phase { clock.phase = phase }
        tick += 1
        do { try await Task.sleep(for:.milliseconds(250)) } catch { return }
      }
    }.task(id: scenario) {
      guard scenario > 0, let root = snapshot?.selectedSessionId else { return }
      let question = try? await MasterHUBPreviewRenderer.fixture().requests.first
      for stage in 0..<4 {
        guard !Task.isCancelled else { return }
        snapshot?.sessions[root]?.updatedAt = DeckClock.now
        snapshot?.requests.removeAll { $0.sessionId == root }
        if stage == 2, var request = question {
          request.sessionId = root; request.createdAt = DeckClock.now; request.expiresAt = DeckClock.now + 120000
          snapshot?.requests.append(request)
        }
        snapshot?.sessions[root]?.status = stage == 2 ? .waiting : stage == 3 ? .done : .working
        snapshot?.sessions[root]?.work = stage == 1 ? MasterHUBPreviewRenderer.sampleWork : nil
        feedback = ["Demo: root working", "Demo: shell and two subagents running; parent remains Working", "Demo: needs your input in the original agent", "Demo: root finished; dependencies are complete"][stage]
        if stage == 3 { clock.celebration = snapshot?.sessions[root]?.workspace }
        do {
          try await Task.sleep(for: .milliseconds(1500))
          clock.celebration = nil
          try await Task.sleep(for: .milliseconds(1500))
        } catch { return }
      }
    }
  }
  private func restSamples() { scenario = 0; resetSamples() }
  private func resetSamples() {
    clock.celebration = nil
    for id in snapshot?.sessions.keys.map({ $0 }) ?? [] { snapshot?.sessions[id]?.status = .idle; snapshot?.sessions[id]?.work = nil }
    snapshot?.requests.removeAll()
    feedback = "Sample agents resting. Real agents and hardware are unchanged."
  }
  private var currentLayout: MasterHUBSurfaceSnapshot {
    var copy = surface
    return copy.layout(snapshot: snapshot, configuration: .init(), media: media)
  }
  private func activate(_ item: MasterHUBSurfaceTile) {
    let tile = item.tile
    switch tile.action {
    case "focus": snapshot?.selectedSessionId = tile.target; feedback = "Demo: selected \(tile.label). No real window was opened."
    case "hub.macPage": page = .mac
    case "hub.mediaPage": page = .media
    case "hub.toolsPage": page = .tools
    case "hub.agents": page = .agents
    case "hub.handoffs": page = .handoffs
    case "hub.attention": page = .attention
    case "hub.actions", "hub.request": snapshot?.selectedSessionId = tile.target; surface.navigate(.actions, sessionID: tile.target, requestID: tile.requestId)
    case "hub.next": surface.movePage(1)
    case "hub.previous": surface.movePage(-1)
    case "hub.media":
      switch tile.target { case "playpause": media.playing.toggle(); case "shuffle": media.shuffle.toggle(); case "repeat": media.repeating.toggle(); default: break }
      feedback = "Demo: \(tile.label). Real playback and volume are unchanged."
    case "respond": snapshot?.requests.removeAll { $0.id == tile.requestId }; feedback = "Demo: request answered locally. No command was executed."
    default: feedback = "Demo: \(tile.label). Real actions are disabled."
    }
  }
}
