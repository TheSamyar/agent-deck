import SwiftUI
import DeckCore

struct RobinMissionStatus: View {
  @ObservedObject var journal: RobinMissionJournal
  var body: some View {
    if let mission = journal.current {
      GroupBox("Mission · " + mission.deviceState) {
        VStack(alignment: .leading, spacing: 8) {
          Text(mission.goal).font(.headline).lineLimit(3)
          Text(mission.currentStep).font(.callout)
          Text("\(mission.actionCount) / 32 actions · \(mission.checks.filter(\.succeeded).count) checks passed").font(.caption).foregroundStyle(.secondary)
          if let blocker = mission.blocker { Text(blocker).font(.caption).foregroundStyle(.orange) }
          DisclosureGroup("Evidence") {
            ForEach(Array(mission.evidence.suffix(10).enumerated()), id: \.offset) { _, item in
              Text("\(item.succeeded ? "✓" : "×") \(item.name): \(item.detail)").font(.caption).textSelection(.enabled)
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}
