import DeckCore
import Foundation

/// The local service operations used by Alfred's desktop runtime. These are
/// application capabilities, not permission grants; the host and service must
/// still apply their existing authorization and exact-task checks.
public enum AlfredAgentServiceRoute: String, CaseIterable, Sendable {
  case tasks
  case start
  case continueTask = "continue"
  case browser
  case browserCommand = "browser-command"
}

/// A desktop host supplies observations and authenticated local-agent transport.
/// Alfred does not need the host's window model, hardware, updater, or credentials.
/// Implementations own authentication; callers never receive the service token.
@MainActor public protocol AlfredAgentService: AnyObject {
  var snapshot: DeckSnapshot? { get }
  func alfredRequest(_ route: AlfredAgentServiceRoute, body: [String: Any]?) async throws -> Data
}

public extension AlfredAgentService {
  func alfredRequest(_ route: AlfredAgentServiceRoute) async throws -> Data {
    try await alfredRequest(route, body: nil)
  }
}
