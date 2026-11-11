import Darwin
import DeckTransport
import DeckCore
import Foundation

let env = ProcessInfo.processInfo.environment
let agent = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "unknown"
let event = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "activity"
// Managed Codex already has an authoritative structured event stream.
if agent == "codex" && env["AGENT_DECK_HOST_INSTANCE"] == "managed-codex" { exit(EXIT_SUCCESS) }
let raw =
  CommandLine.arguments.count > 3
  ? Data(CommandLine.arguments.dropFirst(3).joined(separator: " ").utf8)
  : isatty(STDIN_FILENO) == 0 ? FileHandle.standardInput.readDataToEndOfFile() : Data()
let payload = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
let runtime =
  env["AGENT_DECK_RUNTIME"]
  ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Library/Caches/AgentDeck"
  ).path
var tty = env["TTY"] ?? ""
if tty.isEmpty {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/ps")
  process.arguments = ["-p", String(getppid()), "-o", "tty="]
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = FileHandle.nullDevice
  if (try? process.run()) != nil {
    let text =
      String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if text.hasPrefix("ttys") { tty = "/dev/" + text }
  }
}
let eventKey = event.lowercased().filter(\.isLetter)
let isPermissionHook = ["claude", "codex"].contains(agent) && eventKey == "permissionrequest"
let isToolHook =
  (agent == "cursor" && ["beforeshellexecution", "beforemcpexecution"].contains(eventKey))
  || (agent == "gemini" && eventKey == "beforetool")
let waiting = isPermissionHook || isToolHook
let owner = ProcessWitness.agentOwner(startingAt: Int(getppid()), agent: agent)
let witness = owner ?? ProcessWitness.read(Int(getppid()))
let body: [String: Any] = [
  "data": HookMetadata.filtered(payload, permissionContext: waiting), "awaitDecision": waiting,
  "env": [
    "pwd": env["PWD"] ?? FileManager.default.currentDirectoryPath,
    "bundleId": env["__CFBundleIdentifier"] ?? "", "ppid": owner?.pid ?? Int(getppid()), "processBirth": witness?.birth ?? "", "ownerVerified": owner != nil, "tty": tty,
    "terminalId": env["ITERM_SESSION_ID"]?.components(separatedBy: ":").last ?? "",
    "hostInstanceId": env["AGENT_DECK_HOST_INSTANCE"] ?? env["__CFBundleIdentifier"] ?? "",
  ],
]
do {
  let response = try LocalIO.unixRequest(
    path: runtime + "/deck.sock", route: "/hook/\(agent)/\(event)",
    body: JSONSerialization.data(withJSONObject: body), timeout: waiting ? 305 : 2)
  let trimmedResponse =
    String(data: response, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  if waiting && !trimmedResponse.isEmpty {
    FileHandle.standardOutput.write(response)
    FileHandle.standardOutput.write(Data("\n".utf8))
  } else if agent == "gemini" {
    print("{}")
  } else if agent == "cursor" && isToolHook {
    print(#"{"permission":"ask"}"#)
  }
} catch {
  // No decision leaves the agent's original permission flow intact.
  if agent == "cursor" && isToolHook {
    print(#"{"permission":"ask"}"#)
  } else if waiting || agent == "gemini" {
    print("{}")
  }
}
