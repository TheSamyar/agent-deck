import Foundation

actor JarvisBrowserBroker {
  private var state: [String: Any] = [:]
  private var updated = Date.distantPast
  private var pending: [String: Any]?
  private var result: [String: Any]?
  private var executing = false
  func poll(_ body: [String: Any]) -> [String: Any] {
    if let state = body["state"] as? [String: Any] { self.state = state; updated = Date() }
    if let result = body["result"] as? [String: Any], let id=result["id"] as? String, id == pending?["id"] as? String {
      self.result = result; pending = nil
    }
    if let pending { return ["command": pending] }
    return [:]
  }
  func status() -> [String: Any] { ["connected":Date().timeIntervalSince(updated)<3,"state":state] }
  func command(_ body: [String: Any]) async -> [String: Any] {
    guard !executing else { return ["ok":false,"message":"Another browser action is finishing."] }
    guard Date().timeIntervalSince(updated)<3 else { return ["ok":false,"message":"Load the browser companion extension and approve the site first."] }
    guard let kind = body["kind"] as? String, ["observe","navigate","click","typeText","scroll"].contains(kind),
      let origin = body["origin"] as? String, (state["origins"] as? [String] ?? []).contains(origin),
      (kind == "navigate" || state["origin"] as? String == origin), let tab = state["tabId"] as? Int else { return ["ok":false,"message":"The active website is not approved or changed. Inspect browser status first."] }
    let id = UUID().uuidString
    executing=true
    defer {executing=false;pending=nil;result=nil}
    var command = body; command["id"] = id; command["tabId"] = tab
    pending = command; result = nil
    for _ in 0..<50 {
      if let result = self.result { self.result = nil; return result }
      try? await Task.sleep(for:.milliseconds(100))
    }
    pending = nil
    return ["ok":false,"message":"Browser action outcome is unknown. Inspect the page before retrying."]
  }
}
