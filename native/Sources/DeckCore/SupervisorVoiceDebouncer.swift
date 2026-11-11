import Foundation

/// Owns only the silence countdown, never the submitted model request.
@MainActor public final class SupervisorVoiceDebouncer {
  private var pending: Task<Void, Never>?
  public init() {}
  public func schedule(delay: Duration = .milliseconds(1200), action: @escaping @MainActor @Sendable () async -> Void) {
    pending?.cancel()
    pending = Task {
      do { try await Task.sleep(for: delay) } catch { return }
      guard !Task.isCancelled else { return }
      // Sending stops the silence timer. Release it before submitting so that
      // stopping the timer cannot cancel the request executing in this task.
      pending = nil
      await action()
    }
  }
  public func cancel() { pending?.cancel(); pending = nil }
}
