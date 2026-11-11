import Foundation

public enum RobinPersonalSource: String, Codable, CaseIterable, Sendable { case gmail, calendar, drive, docs, sheets, tasks, contacts, slack
  public var provider: String { self == .slack ? "slack" : "google" }
  public var scope: String {
    switch self {
    case .gmail: "https://www.googleapis.com/auth/gmail.readonly"
    case .calendar: "https://www.googleapis.com/auth/calendar.readonly"
    case .drive, .docs, .sheets: "https://www.googleapis.com/auth/drive.readonly"
    case .tasks: "https://www.googleapis.com/auth/tasks.readonly"
    case .contacts: "https://www.googleapis.com/auth/contacts.readonly"
    case .slack: "search:read,channels:read,groups:read"
    }
  }
}
public struct RobinPersonalAccount: Codable, Identifiable, Sendable, Equatable {
  public var id: String
  public var label: String
  public var provider: String
  public var sources: Set<RobinPersonalSource>
  public var destinations: Set<String>
  public var grantedSources: Set<RobinPersonalSource>? = nil
  public var canWrite: Bool? = false
  public var slackChannels: [String]
  public init(id:String = UUID().uuidString,label:String,provider:String,sources:Set<RobinPersonalSource>,destinations:Set<String> = [],slackChannels:[String] = []) {
    self.id=id;self.label=label;self.provider=provider;self.sources=sources;self.destinations=destinations;self.slackChannels=slackChannels
  }
}
public struct RobinPersonalResult: Sendable {
  public var accountID:String; public var source:RobinPersonalSource; public var text:String; public var fetchedAt:Date
  public init(accountID:String,source:RobinPersonalSource,text:String,fetchedAt:Date = Date()) {self.accountID=accountID;self.source=source;self.text=text;self.fetchedAt=fetchedAt}
}
public enum RobinPersonalRequest {
  public static func request(source:RobinPersonalSource,query:String,resourceID:String? = nil,channels:[String] = [],now:Date = Date()) throws -> URLRequest {
    guard query.count <= 2000, resourceID.map({!$0.isEmpty && $0.count<512 && !$0.contains("/") && !$0.contains("..")}) ?? true else { throw failure("Invalid personal-source query or resource identifier.") }
    var path:String;var items:[URLQueryItem] = []
    let id=resourceID?.addingPercentEncoding(withAllowedCharacters:.alphanumerics) ?? ""
    switch source {
    case .gmail:
      path="https://gmail.googleapis.com/gmail/v1/users/me/messages" + (resourceID == nil ? "" : "/"+id)
      items=resourceID == nil ? [.init(name:"q",value:query),.init(name:"maxResults",value:"10")] : [.init(name:"format",value:"full")]
    case .calendar:
      path="https://www.googleapis.com/calendar/v3/calendars/primary/events"
      items=[.init(name:"timeMin",value:ISO8601DateFormatter().string(from:now)),.init(name:"timeMax",value:ISO8601DateFormatter().string(from:now.addingTimeInterval(7*86400))),.init(name:"singleEvents",value:"true"),.init(name:"orderBy",value:"startTime"),.init(name:"maxResults",value:"20")]
      if !query.isEmpty {items.append(.init(name:"q",value:query))}
    case .drive, .docs, .sheets:
      if resourceID != nil {
        path="https://www.googleapis.com/drive/v3/files/"+id
        items=[.init(name:"alt",value:"media")]
        if source == .docs || source == .sheets {path += "/export";items=[.init(name:"mimeType",value:source == .docs ? "text/plain" : "text/csv")]}
      } else {
        path="https://www.googleapis.com/drive/v3/files"
        let escaped=query.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"'",with:"\\'")
        let mime=source == .docs ? " and mimeType = 'application/vnd.google-apps.document'" : source == .sheets ? " and mimeType = 'application/vnd.google-apps.spreadsheet'" : ""
        items=[.init(name:"q",value:"trashed = false and fullText contains '\(escaped)'"+mime),.init(name:"pageSize",value:"10"),.init(name:"fields",value:"files(id,name,mimeType,modifiedTime,webViewLink)")]
      }
    case .tasks:
      path="https://tasks.googleapis.com/tasks/v1/users/@me/lists"
      if resourceID != nil {path="https://tasks.googleapis.com/tasks/v1/lists/"+id+"/tasks"}
      items=[.init(name:"maxResults",value:"20")]
    case .contacts:
      path="https://people.googleapis.com/v1/people:searchContacts"
      items=[.init(name:"query",value:query),.init(name:"readMask",value:"names,emailAddresses"),.init(name:"pageSize",value:"10")]
    case .slack:
      guard !channels.isEmpty,channels.count<=30,channels.allSatisfy({$0.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil}) else {throw failure("Select allowed Slack channel names before searching.")}
      path="https://slack.com/api/search.messages"
      // Each channel is searched separately by the client; never let query operators bypass its scope.
      guard channels.count == 1 else {throw failure("Search one approved Slack channel at a time.")}
      let escaped=query.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
      items=[.init(name:"query",value:"in:\(channels[0]) \"\(escaped)\""),.init(name:"count",value:"10")]
    }
    var url=URLComponents(string:path)!;url.queryItems=items
    var request=URLRequest(url:url.url!);request.httpMethod="GET";request.timeoutInterval=25;return request
  }
  public static func failure(_ text:String)->NSError {NSError(domain:"RobinConnections",code:1,userInfo:[NSLocalizedDescriptionKey:text])}
}
