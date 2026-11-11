import AppKit
import ApplicationServices
import DeckCore
import SwiftUI

struct SetupView: View {
  @EnvironmentObject var model: DeckModel
  @Environment(\.dismiss) var dismiss
  @State private var step = 0
  @AppStorage("setupDevice") private var device = "MasterHUB"
  @State private var accessibilityGranted = AXIsProcessTrusted()
  @State private var physicalPressVerified = false
  @State private var editor = false
  @State private var checkedPermissions = false
  private var observedSessions: [SessionSnapshot] {
    (model.snapshot?.sessions.values.map { $0 } ?? []).filter {
      $0.status != .disconnected && $0.status != .unknown
    }
  }
  private var focusSession: SessionSnapshot? {
    observedSessions.filter { $0.capabilities.focus }.sorted { $0.id < $1.id }.first
  }
  private var vendorPluginInstalled: Bool {
    let relative = device == "MX Creative Console"
      ? "Library/Application Support/Logi/LogiPluginService/Plugins/AiAgentDeck/AiAgentDeckPlugin.dll"
      : ".local/share/Loupedeck/Plugins/AiAgentDeck/AiAgentDeckPlugin.dll"
    return FileManager.default.fileExists(atPath:
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relative).path)
  }
  private var title: String {
    ["Choose your control surface", "Connect your agents", "Enable window focus", "Verify one real press"][step]
  }
  private func connectionRow(_ agent: String) -> some View {
    let configuration = model.integrationConfiguration[agent] ?? .missing
    let sessions = observedSessions.filter { $0.agentId == agent }
    return HStack(alignment: .top, spacing: 12) {
      Toggle(agentName(agent), isOn: Binding(
        get: { model.preferences.enabledAgents.contains(agent) },
        set: { enabled in
          model.savePreferences { preferences in
            preferences.enabledAgents.removeAll { $0 == agent }
            if enabled { preferences.enabledAgents.append(agent) }
          }
        })).disabled(model.installing || !model.connected)
      Spacer()
      VStack(alignment: .trailing, spacing: 3) {
        Label(configuration.label, systemImage: configuration == .ready ? "checkmark.circle.fill" : "circle.dashed")
          .font(.caption.weight(.medium))
          .foregroundStyle(configuration == .ready ? Color.green : Color.secondary)
        Text(sessions.isEmpty ? "No live session" : "\(sessions.count) observed session\(sessions.count == 1 ? "" : "s")")
          .font(.caption).foregroundStyle(.secondary)
      }
    }.padding(12)
      .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
      .accessibilityElement(children: .contain)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Label("SETUP", systemImage: "square.grid.3x3.fill").font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Text("\(step + 1) of 4").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }
      if step == 0 { Button("Explore without hardware…") { model.openDemo() } }
      ProgressView(value: Double(step + 1), total: 4).accessibilityLabel("Setup step \(step + 1) of 4")
      Text(title).font(.largeTitle.weight(.semibold))
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          switch step {
          case 0:
            Picker("Device", selection: $device) {
              Text("MasterHUB").tag("MasterHUB")
              Text("MX Creative Console").tag("MX Creative Console")
              Text("Loupedeck / Razer").tag("Loupedeck / Razer")
            }.pickerStyle(.segmented)
            if device == "MasterHUB" {
              Label("Built-in native MasterHUB support", systemImage: "checkmark.circle")
              Text("Your keypad, rollers, three dials, and screen dial are configured in the MasterHUB workspace. Keep your existing USB connection.")
              Button("Open MasterHUB workspace") {
                model.section = "MasterHUB"; model.showSetup = false; dismiss()
              }
              Text("Use Check controls to verify physical input without running actions.").font(.caption).foregroundStyle(.secondary)
            } else {
              Text(device == "MX Creative Console"
                ? "Connect your keypad and keep Logi Options+ running. Agent Deck installs an AI Agents page through its plugin service."
                : "Connect your controller and keep its Loupedeck application running.")
              Label(vendorPluginInstalled ? "Keypad plugin is installed" : "Keypad plugin will be installed in the next step",
                systemImage: vendorPluginInstalled ? "checkmark.circle" : "puzzlepiece.extension")
            }
          case 1:
            Text("Choose your agents. Hooks installed and live sessions are separate checks; an installed hook does not mean an agent is running.")
              .foregroundStyle(.secondary)
            ForEach(["claude", "codex", "cursor", "gemini", "antigravity"], id: \.self) { connectionRow($0) }
            Text("Codex: request controls require a session started from Agent Deck. Existing notify commands are preserved. Antigravity’s native adapter is experimental.")
              .font(.caption).foregroundStyle(.secondary)
            Toggle("Include Cursor terminal bridge", isOn: $editor).disabled(model.installing)
            Text("After installation, reload Cursor windows when convenient. Working terminals are not reloaded for you.")
              .font(.caption).foregroundStyle(.secondary)
            HStack {
              Button(model.installing ? "Installing…" : "Install selected integrations") {
                model.installIntegrations(editor: editor)
              }.disabled(model.installing || !model.connected || model.preferences.enabledAgents.isEmpty)
              Button("Refresh checks") { model.refreshIntegrationReadiness() }.disabled(model.installing)
              if model.installing { ProgressView().controlSize(.small) }
            }
            if !model.installationMessage.isEmpty {
              Text(model.installationMessage).font(.caption).textSelection(.enabled)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
          case 2:
            Label(accessibilityGranted ? "App Accessibility check passed" : "App Accessibility access is missing",
              systemImage: accessibilityGranted ? "checkmark.circle.fill" : "hand.raised")
              .foregroundStyle(accessibilityGranted ? .green : .orange)
            Label(model.serviceAccessibilityGranted == true ? "Mac window controls connected"
              : model.serviceAccessibilityGranted == false ? "Mac window controls need app access" : "Connecting Mac window controls…",
              systemImage: model.serviceAccessibilityGranted == true ? "checkmark.circle.fill" : "hand.raised")
            Text("Window discovery and focus run inside Agent Deck. Enable the app’s Accessibility entry; the background service does not need its own permission.")
              .font(.caption).foregroundStyle(.secondary)
            Text("Window focus needs Accessibility access. macOS may also ask to control the terminal or editor you choose. Approval hooks respond directly to their original request.")
            Text("The switch in System Settings can outlive an app update. This check uses the running app’s permission; the final focus test checks the app’s ability to open your session.")
              .font(.caption).foregroundStyle(.secondary)
            HStack {
              Button("Open permission settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
              }
              Button("Recheck access") {
                accessibilityGranted = AXIsProcessTrusted()
                checkedPermissions = true
                model.refreshIntegrationReadiness()
              }
            }
            if checkedPermissions && !accessibilityGranted {
              Text("Enable Agent Deck in Accessibility (called Device Control and Data Access on some macOS versions), return here, and recheck. If it remains denied after an update, remove and re-add the installed app, then reopen it.")
                .font(.caption).foregroundStyle(.secondary)
            }
          default:
            Label(model.connected ? "Local service connected" : "Local service disconnected",
              systemImage: model.connected ? "checkmark.circle.fill" : "wifi.slash")
              .foregroundStyle(model.connected ? .green : .orange)
            Text("\(observedSessions.count) observed session\(observedSessions.count == 1 ? "" : "s"). Disconnected history is excluded.")
            if let session = focusSession {
              Text("First, test the app connection. Then press the same project tile on your physical keypad and confirm it opens the correct session.")
              Button("Test focus: \(session.workspace)") {
                physicalPressVerified = false
                model.perform(.init(action: "focus", sessionId: session.id))
              }.disabled(!model.connected || model.actionInFlight || model.serviceAccessibilityGranted != true)
              if model.actionInFlight { ProgressView("Opening exact session…") }
            } else {
              Text("Start a selected agent in a project. If you installed hooks just now, start a new CLI session. If the session is in Cursor, reload its window after installing the bridge. A session must support focus before you can test it here.")
                .foregroundStyle(.secondary)
            }
            if !model.message.isEmpty { Text(model.message).font(.callout).textSelection(.enabled) }
            Toggle("My physical key opened the correct session", isOn: $physicalPressVerified)
              .disabled(!model.connected || focusSession == nil)
            Text("This is your physical verification, not automatic device certification. No hardware yet? Choose Finish later and explore Demo from Keypad.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
      }
      Divider()
      HStack {
        Button("Finish later") { model.showSetup = false; dismiss() }.disabled(model.installing)
        if step > 0 { Button("Back") { step -= 1 }.disabled(model.installing) }
        Spacer()
        Button(step == 3 ? "Finish setup" : "Continue") {
          if step == 3 {
            UserDefaults.standard.set(true, forKey: "setupCompleted")
            model.showSetup = false
            dismiss()
          } else { step += 1 }
        }.buttonStyle(.borderedProminent)
          .disabled(model.installing || (step == 3 && (!physicalPressVerified || !model.connected || focusSession == nil)))
      }
    }.padding(30).frame(width: 640, height: 680)
      .onAppear { model.refreshIntegrationReadiness(); accessibilityGranted = AXIsProcessTrusted() }
      .onChange(of: step) { _, _ in model.refreshIntegrationReadiness() }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        accessibilityGranted = AXIsProcessTrusted()
        model.refreshIntegrationReadiness()
      }
      .onChange(of: model.connected) { _, connected in if !connected { physicalPressVerified = false } }
      .onChange(of: focusSession?.id) { _, _ in physicalPressVerified = false }
      .onChange(of: device) { _, _ in physicalPressVerified = false }
      .onChange(of: model.snapshot?.instanceId) { _, _ in physicalPressVerified = false }
  }
}
