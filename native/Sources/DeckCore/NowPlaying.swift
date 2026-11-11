import Foundation

public struct NowPlaying: Equatable, Sendable {
  public var title = "Spotify"
  public var artist = "Open Spotify to play music"
  public var trackID = ""
  public var playing = false
  public var shuffle = false
  public var repeating = false
  public var artwork: Data?
  public var message = ""
  public init() {}
  public static func allowedArtworkURL(_ url: URL) -> Bool {
    guard url.scheme == "https", url.user == nil, url.password == nil,
      url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
    return host.hasSuffix(".scdn.co") || host.hasSuffix(".spotifycdn.com")
  }
}
