import SwiftUI
import DeckCore

/// Separate composited planes; decorative motion never represents task progress.
struct HologramView: View {
  let session: SessionSnapshot
  let reduceMotion: Bool
  @Environment(\.scenePhase) private var scenePhase
  @State private var assembled = false
  @State private var pointer = CGSize.zero
  private var color: Color { session.status == .idle ? .mint : Color(nsColor: ReactorArtwork.color(session.status.rawValue)) }
  private var animate: Bool { !reduceMotion && scenePhase == .active && [SessionState.working, .waiting].contains(session.status) }
  var body: some View {
    Group {
      if animate {
        TimelineView(.periodic(from: .distantPast, by: session.status == .working ? 0.25 : 0.5)) { context in
          hologram(at: context.date.timeIntervalSinceReferenceDate)
        }
      } else { hologram(at: 0) }
    }
    .onContinuousHover { phase in
      guard !reduceMotion else { return }
      switch phase {
      case .active(let point): pointer = CGSize(width: point.x - 160, height: point.y - 160)
      case .ended: pointer = .zero
      }
    }
    .task(id: session.id) {
      assembled = reduceMotion
      guard !reduceMotion else { return }
      do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
      withAnimation(.spring(response: 0.65, dampingFraction: 0.8)) { assembled = true }
    }
    .onChange(of: reduceMotion) { _, value in if value { assembled = true; pointer = .zero } }
    .accessibilityHidden(true)
  }
  private func hologram(at t: Double) -> some View {
    let phase = t.truncatingRemainder(dividingBy: 4) / 4
    return ZStack {
      Circle().fill(RadialGradient(colors: [color.opacity(0.18), .clear], center: .center, startRadius: 8, endRadius: 145))
        .frame(width: 310, height: 310).scaleEffect(assembled ? 1 : 0.5)
      ForEach(0..<3) { layer in
        ZStack {
          ForEach(0..<5) { segment in
            Circle().trim(from: Double(segment) * 0.2 + 0.012, to: Double(segment) * 0.2 + (segment == layer ? 0.16 : 0.075))
              .stroke(color.opacity(layer == 1 ? 0.65 : 0.3), style: StrokeStyle(lineWidth: layer == 1 ? 2.5 : 1, lineCap: .round))
          }
        }
        .frame(width: CGFloat(285 - layer * 25), height: CGFloat(285 - layer * 25))
        .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 120) * Double(layer == 1 ? -7 : 4 + layer * 3)))
        .rotation3DEffect(.degrees(layer == 1 ? 42 : -22), axis: (x: 1, y: 0.2, z: 0), perspective: 0.45)
        .offset(x: pointer.width * CGFloat(layer + 1) * 0.02, y: CGFloat(layer - 1) * 18 + (assembled ? 0 : CGFloat(layer - 1) * 70))
        .opacity(assembled ? 1 : 0)
      }
      if let image = RobinProviderGlyph.image(provider: session.agentId, state: session.status.rawValue, phase: phase) {
        Image(nsImage: image).resizable().scaledToFit().frame(width: 160, height: 160)
          .shadow(color: color.opacity(0.45), radius: 18, y: 12)
          .overlay {
            if session.status == .working && animate {
              LinearGradient(colors: [.clear, .white.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 40, height: 180).rotationEffect(.degrees(25))
                .offset(x: CGFloat(t.truncatingRemainder(dividingBy: 5) / 5) * 400 - 200)
                .mask(Image(nsImage: image).resizable().scaledToFit())
            }
          }
          .rotation3DEffect(.degrees(Double(pointer.width) * 0.06), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
          .offset(x: pointer.width * 0.025, y: assembled ? (session.status == .waiting ? -12 : CGFloat(sin(phase * .pi * 2)) * 3) : 35)
          .scaleEffect(assembled ? (session.status == .waiting ? 1.04 + 0.025 * sin(phase * .pi * 2) : 1) : 0.75)
          .opacity(assembled ? 1 : 0)
      }
      if session.status == .waiting {
        RoundedRectangle(cornerRadius: 12).trim(from: 0.03, to: 0.97).stroke(color.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [22, 65]))
          .frame(width: 205, height: 205)
      }
      VStack {
        HStack { Text("LIVE STATUS"); Spacer(); Image(systemName: "scope") }
        Spacer()
        HStack { Text(session.agentName.uppercased()); Spacer(); Text(session.status == .idle ? "READY" : session.status.label.uppercased()) }
      }.font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(color.opacity(0.7)).padding(10)
    }.frame(width: 320, height: 320)
      .drawingGroup()
      .opacity([.disconnected, .unknown].contains(session.status) ? 0.4 : 1)
  }

}
