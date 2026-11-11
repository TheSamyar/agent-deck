import SwiftUI
import DeckCore

struct AgentHandoffsView: View {
  @EnvironmentObject private var model: DeckModel
  var body: some View {
    let records = model.snapshot.map(AgentHandoff.records) ?? []
    List {
      if records.isEmpty { ContentUnavailableView("No handoffs yet", systemImage: "checkmark.bubble", description: Text("Verified completions, failures, and input requests appear here.")) }
      ForEach(records) { record in
        HStack {
          Image(systemName: record.state == .waiting ? "hand.raised.fill" : record.state == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .foregroundStyle(record.state == .waiting ? .orange : record.state == .error ? .red : .green)
          VStack(alignment: .leading) {
            Text(record.project).font(.headline)
            Text(record.state.label + " · Session time " + String(Int(record.sessionMilliseconds / 60000)) + " min").font(.caption).foregroundStyle(.secondary)
            Text("Review results in the original agent. No artifact was supplied by this integration.").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Open agent") { model.perform(.init(action: "focus", sessionId: record.sessionID)) }.disabled(!record.canFocus)
          if record.state == .waiting { Button("Review request") { model.reviewHandoff(record) } }
        }.padding(.vertical, 8)
      }
    }.navigationTitle("Handoffs")
  }
}
