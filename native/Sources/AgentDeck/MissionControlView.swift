import SwiftUI
import DeckCore

/// Live telemetry, not a decorative progress simulation.
struct MissionControlView: View {
  @EnvironmentObject private var model: DeckModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("dashboardAnimatedArtwork") private var animatedArtwork = false
  @State private var selected: String?
  private let mint = Color(red: 0.3, green: 0.94, blue: 0.71)
  private var sessions: [SessionSnapshot] {
    guard model.connected, let snapshot = model.snapshot else { return [] }
    return MasterHUBSurface.orderedSessions(snapshot)
  }
  private var telemetrySessions: [SessionSnapshot] {
    guard model.connected, let snapshot = model.snapshot else { return [] }
    return snapshot.sessions.values.filter {
      snapshot.preferences.enabledAgents.contains($0.agentId) && $0.status != .disconnected && $0.status != .unknown
    }.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt }
  }
  private var requests: [PendingRequest] {
    guard model.connected else { return [] }
    return (model.snapshot?.requests ?? []).filter { $0.state == "pending" && $0.expiresAt > DeckClock.now }
      .sorted { $0.createdAt < $1.createdAt }
  }
  private func needsYou(_ session: SessionSnapshot) -> Bool {
    session.status == .waiting || session.status == .error || session.work?.needsInput == true || requests.contains { $0.sessionId == session.id }
  }
  private var attention: [SessionSnapshot] { telemetrySessions.filter(needsYou) }
  private var attentionCount: Int { Set(attention.map(\.id) + requests.map(\.sessionId)).count }
  private var current: SessionSnapshot? {
    sessions.first { $0.id == selected } ?? attention.first ?? sessions.first { $0.status == .working } ?? sessions.first
  }
  private var quietMotion: Bool { !animatedArtwork || reduceMotion || model.preferences.reduceMotion || model.masterhubConfiguration.motion == false || scenePhase != .active }
  private var headline: String {
    if !model.connected { return "Connection needed" }
    if !attention.isEmpty || !requests.isEmpty { return "Your move" }
    if telemetrySessions.contains(where: { $0.status == .working }) { return "Missions in motion" }
    return "All clear"
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      header
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
        counter("Needs you", count: attentionCount, symbol: "hand.raised.fill", color: .orange)
        counter("Working", count: telemetrySessions.filter { $0.status == .working && !needsYou($0) }.count, symbol: "bolt.fill", color: .cyan)
        counter("Finished", count: telemetrySessions.filter { $0.status == .done && !needsYou($0) }.count, symbol: "checkmark.circle.fill", color: mint)
        counter("Ready", count: telemetrySessions.filter { $0.status == .idle && !needsYou($0) }.count, symbol: "circle.dotted", color: .yellow)
      }
      if let request = requests.first { requestBanner(request) }
      if let session = current {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 30) { core(session); details(session).frame(width: 300) }
          VStack(alignment: .leading, spacing: 20) { core(session).frame(maxWidth: .infinity); details(session) }
        }
        Text("YOUR AGENTS · \(sessions.count)").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.white.opacity(0.6)).padding(.top, 4)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
          ForEach(sessions) { session in agentCard(session) }
        }
      } else { emptyState }
    }.padding(22)
      .foregroundStyle(.white)
      .background(LinearGradient(colors: [Color(red: 0.055, green: 0.085, blue: 0.09), Color(red: 0.025, green: 0.035, blue: 0.04)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
      .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder((attention.isEmpty ? mint : .orange).opacity(0.28)) }
  }
  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        Text("ALFRED / MISSION CONTROL").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.yellow)
        Text(headline).font(.system(size: 30, weight: .bold, design: .rounded))
        Text(model.connected ? "Live agent activity · no guessed progress" : "Reconnect to see current agent activity.")
          .font(.caption).foregroundStyle(.white.opacity(0.6))
      }
      Spacer(minLength: 6)
      VStack(alignment: .trailing, spacing: 10) {
        Label(model.connected ? "LIVE" : "OFFLINE", systemImage: model.connected ? "dot.radiowaves.left.and.right" : "wifi.slash")
          .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(model.connected ? mint : .orange)
        Button("New mission", systemImage: "plus") { model.showCodex = true }.buttonStyle(.bordered)
      }
    }
  }
  private func counter(_ title: String, count: Int, symbol: String, color: Color) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(color)
      VStack(alignment: .leading, spacing: 3) {
        Text(model.connected ? String(count) : "—").font(.system(size: 25, weight: .bold, design: .rounded))
        Text(title).font(.caption).foregroundStyle(.white.opacity(0.7))
      }
      Spacer(minLength: 0)
    }.padding(13).background(color.opacity(count > 0 ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 13))
      .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(color.opacity(count > 0 ? 0.28 : 0.08)) }
      .accessibilityElement(children: .combine)
  }
  private func requestBanner(_ request: PendingRequest) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "hand.raised.fill").font(.title2).foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 4) {
        let session = model.snapshot?.sessions[request.sessionId]
        Text(session.map { "\($0.agentName) · \(project($0))" } ?? "Agent request").font(.caption).foregroundStyle(.orange)
        Text(request.title).font(.headline).lineLimit(2)
        if !request.context.isEmpty { Text(request.context).font(.caption).lineLimit(2).foregroundStyle(.white.opacity(0.7)) }
      }
      Spacer(minLength: 4)
      Button("Review") { model.section = "Attention" }.buttonStyle(.borderedProminent).tint(.orange)
    }.padding(15).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
      .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.orange.opacity(0.4)) }
  }
  private func agentCard(_ session: SessionSnapshot) -> some View {
    Button { selected = session.id } label: {
      HStack(spacing: 12) {
        RobinProviderGlyph(provider: session.agentId, state: session.status.rawValue, reducedMotion: quietMotion)
          .frame(width: 58, height: 58)
        VStack(alignment: .leading, spacing: 4) {
          Text(project(session)).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
          Text(session.agentName).font(.caption).foregroundStyle(.white.opacity(0.55))
          Text(statusText(session))
            .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(ink(session))
          Text(activity(session)).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
        }
        Spacer(minLength: 0)
      }.padding(12).frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background(ink(session).opacity(current?.id == session.id ? 0.13 : 0.04), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(ink(session).opacity(current?.id == session.id ? 0.7 : 0.2), lineWidth: current?.id == session.id ? 1.5 : 1) }
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }.buttonStyle(.plain)
      .accessibilityLabel("Select \(session.agentName), \(project(session)), \(session.status.label), \(activity(session))")
  }
  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: model.connected ? "checkmark.shield.fill" : "wifi.slash").font(.system(size: 48, weight: .light)).foregroundStyle(mint)
      Text(model.connected ? "All clear" : "Waiting for the agent service").font(.title3.bold())
      Text(model.connected ? (telemetrySessions.isEmpty ? "Start an agent. Alfred will show what it is doing here." : "Finished and ready agents are hidden by your display preference. The totals above still include them.") : "The last known state is hidden until the live connection returns.")
        .font(.callout).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
      Button("Start Codex") { model.showCodex = true }.buttonStyle(.bordered)
    }.frame(maxWidth: .infinity).padding(.vertical, 40)
  }
  private func core(_ session: SessionSnapshot) -> some View { HologramView(session: session, reduceMotion: quietMotion) }
  private func statusText(_ session: SessionSnapshot) -> String {
    needsYou(session) ? "Needs you" : session.status == .idle ? "Ready" : session.status.label
  }
  private func project(_ session: SessionSnapshot) -> String { model.preferences.projectNames[session.projectKey] ?? session.workspace }
  private func ink(_ session: SessionSnapshot) -> Color {
    if needsYou(session) { return session.status == .error ? .red : .orange }
    return session.status == .idle ? .yellow : Color(nsColor: ReactorArtwork.color(session.status.rawValue))
  }
  private func activity(_ session: SessionSnapshot) -> String {
    if let request = requests.first(where: { $0.sessionId == session.id }) { return request.title }
    if !session.detail.isEmpty { return session.detail }
    if let work = session.work, work.hasOutstanding || work.awaitingResults { return work.label }
    return session.status == .idle ? "Standing by" : session.status.label
  }
  private func details(_ session: SessionSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(session.agentName.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(ink(session))
      Text(project(session)).font(.system(size: 28, weight: .bold, design: .rounded)).lineLimit(2)
      Label(statusText(session).uppercased(), systemImage: needsYou(session) ? "hand.raised.fill" : session.status == .done ? "checkmark.circle.fill" : "circle.fill")
        .font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(ink(session))
      Text(activity(session)).font(.callout).foregroundStyle(.white.opacity(0.8)).lineLimit(4)
      if let work = session.work, work.hasOutstanding {
        Text("\(work.subagents) subagents · \(work.shellJobs) shell jobs · \(work.tools) tools")
          .font(.caption).foregroundStyle(.white.opacity(0.5))
      }
      HStack {
        Button("Open session", systemImage: "arrow.up.right") { model.perform(.init(action: "focus", sessionId: session.id)) }
          .disabled(!session.capabilities.focus || model.actionInFlight)
        if needsYou(session) { Button("Review", systemImage: "hand.raised") { model.section = "Attention" }.tint(.orange) }
      }.buttonStyle(.bordered)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
