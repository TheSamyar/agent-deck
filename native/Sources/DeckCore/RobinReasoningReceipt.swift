import Foundation

/// An application-produced routing record. A selected brain is not evidence it answered.
public struct RobinReasoningReceipt: Codable, Equatable, Identifiable, Sendable {
  public enum Outcome: String, Codable, Sendable { case success, blocked, failed, cancelled, scripted }
  public var id: UUID
  public var selectedModelID: String
  public var actualModelID: String?
  public var outcome: Outcome
  public var durationMilliseconds: Double
  public var usageRecordID: UUID?
  public init(id: UUID = UUID(), selectedModelID: String, actualModelID: String? = nil,
    outcome: Outcome, durationMilliseconds: Double = 0, usageRecordID: UUID? = nil) {
    self.id = id; self.selectedModelID = selectedModelID; self.actualModelID = actualModelID
    self.outcome = outcome; self.durationMilliseconds = durationMilliseconds; self.usageRecordID = usageRecordID
  }
  public var summary: String {
    if outcome == .scripted { return "Built-in action · no model used" }
    let selected = RobinModelCatalog.model(selectedModelID)?.name ?? selectedModelID
    guard outcome == .success, let actualModelID else { return selected + " · " + outcome.rawValue }
    let actual = RobinModelCatalog.model(actualModelID)?.name ?? actualModelID
    return actual + " · answered in " + String(format: "%.1f s", durationMilliseconds / 1000)
  }
}
