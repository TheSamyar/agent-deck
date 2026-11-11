import AppKit
import ApplicationServices
import Darwin
import IOKit.hid
import SwiftUI

@MainActor final class MacPermissionMonitor: ObservableObject {
  static let shared = MacPermissionMonitor()
  @Published private(set) var accessibility = AXIsProcessTrusted()
  @Published private(set) var inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
  @Published private(set) var repairing = false
  @Published var message = ""
  private var timer: Timer?

  private init() {
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
  }
  func refresh() {
    let accessibility = AXIsProcessTrusted()
    let input = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    if self.accessibility != accessibility { self.accessibility = accessibility }
    if inputMonitoring != input { inputMonitoring = input }
  }
  func openAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    openPane("Privacy_Accessibility")
  }
  func openInputMonitoring() {
    _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    openPane("Privacy_ListenEvent")
  }
  private func openPane(_ pane: String) {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
  }
  func repairStaleEntries() {
    let alert = NSAlert()
    alert.messageText = "Repair Agent Deck’s permission entries?"
    alert.informativeText = "This removes only Agent Deck’s old Accessibility and Input Monitoring entries. You’ll enable Agent Deck again in System Settings. Other apps are unchanged."
    alert.addButton(withTitle: "Repair and Open Settings")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn,
      let identifier = Bundle.main.bundleIdentifier, identifier == "com.aiagentdeck.app" else { return }
    repairing = true
    Task {
      let succeeded = await Task.detached {
        for service in ["Accessibility", "ListenEvent"] {
          let process = Process()
          process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
          process.arguments = ["reset", service, identifier]
          process.standardOutput = FileHandle.nullDevice
          process.standardError = FileHandle.nullDevice
          do { try process.run(); process.waitUntilExit() }
          catch { return false }
          if process.terminationStatus != 0 { return false }
        }
        return true
      }.value
      repairing = false
      message = succeeded
        ? "Old entries cleared. Enable Agent Deck in both settings, then restart the app."
        : "macOS could not clear an entry. Remove the old Agent Deck entry with – in System Settings, then add this app again."
      refresh()
      openAccessibility()
    }
  }
  func restart() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    // The path is a positional argument, never interpolated into shell code.
    process.arguments = ["-c", "sleep 1\nexec /usr/bin/open -n \"$1\"", "agent-deck-relaunch", Bundle.main.bundlePath]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run(); NSApp.terminate(nil) }
    catch { message = "Could not restart. Quit and reopen Agent Deck from Applications." }
  }
}

struct MacPermissionsView: View {
  @EnvironmentObject private var model: DeckModel
  @ObservedObject private var permissions = MacPermissionMonitor.shared
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("Connect Agent Deck to your Mac").font(.title2.bold())
        Text("Enable Accessibility for window focus and shortcuts, and Input Monitoring for MasterHUB controls.")
          .foregroundStyle(.secondary)
        permissionRow("1. Accessibility", detail: "Focus agent windows and run keyboard shortcuts.",
          granted: permissions.accessibility, action: permissions.openAccessibility)
        permissionRow("2. Input Monitoring", detail: "Receive MasterHUB buttons and roller input.",
          granted: permissions.inputMonitoring, action: permissions.openInputMonitoring)
        if model.message.localizedCaseInsensitiveContains("Automation") {
          GroupBox {
            VStack(alignment: .leading, spacing: 8) {
              Label("Allow window control", systemImage: "macwindow").font(.headline)
              Text("In Automation settings, allow Agent Deck to control System Events and the terminal or editor you use.").font(.callout)
              Button("Open Automation settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
              }
            }.padding(6)
          }
        }
        GroupBox {
          VStack(alignment: .leading, spacing: 10) {
            Text("Already enabled, but still blocked?").font(.headline)
            Text("An older app entry can stop working after an update. Repair the entries, then turn Agent Deck’s switches on again.").font(.callout)
            HStack {
              Button(permissions.repairing ? "Repairing…" : "Repair old permissions…") {
                permissions.repairStaleEntries()
              }.disabled(permissions.repairing)
              Button("Show this app in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
              }
            }
            Text("If you need to add the app manually, drag Agent Deck from Finder into the settings list.")
              .font(.caption).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        if !permissions.message.isEmpty {
          Text(permissions.message).font(.callout).textSelection(.enabled)
        }
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("3. Restart Agent Deck").font(.headline)
            Text("After changing access, restart to reconnect the device.")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Restart Agent Deck") { permissions.restart() }
            .buttonStyle(.borderedProminent).disabled(permissions.repairing)
        }
      }.padding(24)
    }.onAppear {
      permissions.refresh()
      Task { await model.refreshServiceReadiness() }
    }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        permissions.refresh()
        Task { await model.refreshServiceReadiness() }
      }
  }
  private func permissionRow(_ title: String, detail: String, granted: Bool,
    action: @escaping () -> Void) -> some View {
    GroupBox {
      HStack(spacing: 12) {
        Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
          .foregroundStyle(granted ? .green : .orange).font(.title2)
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.headline)
          Text(detail).font(.caption).foregroundStyle(.secondary)
          Text(granted ? "Allowed" : "Needs access").font(.caption.bold())
          if !granted {
            Text("Choose Enable, turn on Agent Deck in System Settings, then return here. Restart Agent Deck after changing access.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button(granted ? "Open settings" : "Enable…", action: action)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
    }
  }
}
