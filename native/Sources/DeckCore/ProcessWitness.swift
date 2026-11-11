import Darwin
import Foundation

public struct ProcessWitness: Equatable, Sendable {
  public var pid: Int
  public var parentPID: Int
  public var executable: String
  public var birth: String
  /// Kernel birth identity remains readable after an executable has been unlinked.
  public static func readBirth(_ pid: Int) -> String? {
    guard let info = readInfo(pid) else { return nil }
    return "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
  }
  public static func read(_ pid: Int) -> Self? {
    guard let info = readInfo(pid) else { return nil }
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(Int32(pid), &path, UInt32(path.count)) > 0 else { return nil }
    return .init(pid: pid, parentPID: Int(info.pbi_ppid), executable: String(cString: path), birth: "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)")
  }
  private static func readInfo(_ pid: Int) -> proc_bsdinfo? {
    guard pid > 0, pid <= Int(Int32.max) else { return nil }
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
    return info
  }
  public static func agentOwner(startingAt pid: Int, agent: String) -> Self? {
    let names: Set<String>
    switch agent { case "claude": names = ["claude"]; case "codex": names = ["codex"]; case "gemini": names = ["gemini"]; case "cursor": names = ["cursor", "cursor helper", "cursor helper (plugin)", "cursor helper (renderer)"]; default: return nil }
    var current = pid
    var visited = Set<Int>()
    for _ in 0..<20 {
      guard visited.insert(current).inserted, let witness = read(current) else { return nil }
      let name = URL(fileURLWithPath: witness.executable).lastPathComponent.lowercased()
      if names.contains(name) || (["node", "bun"].contains(name) && moduleMatchesAgent(pid: witness.pid, agent: agent)) || (agent == "claude" && witness.executable.contains("/.local/share/claude/versions/")) { return witness }
      if witness.parentPID <= 1 { return nil }
      current = witness.parentPID
    }
    return nil
  }
  private static func moduleMatchesAgent(pid: Int, agent: String) -> Bool {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
    var length = 0
    guard sysctl(&mib, 3, nil, &length, nil, 0) == 0, length > 4, length <= 1_048_576 else { return false }
    var bytes = [UInt8](repeating: 0, count: length)
    guard sysctl(&mib, 3, &bytes, &length, nil, 0) == 0 else { return false }
    var cursor = MemoryLayout<Int32>.size
    while cursor < length && bytes[cursor] != 0 { cursor += 1 }
    while cursor < length && bytes[cursor] == 0 { cursor += 1 }
    // Inspect only argv[1], the JS entry module; never retain or log prompts.
    while cursor < length && bytes[cursor] != 0 { cursor += 1 }
    cursor += 1
    let start = cursor
    while cursor < length && bytes[cursor] != 0 { cursor += 1 }
    guard start < cursor, cursor - start <= 4096,
      let module = String(bytes: bytes[start..<cursor], encoding: .utf8), module.hasPrefix("/") else { return false }
    let path = URL(fileURLWithPath: module).resolvingSymlinksInPath().path
    let package: String
    switch agent { case "claude": package = "/@anthropic-ai/claude-code/"; case "gemini": package = "/@google/gemini-cli/"; case "codex": package = "/@openai/codex/"; default: return false }
    return path.contains(package) && FileManager.default.fileExists(atPath: path)
  }

}
