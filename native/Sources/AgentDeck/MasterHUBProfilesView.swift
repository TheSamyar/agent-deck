import AppKit
import DeckCore
import SwiftUI
import UniformTypeIdentifiers

struct MasterHUBProfilesView: View {
  @EnvironmentObject private var model: DeckModel
  @State private var name = ""
  @State private var selected = ""
  @State private var bundleID = ""
  @State private var replace: MasterHUBApplicationProfile?
  @State private var remove: MasterHUBApplicationProfile?
  @State private var assignment: (id: UUID, bundleID: String)?
  @State private var importData: Data?
  @State private var importCount = 0
  @State private var fileError = ""
  private var selection: MasterHUBApplicationProfile? { model.masterhubProfiles.profiles.first { $0.id.uuidString == selected } }
  var body: some View {
    Section("Automatic app profiles") {
      LabeledContent("Active profile", value: model.activeMasterHUBProfileName)
      Toggle("Switch profiles for the active app", isOn: Binding(
        get: { model.masterhubProfiles.automaticEnabled }, set: { model.setAutomaticMasterHUBProfiles($0) }))
      Text("Profiles change Mac-page keys and dial assignments; the current page stays selected. Switching waits during checks, editing, held controls and pending agent decisions.")
        .font(.caption).foregroundStyle(.secondary)
      Text(model.masterhubProfileStatus).font(.caption).textSelection(.enabled)
      HStack {
        TextField("New profile name", text: $name)
        Button("Save current setup") {
          if let id = model.captureMasterHUBProfile(name: name) { selected = id.uuidString; name = "" }
        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      Text("Save a profile, use it, then Customize in MasterHUB. Apply updates that named profile while preserving Default.")
        .font(.caption).foregroundStyle(.secondary)
      Picker("Saved profile", selection: $selected) {
        Text("Default").tag("")
        ForEach(model.masterhubProfiles.profiles) { profile in Text(profile.name).tag(profile.id.uuidString) }
      }
      HStack {
        Button("Use selected · pause auto") { model.selectMasterHUBProfile(selection?.id) }
        Button("Use Default · pause auto") { model.selectMasterHUBProfile(nil) }
      }
      if let profile = selection {
        LabeledContent("Last active app", value: model.profileFrontmostName)
        if let current = model.profileFrontmostBundleID {
          Button("Assign \(model.profileFrontmostName) to \(profile.name)") { assign(profile.id, to: current) }
        }
        HStack {
          TextField("Exact bundle ID, e.g. com.apple.Terminal", text: $bundleID)
          Button("Assign app") { assign(profile.id, to: bundleID.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .disabled(!MasterHUBProfileLibrary.validBundleID(bundleID.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let assigned = model.masterhubProfiles.assignments.filter { $0.value == profile.id }.keys.sorted()
        Text(assigned.isEmpty ? "No apps assigned yet." : "Assigned: " + assigned.joined(separator: ", "))
          .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        HStack {
          Button("Replace saved snapshot…") { replace = profile }
          Button("Delete profile…", role: .destructive) { remove = profile }
        }
      }
      Button("Import recovered profiles…") { chooseImport() }
      if !fileError.isEmpty { Text(fileError).font(.caption).foregroundStyle(.red) }
    }
    .onAppear { selected = model.activeMasterHUBProfileID?.uuidString ?? "" }
    .onChange(of: model.activeMasterHUBProfileID) { _, id in selected = id?.uuidString ?? "" }
    .confirmationDialog("Replace saved profile?", isPresented: Binding(get: { replace != nil }, set: { if !$0 { replace = nil } })) {
      Button("Replace \(replace?.name ?? "profile")") { if let profile = replace { model.replaceMasterHUBProfile(profile.id) }; replace = nil }
    } message: { Text("Replace this saved snapshot with the currently active assignments. Other profiles and Default stay unchanged.") }
    .confirmationDialog("Delete profile?", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } })) {
      Button("Delete \(remove?.name ?? "profile")", role: .destructive) { if let profile = remove { model.deleteMasterHUBProfile(profile.id) }; remove = nil; selected = "" }
    } message: { Text("Its app assignments will be removed. Default and other profiles stay unchanged.") }
    .confirmationDialog("Replace this app assignment?", isPresented: Binding(get: { assignment != nil }, set: { if !$0 { assignment = nil } })) {
      Button("Assign to selected profile") { if let value = assignment { model.assignMasterHUBProfile(value.id, bundleID: value.bundleID) }; assignment = nil }
    } message: { Text(assignment?.bundleID ?? "") }
    .confirmationDialog("Import \(importCount) recovered profiles?", isPresented: Binding(get: { importData != nil }, set: { if !$0 { importData = nil } })) {
      Button("Import profiles") { if let data = importData { model.importMasterHUBProfiles(data) }; importData = nil }
    } message: { Text("Existing values are preserved. Conflicting snapshots become separately named recovered profiles; only missing app assignments are added. Automatic switching stays off. Review the recovered profiles before enabling them.") }
  }
  private func assign(_ id: UUID, to bundle: String) {
    if let existing = model.masterhubProfiles.assignments[bundle], existing != id { assignment = (id, bundle) }
    else { model.assignMasterHUBProfile(id, bundleID: bundle) }
  }
  private func chooseImport() {
    let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512 * 1024 else { throw MasterHUBProfileFailure("Choose a profile library smaller than 512 KB.") }
      let data = try Data(contentsOf: url), library = try MasterHUBProfileLibrary.decodeImport(data)
      importData = data; importCount = library.profiles.count; fileError = ""
    } catch { fileError = error.localizedDescription }
  }
}
