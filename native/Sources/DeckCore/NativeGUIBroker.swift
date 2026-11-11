import Foundation

/// A short-lived, authenticated app lease. No scripts or approval commands cross this bridge.
public struct NativeGUIBroker {
  public init() {}
  public private(set) var clientID = ""
  public private(set) var lastSeen = 0.0
  public private(set) var accessibilityGranted = false
  private var pending: [String: NativeGUIControlRequest] = [:]
  private var results: [String: NativeGUIControlReply] = [:]
  public var connected: Bool { DeckClock.now - lastSeen < 5000 && !clientID.isEmpty }
  public mutating func poll(_ poll: NativeGUIControlPoll) -> NativeGUIControlDelivery? {
    guard !poll.clientID.isEmpty, poll.clientID.count <= 100,
      !connected || clientID == poll.clientID, poll.replies.count <= 16 else { return nil }
    if clientID != poll.clientID { pending.removeAll(); results.removeAll() }
    clientID = poll.clientID; lastSeen = DeckClock.now; accessibilityGranted = poll.accessibilityGranted
    pending = pending.filter { $0.value.expiresAt > DeckClock.now }
    for reply in poll.replies {
      guard let request = pending.removeValue(forKey: reply.id), request.expiresAt > DeckClock.now else { continue }
      switch request.kind {
      case .focus:
        if let result = reply.result {
          results[reply.id] = .init(id: reply.id, result: result)
        }
      case .scanWindows:
        if let titles = reply.windowTitles, titles.count <= 512, titles.allSatisfy({ $0.count <= 2048 }) {
          results[reply.id] = .init(id: reply.id, windowTitles: titles)
        } else if let result = reply.result, !result.ok {
          results[reply.id] = .init(id: reply.id, result: result)
        }
      }
    }
    if results.count > 32 { results.removeAll() }
    return .init(requests: pending.values.sorted { $0.id < $1.id })
  }
  public mutating func enqueue(_ request: NativeGUIControlRequest) -> Bool {
    guard connected, accessibilityGranted, pending.count < 8 else { return false }
    pending[request.id] = request; return true
  }
  public mutating func take(_ id: String) -> NativeGUIControlReply? { results.removeValue(forKey: id) }
  public mutating func cancel(_ id: String) { pending.removeValue(forKey: id); results.removeValue(forKey: id) }
}
