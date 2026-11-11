import AlfredIntegration
import Foundation

/// Agent Deck keeps local service credentials and connection handling behind the
/// Alfred capability boundary. The assistant receives only a read-only snapshot
/// and the explicitly supported service operations.
extension DeckModel: AlfredAgentService {
  func alfredRequest(_ route: AlfredAgentServiceRoute, body: [String: Any]?) async throws -> Data {
    try await supervisorRequest(route.rawValue, body: body)
  }
}
