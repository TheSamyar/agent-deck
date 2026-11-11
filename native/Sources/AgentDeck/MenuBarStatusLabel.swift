import SwiftUI
import AppKit

/// Snapshot and device updates must not redraw the menu bar when attention is unchanged.
struct MenuBarStatusLabel: View, Equatable {
  let waitingCount: Int
  var flash = false

  var body: some View {
    Image(systemName: waitingCount > 0 ? "circle.badge.exclamationmark.fill" : "square.grid.2x2")
      .symbolEffect(.pulse, options: .repeat(3), isActive: flash)
    if waitingCount > 0 { Text("\(waitingCount)") }
  }
}

/// Hardware animation and session telemetry do not change this projection.
@MainActor final class MenuBarAttentionState: ObservableObject {
  @Published private(set) var waitingCount = 0
  @Published private(set) var flash = false
  /// Set `attention.soundEnabled` to false in UserDefaults to silence the cue (default on).
  func update(waitingCount: Int) {
    guard self.waitingCount != waitingCount else { return }
    let started = self.waitingCount == 0 && waitingCount > 0
    self.waitingCount = waitingCount
    guard started else { return }
    if UserDefaults.standard.object(forKey: "attention.soundEnabled") as? Bool ?? true { NSSound(named: "Glass")?.play() }
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      flash = true
      Task { try? await Task.sleep(nanoseconds: 3_000_000_000); flash = false }
    }
  }
}

struct ObservedMenuBarStatusLabel: View {
  @ObservedObject var attention: MenuBarAttentionState
  var body: some View {
    MenuBarStatusLabel(waitingCount: attention.waitingCount, flash: attention.flash).equatable()
  }
}
