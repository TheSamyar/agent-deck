import SwiftUI
import DeckCore

struct RobinNotebookView: View {
  @ObservedObject var store: RobinNotebookStore
  let project: String
  @State private var draft = ""
  @State private var kind = RobinNoteKind.preference
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Project notebook").font(.headline)
      Text(project.isEmpty ? "Select a project to inspect its memory." : project).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      if !store.error.isEmpty { Text(store.error).foregroundStyle(.red) }
      if !project.isEmpty {
        HStack {
          Picker("Remember as", selection: $kind) { ForEach([RobinNoteKind.preference, .goal, .decision, .unfinishedWork], id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 180)
          TextField("Remember for this project", text: $draft)
          Button("Save") { store.record(project: project, kind: kind, text: draft, approved: true); draft = "" }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        ForEach(store.notebook.notes.filter { $0.project == project }.sorted { $0.updatedAt > $1.updatedAt }) { note in
          RobinNoteRow(store: store, note: note)
        }
      }
    }.padding(12)
  }
}
private struct RobinNoteRow: View {
  @ObservedObject var store: RobinNotebookStore
  let note: RobinNote
  @State private var editing = false
  @State private var corrected = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(note.kind.rawValue).font(.caption.bold())
        Text(note.approved ? "User approved" : note.verified ? "Verified evidence" : "Inferred · not an approved preference").font(.caption).foregroundStyle(.secondary)
        Spacer()
        if !note.approved { Button("Approve") { store.approve(note.id) } }
        Button("Correct") { corrected = note.text; editing = true }
        Button("Forget", role: .destructive) { store.forget(note.id) }
      }
      if editing {
        TextField("Correction", text: $corrected, axis: .vertical)
        HStack { Button("Save correction") { store.correct(note.id, text: corrected); editing = false }; Button("Cancel") { editing = false } }
      } else { Text(note.text).font(.callout).textSelection(.enabled) }
    }.padding(10).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
  }
}

struct RobinNotebookBrowser: View {
  @ObservedObject var store: RobinNotebookStore
  let suggestedProject: String
  @State private var selection = ""
  private var projects: [String] { Array(Set(store.notebook.notes.map(\.project) + (suggestedProject.isEmpty ? [] : [suggestedProject]))).sorted() }
  private var current: String { projects.contains(selection) ? selection : projects.contains(suggestedProject) ? suggestedProject : projects.first ?? "" }
  var body: some View {
    VStack(alignment: .leading) {
      if !projects.isEmpty {
        Picker("Notebook project", selection: Binding(get: { current }, set: { selection = $0 })) {
          ForEach(projects, id: \.self) { Text($0).tag($0) }
        }
      }
      RobinNotebookView(store: store, project: current)
    }
  }
}
