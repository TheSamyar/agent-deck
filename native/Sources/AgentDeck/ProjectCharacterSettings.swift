import AppKit
import SwiftUI
import DeckCore

struct ProjectCharacterSettings: View {
  @EnvironmentObject private var model: DeckModel
  @State private var selected = ""
  @State private var character = 0
  @State private var color = 0
  private var projects: [SessionSnapshot] {
    var seen = Set<String>()
    return model.allSessions.filter { seen.insert($0.projectKey).inserted }.sorted { $0.workspace < $1.workspace }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if projects.isEmpty { Text("Projects appear after their first agent session.").foregroundStyle(.secondary) }
      else {
        Picker("Project", selection: $selected) { ForEach(projects) { Text($0.workspace).tag($0.projectKey) } }
          .onChange(of: selected) { _, value in load(value) }
        Text("Agent identity follows its provider logo.").font(.caption).foregroundStyle(.secondary)
        Picker("Project color", selection: $color) { ForEach(0..<4) { Text(AgentVisualStyle.colors[$0]).tag($0) } }
          .onChange(of: color) { _, _ in save() }
        HStack {
          ForEach([SessionState.working, .waiting, .done, .error], id: \.self) { state in
            VStack {
              if let data = MasterHUBArtwork.jpeg(title: projects.first { $0.projectKey == selected }?.workspace ?? "Project", subtitle: "", state: state.rawValue, size: 72, symbol: "gearshape.2", characterProject: selected, agentId: projects.first { $0.projectKey == selected }?.agentId ?? ""), let image = MasterHUBPreviewImage.image(data) {
                Image(nsImage: image).resizable().frame(width: 72,height: 72)
              }
              Text(state.label).font(.caption)
            }
          }
        }.accessibilityLabel("Provider previews for working, needs input, finished, and error")
      }
    }.onAppear { if selected.isEmpty, let first = projects.first { selected = first.projectKey; load(selected) } }
  }
  private func load(_ key: String) {
    let baseline = AgentCharacter(project: key, state: .idle)
    character = baseline.variant; color = baseline.color
  }
  private func save() {
    guard !selected.isEmpty else { return }
    AgentVisualStyle(character: character, color: color).save(project: selected)
    model.refreshAppearance()
  }
}
