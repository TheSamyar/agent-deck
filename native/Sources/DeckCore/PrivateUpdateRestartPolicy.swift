import Foundation

/// Shared fail-closed rules for update restarts and startup recovery markers.
public enum PrivateUpdateRestartPolicy {
  /// `processIsAlive` must also return true when an owned process cannot safely be ruled out.
  public static func canRestart(
    connected: Bool,
    pendingRequestCount: Int,
    busy: Bool,
    tasks: [SupervisedTask],
    managedSessions: [SessionSnapshot] = [],
    processIsAlive: (SupervisedTask) -> Bool
  ) -> Bool {
    guard connected, pendingRequestCount == 0, !busy else { return false }
    guard !managedSessions.contains(where: {
      $0.hostInstanceId == "managed-codex" && ($0.status == .working || $0.status == .waiting
        || $0.work?.hasOutstanding == true || $0.work?.awaitingResults == true)
    }) else { return false }
    return !tasks.contains { $0.state == .working || processIsAlive($0) }
  }

  /// A marker applies only to its expected build or a newer numeric build.
  public static func applies(expectedBuild: String, currentBuild: String) -> Bool {
    guard let expected = buildNumber(expectedBuild), let current = buildNumber(currentBuild) else {
      return false
    }
    return current >= expected
  }

  /// Match only top-level launchctl fields, never an argument or a nested diagnostic.
  public static func launchdServiceMatches(_ output: String, pid: Int, programPath: String) -> Bool {
    guard pid > 0, pid <= Int(Int32.max), programPath.hasPrefix("/"),
      !programPath.contains("\n"), !programPath.contains("\r") else { return false }
    let lines = output.components(separatedBy: "\n")
    let programs = lines.filter { $0.hasPrefix("\tprogram = ") }
    let pids = lines.filter { $0.hasPrefix("\tpid = ") }
    return programs == ["\tprogram = " + programPath] && pids == ["\tpid = " + String(pid)]
  }

  private static func buildNumber(_ value: String) -> UInt64? {
    guard !value.isEmpty, value.utf8.count <= 18,
      value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return UInt64(value)
  }
}
