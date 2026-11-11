import DeckCore
import SwiftUI

struct AlfredSkillsView: View {
  @ObservedObject var store: SupervisorStore
  @ObservedObject private var skills: AlfredSkillStore
  @State private var editing: AlfredSkill?
  @State private var deleting: AlfredSkill?
  init(store: SupervisorStore) { self.store = store; skills = store.skills }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text("Reusable skills").font(.title2.bold())
          Spacer()
          Button("New skill") { editing = .init(name: "", instructions: "") }
        }
        Text("Save a repeatable goal. Skills use Alfred's existing permissions and executor; saving a skill grants no new access.").font(.caption).foregroundStyle(.secondary)
        ForEach(skills.skills) { skill in
          GroupBox(skill.name) {
            VStack(alignment: .leading, spacing: 8) {
              Text(skill.instructions).lineLimit(4)
              Text(skill.project.map { "Project: " + $0 } ?? "Scope: current selected project").font(.caption).foregroundStyle(.secondary)
              Text("Say: run skill " + skill.name).font(.caption)
              if !skill.aliases.isEmpty { Text("Aliases: " + skill.aliases.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
              HStack {
                Button("Run") { Task { await store.runSkill(skill) } }.disabled(store.busy)
                Button("Edit") { editing = skill }
                Spacer()
                Button("Delete", role: .destructive) { deleting = skill }
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        if skills.skills.isEmpty { Text("No saved skills. Create a reusable goal with New skill.") }
        if let questions = store.memory.deferredConversationQuestions, !questions.isEmpty {
          GroupBox("Paused questions") {
            VStack(alignment: .leading, spacing: 8) {
              ForEach(Array(questions.enumerated()).suffix(5).reversed(), id: \.offset) { index, question in
                HStack(alignment: .top) {
                  VStack(alignment: .leading) {
                    Text(question.question).lineLimit(2)
                    Text(question.project.isEmpty ? "Personal conversation" : question.project).font(.caption).foregroundStyle(.secondary)
                  }
                  Spacer()
                  Button("Resume") { store.resumeDeferredQuestion(index) }.disabled(store.busy)
                }
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        if !skills.error.isEmpty { Text(skills.error).foregroundStyle(.red).textSelection(.enabled) }
      }.padding()
    }
    .sheet(item: $editing) { skill in AlfredSkillEditor(skill: skill, skills: skills) }
    .alert("Delete saved skill?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
      Button("Cancel", role: .cancel) { deleting = nil }
      Button("Delete", role: .destructive) { if let deleting { skills.remove(deleting) }; deleting = nil }
    } message: { Text("This removes the saved template. It does not change running tasks or app permissions.") }
  }
}

private struct AlfredSkillEditor: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var skills: AlfredSkillStore
  @State private var draft: AlfredSkill
  @State private var aliases: String
  @State private var project: String
  init(skill: AlfredSkill, skills: AlfredSkillStore) {
    self.skills = skills; _draft = State(initialValue: skill)
    _aliases = State(initialValue: skill.aliases.joined(separator: "\n")); _project = State(initialValue: skill.project ?? "")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Save a skill").font(.title2.bold())
      TextField("Skill name", text: $draft.name)
      Text("Instructions").font(.headline)
      TextEditor(text: $draft.instructions).frame(minHeight: 130).border(.secondary.opacity(0.3))
      TextField("Project folder (optional absolute path)", text: $project)
      Text("An empty folder uses the selected project. A saved path still needs normal project and Codex-sharing approval.").font(.caption).foregroundStyle(.secondary)
      Text("Exact voice aliases · one per line").font(.headline)
      TextEditor(text: $aliases).frame(height: 65).border(.secondary.opacity(0.3))
      if !skills.error.isEmpty { Text(skills.error).font(.caption).foregroundStyle(.red) }
      HStack {
        Button("Cancel") { dismiss() }
        Spacer()
        Button("Save") {
          draft.aliases = aliases.components(separatedBy: .newlines); draft.project = project
          if skills.save(draft) { dismiss() }
        }.keyboardShortcut(.defaultAction)
      }
    }.padding(22).frame(width: 560)
  }
}
