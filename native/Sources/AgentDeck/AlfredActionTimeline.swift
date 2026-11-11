import SwiftUI
import DeckCore

struct AlfredActionTimeline: View {
  @ObservedObject var runtime: JarvisRuntime
  var stop: () -> Void
  @State private var expanded = false
  private var events: [AlfredActionEvent] {
    Array((expanded ? runtime.actionEvents : Array(runtime.actionEvents.suffix(5))).reversed())
  }
  var body: some View {
    if !runtime.actionEvents.isEmpty {
      GroupBox("Alfred actions") {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Actual action status · verification is separate from an attempt")
              .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if runtime.actionEvents.contains(where: { $0.state == .running }) {
              Button("Stop", action: stop).help("Cancel Alfred work and audio")
            }
          }
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
              ForEach(events) { event in
                HStack(alignment: .top, spacing: 8) {
                  Image(systemName: symbol(event.state)).foregroundStyle(color(event.state))
                  VStack(alignment: .leading, spacing: 2) {
                    Text(event.purpose).font(.callout.weight(.medium))
                    Text(event.target).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  }
                  Spacer()
                  Text(event.state.rawValue).font(.caption.bold()).foregroundStyle(color(event.state))
                }.accessibilityElement(children: .combine)
              }
            }
          }.frame(maxHeight: expanded ? 260 : 150)
          if runtime.actionEvents.count > 5 {
            Button(expanded ? "Show less" : "Show more (\(runtime.actionEvents.count))") { expanded.toggle() }.font(.caption)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
  private func symbol(_ state: AlfredActionEvent.State) -> String {
    switch state {
    case .running: "arrow.triangle.2.circlepath"
    case .waiting: "hand.raised"
    case .verified: "checkmark.seal"
    case .failed, .blocked: "exclamationmark.triangle"
    case .cancelled: "stop.circle"
    case .attempted: "arrow.up.right.circle"
    }
  }
  private func color(_ state: AlfredActionEvent.State) -> Color {
    switch state {
    case .verified: .green
    case .failed, .blocked: .orange
    case .running: .cyan
    default: .secondary
    }
  }
}
