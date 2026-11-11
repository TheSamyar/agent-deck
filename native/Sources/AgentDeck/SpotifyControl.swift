import AppKit
import Carbon
import DeckCore

/// Commands are fixed strings, never interpolated from imported user text.
actor SpotifyControl {
  static func run(_ command: String) async -> String {
    await worker.execute(command)
  }
  private static let worker = SpotifyControl()
  private var cachedURL: URL?
  private var cachedArtwork: Data?
  static func nowPlaying() async -> NowPlaying { await worker.readState() }
  private func readState() async -> NowPlaying {
    var state = NowPlaying()
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").count > 0 else { return state }
    let target = NSAppleEventDescriptor(bundleIdentifier: "com.spotify.client")
    guard AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr else {
      state.artist = "Connect Spotify controls"; state.message = "Press a Spotify control to request Automation access."; return state
    }
    var error: NSDictionary?
    let source = "with timeout of 2 seconds\ntell application id \"com.spotify.client\"\nreturn {name of current track, artist of current track, id of current track, artwork url of current track, player state as string, shuffling, repeating}\nend tell\nend timeout"
    guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil else {
      state.artist = "No track selected"; return state
    }
    state.title = result.atIndex(1)?.stringValue ?? "Spotify"
    state.artist = result.atIndex(2)?.stringValue ?? ""
    state.trackID = result.atIndex(3)?.stringValue ?? ""
    state.playing = result.atIndex(5)?.stringValue == "playing"
    state.shuffle = result.atIndex(6)?.booleanValue ?? false
    state.repeating = result.atIndex(7)?.booleanValue ?? false
    if let value = result.atIndex(4)?.stringValue, let url = URL(string: value), NowPlaying.allowedArtworkURL(url) {
      if cachedURL != url {
        cachedURL = url; cachedArtwork = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: ArtworkRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
          let (bytes, response) = try await session.bytes(for: URLRequest(url: url, timeoutInterval: 5))
          if let response = response as? HTTPURLResponse, response.statusCode == 200,
            response.expectedContentLength <= 2_000_000, response.mimeType?.hasPrefix("image/") == true {
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > 2_000_000 { throw URLError(.dataLengthExceedsMaximum) } }
            cachedArtwork = data
          }
        } catch { cachedArtwork = nil }
      }
      state.artwork = cachedArtwork
    }
    return state
  }
  private func execute(_ command: String) -> String {
    let body: String
    switch command {
    case "open": body = "activate"
    case "playpause": body = "playpause"
    case "previous track": body = "previous track"
    case "next track": body = "next track"
    case "shuffle": body = "set shuffling to not shuffling"
    case "repeat": body = "set repeating to not repeating"
    default: return "This media control is unavailable."
    }
    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil else {
      return "Spotify is not installed. Install Spotify to use these controls."
    }
    var error: NSDictionary?
    guard let script = NSAppleScript(source: "with timeout of 3 seconds\ntell application id \"com.spotify.client\"\n\(body)\nend tell\nend timeout") else { return "Spotify command could not be prepared." }
    script.executeAndReturnError(&error)
    if let error {
      if error[NSAppleScript.errorNumber] as? Int == -1743 { return "Allow Agent Deck to control Spotify in System Settings → Privacy & Security → Automation." }
      return "Spotify could not complete that action. Open Spotify and try again."
    }
    return "Spotify · \(command == "playpause" ? "Playback toggled" : command.capitalized)"
  }
}

private final class ArtworkRedirectPolicy: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(request.url.map(NowPlaying.allowedArtworkURL) == true ? request : nil)
  }
}
