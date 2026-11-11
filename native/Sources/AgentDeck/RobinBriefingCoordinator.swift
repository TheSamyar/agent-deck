import DeckCore
import Foundation
import SwiftUI

/// Called after a successful refresh. The store owns playback and gives this controller
/// an idle/awake gate, so briefings never create a second microphone or speaker owner.
@MainActor final class RobinBriefingCoordinator: ObservableObject {
  @Published private(set) var report: RobinBriefingReport?
  @Published private(set) var lastBriefingAt: Date?
  private let defaults: UserDefaults
  private let key = "robin.briefing.lastAt"
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    lastBriefingAt = defaults.object(forKey: key) as? Date
  }

  @discardableResult
  func deliver(snapshot: DeckSnapshot, tasks: [SupervisedTask], automatic: Bool, enabled: Bool,
    hour: Int, available: Bool, now: Date = Date(), speak: (String) -> Void) -> Bool {
    let age = now.timeIntervalSince1970 - snapshot.timestamp / 1000
    guard available, snapshot.ok, age.isFinite, (-5...30).contains(age) else { return false }
    guard !automatic || RobinBriefingSchedule.isDue(now: now, lastBriefingAt: lastBriefingAt, enabled: enabled, hour: hour) else { return false }
    let result = RobinBriefing.make(snapshot: snapshot, tasks: tasks, now: now, since: lastBriefingAt)
    // Persist before enqueueing: restarting the app cannot announce this day twice.
    // An explicit on-demand briefing also satisfies today's automatic briefing.
    defaults.set(now, forKey: key)
    lastBriefingAt = now
    report = result
    speak(result.spokenText)
    return true
  }
}
