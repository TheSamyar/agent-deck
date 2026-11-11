import Foundation

public struct NativeGUIControlRequest: Codable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable { case focus, scanWindows }
  public var id: String
  public var kind: Kind
  public var session: SessionSnapshot?
  public var expiresAt: Double
  public init(kind: Kind, session: SessionSnapshot? = nil) {
    id = UUID().uuidString; self.kind = kind; self.session = session
    expiresAt = DeckClock.now + 6000
  }
}
public struct NativeGUIControlReply: Codable, Sendable {
  public var id: String
  public var result: ActionResult?
  public var windowTitles: [String]?
  public init(id: String, result: ActionResult? = nil, windowTitles: [String]? = nil) {
    self.id = id; self.result = result; self.windowTitles = windowTitles
  }
}
public struct NativeGUIControlPoll: Codable, Sendable {
  public var clientID: String
  public var accessibilityGranted: Bool
  public var replies: [NativeGUIControlReply]
  public init(clientID: String, accessibilityGranted: Bool, replies: [NativeGUIControlReply]) {
    self.clientID = clientID; self.accessibilityGranted = accessibilityGranted; self.replies = replies
  }
}
public struct NativeGUIControlDelivery: Codable, Sendable {
  public var requests: [NativeGUIControlRequest]
  public init(requests: [NativeGUIControlRequest]) { self.requests = requests }
}
public struct NativeGUIControlHealth: Codable, Sendable {
  public var accessibilityGranted: Bool
  public var guiConnected: Bool
  public var controlHost = "app"
  public init(accessibilityGranted: Bool, guiConnected: Bool) {
    self.accessibilityGranted = accessibilityGranted; self.guiConnected = guiConnected
  }
}
