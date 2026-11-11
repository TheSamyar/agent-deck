import DeckCore
import Foundation
import SwiftUI

@MainActor final class RobinMissionJournal: ObservableObject {
  @Published private(set) var current: RobinMission?
  @Published private(set) var storageError = ""
  private let file: URL
  init(file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Deck/robin-mission.json")) {
    self.file = file
    guard FileManager.default.fileExists(atPath: file.path) else { return }
    do {
      current = try JSONDecoder().decode(RobinMission.self, from: Data(contentsOf: file))
      if current?.phase != .done {
        current?.phase = .needsYou; current?.requiresObservation = true
        current?.blocker = "Saved mission restored. Observe current state before resuming."
      }
    } catch { storageError = "Could not read the saved mission. Existing data was preserved." }
  }
  @discardableResult func start(goal: String, project: String, acceptance: [String]) -> UUID {
    current = RobinMission(goal: goal, project: project, acceptance: acceptance); persist(); return current!.id
  }
  var context: String { guard let current, let data = try? JSONEncoder().encode(current) else { return "{}" }; return String(decoding: data, as: UTF8.self) }
  func transition(_ phase: RobinMission.Phase, detail: String) {
    guard current != nil, phase != .done else { return }
    current?.phase = phase; current?.currentStep = String(detail.prefix(1000)); current?.updatedAt = Date(); persist()
  }
  func setPlan(_ steps: [String]) { current?.plan = Array(steps.prefix(32)); persist() }
  func observed() { current?.requiresObservation = false; persist() }
  func recordAction(action: String, succeeded: Bool, verified: Bool, detail: String) {
    guard current != nil else { return }
    current?.actionCount += 1
    current?.evidence.append(.init(name: action, succeeded: succeeded, verified: verified, detail: detail))
    if succeeded { current?.failureSignature = nil; current?.equivalentFailures = 0 }
    else {
      let signature = action + ":" + detail.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
      if current?.failureSignature == signature { current?.equivalentFailures += 1 }
      else { current?.failureSignature = signature; current?.equivalentFailures = 1 }
    }
    current?.updatedAt = Date(); persist()
  }
  func recordCheck(name: String, passed: Bool, detail: String) {
    guard current != nil else { return }
    current?.checks.removeAll { $0.name == name }
    current?.checks.append(.init(name: name, succeeded: passed, verified: true, detail: detail)); persist()
  }
  @discardableResult func canContinue(now: Date = Date()) -> Bool {
    guard let current else { return false }
    if let reason = current.budgetBlocker(now: now) { checkpoint(blocker: reason); return false }
    return true
  }
  func checkpoint(blocker: String) { current?.blocker = blocker; transition(.needsYou, detail: blocker) }
  @discardableResult func finish(summary: String) -> Bool {
    guard let mission = current else { return false }
    guard mission.acceptanceVerified else {
      checkpoint(blocker: "Work was attempted, but acceptance checks have not all passed. " + String(summary.prefix(500))); return false
    }
    current?.phase = .done; current?.currentStep = String(summary.prefix(2000)); current?.blocker = nil; current?.updatedAt = Date(); persist(); return true
  }
  private func persist() {
    guard storageError.isEmpty, let current else { return }
    do {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try JSONEncoder().encode(current).write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } catch { storageError = "Could not save the mission checkpoint." }
  }
}
