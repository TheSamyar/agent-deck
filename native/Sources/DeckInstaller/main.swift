import DeckCore
import Foundation

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
  guard let i = arguments.firstIndex(of: name), arguments.indices.contains(i + 1) else {
    return nil
  }
  return arguments[i + 1]
}
let home = URL(
  fileURLWithPath: option("--home") ?? FileManager.default.homeDirectoryForCurrentUser.path)
let remove = arguments.contains("--uninstall")
let dryRun = arguments.contains("--dry-run")
let enabled = Set(
  (option("--agents") ?? "claude,cursor,gemini,codex").split(separator: ",").map(String.init))
let selfURL = URL(fileURLWithPath: arguments[0]).standardizedFileURL
let hook =
  option("--hook")
  ?? selfURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
    "MacOS/deck-hook"
  ).path
let quotedHook =
  "\""
  + hook.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
  + "\""
var failures = 0
func ours(_ value: Any) -> Bool {
  guard let object = value as? [String: Any], let command = object["command"] as? String else { return false }
  let pattern = #""(?:\\.|[^"\\])*"|'[^']*'|\S+"#
  guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
  let ns = command as NSString
  var tokens = regex.matches(in: command, range: NSRange(location: 0, length: ns.length)).map { match -> String in
    var token = ns.substring(with: match.range)
    if token.hasPrefix("\"") && token.hasSuffix("\"") || token.hasPrefix("'") && token.hasSuffix("'") { token.removeFirst(); token.removeLast() }
    return token.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
  }
  if tokens.first == "/usr/bin/env" { tokens.removeFirst() }
  guard let executable = tokens.first else { return false }
  if executable == hook || executable.hasSuffix("/Agent Deck.app/Contents/MacOS/deck-hook") { return true }
  let name = URL(fileURLWithPath: executable).lastPathComponent
  if name == "agent-hook.mjs" { return true }
  return name == "node" && tokens.count > 1 && URL(fileURLWithPath: tokens[1]).lastPathComponent == "agent-hook.mjs"
}
func withoutOwned(_ value: Any) -> Any? {
  guard var object = value as? [String: Any] else { return value }
  if let handlers = object["hooks"] as? [Any] {
    let kept = handlers.filter { !ours($0) }
    if kept.isEmpty { return nil }
    object["hooks"] = kept; return object
  }
  return ours(object) ? nil : object
}
func write(_ data: Data, to url: URL) throws {
  if dryRun {
    print("Would update \(url.path)")
    return
  }
  let fm = FileManager.default
  try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  let backup = URL(fileURLWithPath: url.path + ".pre-agent-deck-native.bak")
  if fm.fileExists(atPath: url.path) && !fm.fileExists(atPath: backup.path) {
    try fm.copyItem(at: url, to: backup)
  }
  let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o600
  try data.write(to: url, options: .atomic)
  try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
  print("Updated \(url.path)")
}
func configure(_ relative: String, agent: String, events: [String], cursor: Bool = false) {
  guard enabled.contains(agent) || remove else { return }
  let url = home.appendingPathComponent(relative)
  guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
    print("Skipped \(agent): not installed")
    return
  }
  do {
    var root: [String: Any] = [:]
    if FileManager.default.fileExists(atPath: url.path) {
      guard
        let parsed = try JSONSerialization.jsonObject(
          with: Data(contentsOf: url), options: [.json5Allowed]) as? [String: Any]
      else { throw CocoaError(.propertyListReadCorrupt) }
      root = parsed
    }
    if root["hooks"] != nil && !(root["hooks"] is [String: Any]) {
      throw CocoaError(.propertyListReadCorrupt)
    }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    for event in events {
      if hooks[event] != nil && !(hooks[event] is [Any]) {
        throw CocoaError(.propertyListReadCorrupt)
      }
      var entries = (hooks[event] as? [Any] ?? []).compactMap { withoutOwned($0) }
      if !remove {
        let command = "\(quotedHook) \(agent) \(event)"
        if cursor {
          entries.append(["command": command])
        } else {
          var entry: [String: Any] = [
            "hooks": [
              [
                "type": "command", "command": command,
                "timeout": agent == "gemini" ? 3000 : agent == "claude" && event == "PermissionRequest" ? 310 : 3,
              ]
            ]
          ]
          if [
            "PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "BeforeTool",
            "AfterTool",
          ].contains(event) {
            entry["matcher"] = ".*"
          }
          entries.append(entry)
        }
      }
      if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
    }
    root["hooks"] = hooks
    if cursor && root["version"] == nil { root["version"] = 1 }
    try write(
      JSONSerialization.data(
        withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
      to: url)
  } catch {
    failures += 1
    fputs("Left \(url.path) unchanged: \(error.localizedDescription)\n", stderr)
  }
}
configure(
  ".claude/settings.json", agent: "claude",
  events: [
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
    "Notification", "Stop", "SubagentStart", "SubagentStop", "SessionEnd",
  ])
