import AppKit
import ApplicationServices
import Darwin
import Foundation

public actor MacControl {
  public static let cursorBundle = "com.todesktop.230313mzl4w4u92"
  public init() {}
  public func hasAccessibility() -> Bool { AXIsProcessTrusted() }
  public func verifiesForegroundTerminal(_ session: SessionSnapshot) -> Bool {
    guard session.pid > 0, session.tty.hasPrefix("/dev/ttys") else { return false }
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(session.pid)]
    guard sysctl(&query, u_int(query.count), &info, &size, nil, 0) == 0,
      size == MemoryLayout<kinfo_proc>.stride
    else { return false }
    let fd = Darwin.open(session.tty, O_RDONLY | O_NOCTTY | O_NONBLOCK)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var terminal = stat()
    guard fstat(fd, &terminal) == 0 else { return false }
    let processGroup = info.kp_eproc.e_pgid
    return processGroup > 0 && info.kp_eproc.e_tpgid == processGroup
      && info.kp_eproc.e_tdev == terminal.st_rdev && processGroup == getpgid(Int32(session.pid))
  }
  public func interrupt(_ session: SessionSnapshot) -> ActionResult {
    guard verifiesForegroundTerminal(session) else {
      return .failure(
        "This agent is not the verified foreground terminal process. Open its session before interrupting."
      )
    }
    let group = getpgid(Int32(session.pid))
    guard group > 0, kill(-group, SIGINT) == 0 else {
      return .failure("The terminal process ended before it could be interrupted.")
    }
    return .init(
      ok: true, state: "acknowledged", message: "Interrupt sent to the verified process group")
  }
  private func script(_ source: String) throws -> String {
    var error: NSDictionary?
    guard let script = NSAppleScript(source: "with timeout of 3 seconds\n\(source)\nend timeout")
    else { throw CocoaError(.executableNotLoadable) }
    let result = script.executeAndReturnError(&error)
    if let error {
      throw NSError(
        domain: "DeckAutomation", code: error[NSAppleScript.errorNumber] as? Int ?? 1,
        userInfo: [
          NSLocalizedDescriptionKey: error[NSAppleScript.errorMessage] as? String
            ?? "Automation permission is required."
        ])
    }
    return result.stringValue ?? ""
  }
  private func quote(_ text: String) -> String {
    "\""
      + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
        of: "\"", with: "\\\"") + "\""
  }
  public func cursorWindows() throws -> [String] {
    guard
      NSRunningApplication.runningApplications(withBundleIdentifier: Self.cursorBundle).first != nil
    else { return [] }
    let output = try script(
      """
      tell application "System Events"
          tell process "Cursor"
              set names to name of every menu item of menu "Window" of menu bar 1
              set windowsList to {}
              repeat with i from (count of names) to 1 by -1
                  set itemName to item i of names
                  if itemName is missing value then exit repeat
                  set beginning of windowsList to itemName
              end repeat
              set AppleScript's text item delimiters to linefeed
              return windowsList as text
          end tell
      end tell
      """)
    return output.split(separator: "\n").map(String.init)
  }
  public func focus(_ session: SessionSnapshot, interrupt: Bool = false) async -> ActionResult {
    do {
      if session.agentId == "cursor" || session.bundleId == Self.cursorBundle {
        guard !interrupt else {
          return .failure("Connect the editor extension to control this terminal.")
        }
        let matches = try cursorWindows().filter { workspaceName($0) == session.workspace }
        guard matches.count == 1 else {
          return .failure(
            matches.isEmpty
              ? "This project window is no longer open."
              : "Several windows share this project name. Connect the editor extension to identify the exact session."
          )
        }
        let wanted = quote(matches[0])
        _ = try script(
          """
          tell application "Cursor" to activate
          tell application "System Events"
              tell process "Cursor"
                  set frontmost to true
                  click menu item \(wanted) of menu "Window" of menu bar 1
                  repeat 20 times
                      if exists window 1 then
                          if name of window 1 is \(wanted) then return "focused"
                      end if
                      delay 0.1
                  end repeat
                  error "The project window did not become active."
              end tell
          end tell
          """)
        return .init(ok: true, state: "acknowledged", message: "Opened \(session.workspace)")
      }
      if session.bundleId == "com.googlecode.iterm2" {
        guard !session.tty.isEmpty || !session.terminalId.isEmpty else {
          return .failure("The iTerm session identity is missing.")
        }
        let match =
          session.terminalId.isEmpty
          ? "tty of s is \(quote(session.tty))" : "unique id of s is \(quote(session.terminalId))"
        let verify =
          session.terminalId.isEmpty
          ? "tty of current session of current window is not \(quote(session.tty))"
          : "unique id of current session of current window is not \(quote(session.terminalId))"
        let key =
          interrupt
          ? "tell application \"System Events\" to keystroke \"c\" using control down" : ""
        _ = try script(
          """
          set matched to 0
          tell application "iTerm2"
              repeat with w in windows
                  repeat with t in tabs of w
                      repeat with s in sessions of t
                          if \(match) then
                              select s
                              select t
                              select w
                              activate
                              set matched to matched + 1
                          end if
                      end repeat
                  end repeat
              end repeat
              if matched is not 1 then error "The iTerm session is missing or ambiguous."
              if \(verify) then error "The selected iTerm session changed."
          end tell
          tell application "System Events"
              repeat 20 times
                  if (bundle identifier of (first application process whose frontmost is true)) is "com.googlecode.iterm2" then exit repeat
                  delay 0.1
              end repeat
              if (bundle identifier of (first application process whose frontmost is true)) is not "com.googlecode.iterm2" then error "iTerm did not become active."
          end tell
          \(key)
          return "focused"
          """)
        return .init(
          ok: true, state: "acknowledged",
          message: interrupt ? "Interrupt sent" : "Opened \(session.workspace)")
      }
      guard !session.tty.isEmpty, session.bundleId == "com.apple.Terminal" else {
        return .failure(
          "Exact terminal targeting is unavailable for this host. Connect its integration first.")
      }
      let key =
        interrupt ? "tell application \"System Events\" to keystroke \"c\" using control down" : ""
      _ = try script(
        """
        set matched to 0
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is \(quote(session.tty)) then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        set matched to matched + 1
                    end if
                end repeat
            end repeat
            if matched is not 1 then error "The terminal is missing or ambiguous."
            if tty of selected tab of front window is not \(quote(session.tty)) then error "Terminal selection changed."
        end tell
        tell application "System Events"
            repeat 20 times
                if (bundle identifier of (first application process whose frontmost is true)) is "com.apple.Terminal" then exit repeat
                delay 0.1
            end repeat
            if (bundle identifier of (first application process whose frontmost is true)) is not "com.apple.Terminal" then error "Terminal did not become active."
        end tell
        \(key)
        return "focused"
        """)
      return .init(
        ok: true, state: "acknowledged",
        message: interrupt ? "Interrupt sent" : "Opened \(session.workspace)")
    } catch {
      return .failure(
        error.localizedDescription
          + " Check Agent Deck in Privacy & Security → Accessibility and Automation.")
    }
  }
}
