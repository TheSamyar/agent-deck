import AppKit
import SwiftUI
import DeckCore

/// Official CLI sign-ins stay owned by each vendor. No credential data enters the UI.
struct RobinSubscriptionConnection: Identifiable {
  let id: String
  let name: String
  let login: String
  let setupURL: String
  static let all: [Self] = [
    .init(id: "chatgpt", name: "Codex · ChatGPT", login: "codex login", setupURL: "https://developers.openai.com/codex/cli/"),
    .init(id: "claude-subscription", name: "Claude Code", login: "claude auth login", setupURL: "https://code.claude.com/docs/en/quickstart"),
    .init(id: "gemini-subscription", name: "Gemini · Antigravity CLI", login: "agy", setupURL: "https://antigravity.google/docs/install"),
    .init(id: "cursor-subscription", name: "Cursor CLI", login: "agent login", setupURL: "https://cursor.com/docs/cli/installation")
  ]
  static func contains(_ providerID: String) -> Bool { all.contains { $0.id == providerID } }
  func nextStep(for state: String?) -> String {
    switch state {
    case "missing": return "Open Install / setup, install the CLI, then run \(login) in Terminal. Return here and choose Check sign-ins."
    case "signInRequired": return "Copy the sign-in command, run it in Terminal, and finish the vendor’s sign-in. Return here and choose Check sign-ins."
    case "unsupported", "unverified": return "Open Install / setup to check the supported CLI setup. Run \(login) in Terminal, then choose Check sign-ins."
    case "connected": return ["cursor-subscription", "gemini-subscription"].contains(id)
      ? "Ready for supervised tasks. This connection cannot be selected as a planning brain."
      : "Ready to select Use as brain. Your next request checks model access and remaining quota."
    default: return "Choose Check sign-ins to find your next setup step."
    }
  }
}

@MainActor final class RobinSubscriptionConnections: ObservableObject {
  struct Status: Sendable { let state: String; let message: String; var planningSupported: Bool = false }
  @Published var statuses: [String: Status] = [:]
  @Published private(set) var checking = false
  func refresh() async {
    guard !checking else { return }
    checking = true
    defer { checking = false }
    for connection in RobinSubscriptionConnection.all {
      let result = await Task.detached { Self.check(connection.id) }.value
      statuses[connection.id] = result
    }
  }
  nonisolated private static func check(_ provider: String) -> Status {
    let bundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Jarvis/subscription-planner.py")
    let debug = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Jarvis/subscription-planner.py")
    let helper = FileManager.default.fileExists(atPath: bundle.path) ? bundle : debug
    guard FileManager.default.fileExists(atPath: helper.path) else { return .init(state: "unverified", message: "Connection checker unavailable. Rebuild Agent Deck.") }
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [helper.path, "--status", provider]
    process.standardOutput = output; process.standardError = FileHandle.nullDevice
    // The helper bounds its status calls and returns only sanitized connection metadata.
    do {
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard data.count < 16_384,
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let state = value["state"] as? String, let message = value["message"] as? String,
        ["connected", "signInRequired", "missing", "unverified", "unsupported"].contains(state)
      else { return .init(state: "unverified", message: "Could not verify subscription sign-in.") }
      return .init(state: state, message: String(message.prefix(300)), planningSupported: value["planningSupported"] as? Bool ?? false)
    } catch { return .init(state: "unverified", message: "Could not start the connection check.") }
  }
}

struct RobinSubscriptionConnectionsPanel: View {
  @ObservedObject var store: SupervisorStore
  @StateObject private var connections = RobinSubscriptionConnections()
  @State private var copied = ""
  var body: some View {
    GroupBox("Subscription connections") {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Subscription only · block API billing routes", isOn: Binding(get: { store.configuration.robinSubscriptionOnly == true }, set: { enabled in
          store.configuration.robinSubscriptionOnly = enabled
          if enabled {
            store.configuration.backend = .local
            if let model = RobinModelCatalog.model(store.selectedReasoningModelID), model.providerID != "local", !["chatgpt", "claude-subscription"].contains(model.providerID) { store.configuration.robinProviderID = "chatgpt" }
          }
        }))
        Text("Use your own official CLI sign-ins. Alfred never copies tokens, buys credits, or switches to an API key. Vendor plan limits and existing extra-usage settings still apply.").font(.caption).foregroundStyle(.secondary)
        ForEach(RobinSubscriptionConnection.all) { connection in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(connection.name).font(.headline)
              Spacer()
              let status = connections.statuses[connection.id]
              Label(status?.state == "connected" ? "Signed in" : status?.state == "missing" ? "Install CLI" : status?.state == "signInRequired" ? "Sign in" : status?.state == "unsupported" ? "Unavailable" : "Not verified", systemImage: status?.state == "connected" ? "checkmark.circle.fill" : "circle.dashed")
                .font(.caption).foregroundStyle(status?.state == "connected" ? Color.green : Color.secondary)
            }
            Text(connections.statuses[connection.id]?.message ?? "Check sign-ins to verify this connection.").font(.caption).foregroundStyle(.secondary)
            Text(connection.nextStep(for: connections.statuses[connection.id]?.state))
              .font(.caption).textSelection(.enabled)
            if connection.id == "gemini-subscription" { Text("Supervised task agent through Antigravity CLI (agy). Choose personal Google sign-in. Alfred planning stays disabled because this CLI cannot enforce no-tools isolation.").font(.caption).foregroundStyle(.secondary) }
            if connection.id == "cursor-subscription" { Text("Supervised task agent only. Alfred planning stays disabled until the CLI can enforce no-tools isolation.").font(.caption).foregroundStyle(.secondary) }
            HStack {
              Button(copied == connection.id ? "Copied sign-in command" : "Copy sign-in command") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(connection.login, forType: .string); copied = connection.id
              }
              Link("Install / setup", destination: URL(string: connection.setupURL)!)
              Button(["cursor-subscription", "gemini-subscription"].contains(connection.id) ? "Task agent only" : store.selectedReasoningModelID == connection.id ? "Selected brain" : "Use as brain") {
                store.configuration.robinProviderID = connection.id
                store.configuration.robinHybridEnabled = true
                store.configuration.jarvisEnabled = true
                store.providerKeyInput = ""; store.providerSetupStatus = ""
              }.disabled(connections.checking || connections.statuses[connection.id]?.state != "connected" || connections.statuses[connection.id]?.planningSupported != true)
            }.font(.caption)
          }
        }
        HStack {
          Button(connections.checking ? "Checking sign-ins…" : "Check sign-ins") { Task { await connections.refresh() } }.disabled(connections.checking)
          Button("Open Terminal") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
          }
        }
        Text("Run the copied command in Terminal and finish the vendor's browser sign-in, then check again. Signed in does not prove remaining quota or model access; the next successful request verifies those.").font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.task { await connections.refresh() }
  }
}