configure(
  ".cursor/hooks.json", agent: "cursor",
  events: [
    "beforeSubmitPrompt", "afterMCPExecution", "afterShellExecution", "afterFileEdit", "stop",
  ], cursor: true)
configure(
  ".gemini/settings.json", agent: "gemini",
  events: [
    "SessionStart", "BeforeAgent", "BeforeTool", "AfterTool", "Notification", "AfterAgent",
    "SessionEnd",
  ])
configure(
  ".codex/hooks.json", agent: "codex",
  events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SubagentStart", "SubagentStop", "Interrupt", "SessionEnd"])
if enabled.contains("codex") && !remove {
  print("Codex: review updated Agent Deck hooks with /hooks. Hook trust is controlled by Codex, not this installer.")
}
if enabled.contains("codex") || remove {
  let url = home.appendingPathComponent(".codex/config.toml")
  if FileManager.default.fileExists(atPath: url.path) {
    do {
      var text = try String(contentsOf: url, encoding: .utf8)
      let regex = try NSRegularExpression(pattern: #"(?m)^notify\s*=\s*(\[[^\n]*\])\s*$"#)
      let range = NSRange(text.startIndex..., in: text)
      let command = [hook, "codex", "turn-ended"]
      let line =
        "notify = " + String(
          data: try JSONSerialization.data(
            withJSONObject: command, options: [.withoutEscapingSlashes]), encoding: .utf8)!
      if let match = regex.firstMatch(in: text, range: range),
        let valueRange = Range(match.range(at: 1), in: text),
        let full = Range(match.range, in: text)
      {
        let value = String(text[valueRange])
        if let argv = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String] {
          if let previous = argv.firstIndex(of: "--previous-notify"),
            argv.indices.contains(previous + 1)
          {
            var updated = argv
            if updated[previous + 1].contains("agent-hook.mjs")
              || updated[previous + 1].contains("deck-hook")
            {
              if remove {
                updated.removeSubrange(previous...previous + 1)
              } else {
                updated[previous + 1] = String(
                  data: try JSONSerialization.data(
                    withJSONObject: command, options: [.withoutEscapingSlashes]), encoding: .utf8)!
              }
              text.replaceSubrange(
                full,
                with: "notify = " + String(
                  data: try JSONSerialization.data(
                    withJSONObject: updated, options: [.withoutEscapingSlashes]), encoding: .utf8)!)
            } else {
              print("Codex notify belongs to another integration; preserved.")
            }
          } else if value.contains("agent-hook.mjs") || value.contains("MacOS/deck-hook") {
            text.replaceSubrange(full, with: remove ? "" : line)
          } else {
            print("Codex notify belongs to another integration; preserved.")
          }
        } else {
          print("Codex notify could not be parsed safely; preserved.")
        }
      } else if !remove && !text.contains("notify =") {
        text = line + "\n" + text
      }
      try write(Data(text.utf8), to: url)
    } catch {
      failures += 1
      fputs("Codex configuration was not changed: \(error.localizedDescription)\n", stderr)
    }
  }
}
if arguments.contains("--keypad") { configureKeypad() }
if arguments.contains("--editor") {
  let source = selfURL.deletingLastPathComponent().appendingPathComponent("EditorExtension")
  let extensions = home.appendingPathComponent(".cursor/extensions")
  let target = extensions.appendingPathComponent("agent-deck.agent-deck-bridge-0.2.0")
  do {
    if !dryRun {
      try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: target.path) {
        try FileManager.default.removeItem(at: target)
      }
      if !remove { try FileManager.default.copyItem(at: source, to: target) }
    }
    print(
      remove
        ? "Editor bridge removed."
        : "Editor bridge installed. Reload Cursor windows when you are ready; running terminals were not interrupted."
    )
  } catch {
    failures += 1
    fputs("Editor bridge was not installed: \(error.localizedDescription)\n", stderr)
  }
}
print(
  remove
    ? "Owned hooks removed. Other integrations were preserved."
    : "Hook setup finished. Restart CLI sessions to connect. Existing unrelated hooks were preserved."
)
exit(failures == 0 ? 0 : 1)
