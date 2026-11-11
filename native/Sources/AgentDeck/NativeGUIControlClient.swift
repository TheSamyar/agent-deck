import AppKit
import ApplicationServices
import DeckCore
import Foundation

@MainActor final class NativeGUIControlClient {
  let clientID = UUID().uuidString
  private let controls = MacControl()
  private var replies: [String: NativeGUIControlReply] = [:]
  private var completed: [String: NativeGUIControlReply] = [:]
  private var worker: Task<Void, Never>?
  private struct ControlFailure: Error {}
  func start(runtime: URL) {
    guard worker == nil else { return }
    worker = Task {
      while !Task.isCancelled {
        do {
          let data = try Data(contentsOf: runtime.appendingPathComponent("connection.json"))
          guard let endpoint = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let port = endpoint["port"] as? Int, let token = endpoint["token"] as? String,
            (1...65535).contains(port) else { throw URLError(.badServerResponse) }
          let sending = Array(replies.values.prefix(16))
          var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/gui/control")!)
          request.httpMethod = "POST"
          request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.httpBody = try JSONEncoder().encode(NativeGUIControlPoll(clientID: clientID,
            accessibilityGranted: AXIsProcessTrusted(), replies: sending))
          request.timeoutInterval = 3
          let (body, response) = try await URLSession.shared.data(for: request)
          guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
          for reply in sending { replies.removeValue(forKey: reply.id) }
          let delivery = try JSONDecoder().decode(NativeGUIControlDelivery.self, from: body)
          for command in delivery.requests where command.expiresAt > DeckClock.now {
            if let old = completed[command.id] { replies[command.id] = old; continue }
            let reply: NativeGUIControlReply
            switch command.kind {
            case .focus:
              if let session = command.session, AXIsProcessTrusted() {
                reply = .init(id: command.id, result: await controls.focus(session))
              } else { reply = .init(id: command.id, result: .failure("Enable Accessibility for Agent Deck in Mac Permissions.")) }
            case .scanWindows:
              do {
                guard AXIsProcessTrusted() else { throw ControlFailure() }
                let titles = try await controls.cursorWindows()
                reply = .init(id: command.id, windowTitles: titles)
              } catch {
                reply = .init(id: command.id, result: .failure("Window discovery needs Agent Deck’s Accessibility and Automation access. Open Mac Permissions to check them."))
              }
            }
            completed[command.id] = reply; replies[command.id] = reply
            if completed.count > 128 { completed = [command.id: reply] }
          }
        } catch { /* The authenticated app connection retries after service restarts. */ }
        try? await Task.sleep(for: .milliseconds(250))
      }
    }
  }
}
