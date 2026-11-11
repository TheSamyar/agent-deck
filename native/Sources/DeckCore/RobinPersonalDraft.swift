import Foundation
public enum RobinPersonalWrite: String,Codable,CaseIterable,Sendable {
 case gmailDraft,gmailSend,slackPost,calendarCreate,documentAppend,sheetUpdate,taskCreate,taskUpdate,contactUpdate
 public var source:RobinPersonalSource {switch self {case .gmailDraft,.gmailSend:.gmail;case .slackPost:.slack;case .calendarCreate:.calendar;case .documentAppend:.docs;case .sheetUpdate:.sheets;case .taskCreate,.taskUpdate:.tasks;case .contactUpdate:.contacts}}
 public var scope:String {switch source {case .gmail:"https://www.googleapis.com/auth/gmail.compose";case .calendar:"https://www.googleapis.com/auth/calendar.events";case .docs:"https://www.googleapis.com/auth/documents";case .sheets:"https://www.googleapis.com/auth/spreadsheets";case .tasks:"https://www.googleapis.com/auth/tasks";case .contacts:"https://www.googleapis.com/auth/contacts";case .slack:"chat:write";case .drive:"https://www.googleapis.com/auth/drive.file"}}
}
public struct RobinPersonalDraft:Codable,Identifiable,Sendable {
 public let id:UUID; public let revision:UUID; public let accountID:String; public let operation:RobinPersonalWrite;public let fields:[String:String]; public let createdAt:Date
 public init(accountID:String,operation:RobinPersonalWrite,fields:[String:String]) {id=UUID();revision=UUID();self.accountID=accountID;self.operation=operation;self.fields=fields;createdAt=Date()}
 public var preview:String {operation.rawValue+"\n"+fields.keys.sorted().map{$0+": "+fields[$0]!}.joined(separator:"\n")}
 public func request() throws -> URLRequest {
  func value(_ key:String)throws->String {guard let text=fields[key],!text.isEmpty,text.count<=32000 else {throw RobinPersonalRequest.failure("Missing or oversized field: "+key)};return text}
  func id(_ key:String)throws->String {let text=try value(key);guard text.count<=512,text.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil else {throw RobinPersonalRequest.failure("Invalid identifier: "+key)};return text}
  var url:String;var body:[String:Any];var method="POST"
  switch operation {
  case .gmailDraft,.gmailSend:
   let to=try value("to"),subject=try value("subject"),text=try value("body")
   guard to.rangeOfCharacter(from:.newlines)==nil,subject.rangeOfCharacter(from:.newlines)==nil else {throw RobinPersonalRequest.failure("Mail headers must not contain line breaks.")}
   let raw=Data("To: \(to)\r\nSubject: \(subject)\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(text)".utf8).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
   url="https://gmail.googleapis.com/gmail/v1/users/me/"+(operation == .gmailDraft ? "drafts" : "messages/send");body=operation == .gmailDraft ? ["message":["raw":raw]] : ["raw":raw]
  case .slackPost:url="https://slack.com/api/chat.postMessage";body=["channel":try id("channel"),"text":try value("text"),"unfurl_links":false,"unfurl_media":false]
  case .calendarCreate:
   let start=try value("start"),end=try value("end")
   let formatter=ISO8601DateFormatter()
   guard let begins=formatter.date(from:start),let ends=formatter.date(from:end),begins<ends else {throw RobinPersonalRequest.failure("Calendar start/end must be ISO8601 dates with start before end.")}
   url="https://www.googleapis.com/calendar/v3/calendars/primary/events?sendUpdates=all";body=["summary":try value("title"),"start":["dateTime":try value("start")],"end":["dateTime":try value("end")]]
   if let emails=fields["attendees"],!emails.isEmpty {body["attendees"]=emails.split(separator:",").map{["email":$0.trimmingCharacters(in:.whitespacesAndNewlines)]}}
  case .documentAppend:url="https://docs.googleapis.com/v1/documents/"+(try id("documentID"))+":batchUpdate";body=["requests":[["insertText":["endOfSegmentLocation":[:],"text":try value("text")]]]]
  case .sheetUpdate:
   let range=try value("range");guard let rangeEncoded=range.addingPercentEncoding(withAllowedCharacters:.alphanumerics),let data=(try value("values")).data(using:.utf8),let values=try JSONSerialization.jsonObject(with:data) as? [[Any]] else {throw RobinPersonalRequest.failure("Sheet values must be a JSON array of rows.")}
   url="https://sheets.googleapis.com/v4/spreadsheets/"+(try id("spreadsheetID"))+"/values/"+rangeEncoded+"?valueInputOption=RAW";body=["range":range,"values":values];method="PUT"
  case .taskCreate,.taskUpdate:
   url="https://tasks.googleapis.com/tasks/v1/lists/"+(try id("listID"))+"/tasks";body=["title":try value("title")]
   if operation == .taskUpdate {url += "/"+(try id("taskID"));method="PATCH"}
   if let notes=fields["notes"] {body["notes"]=notes}
  case .contactUpdate:
   url="https://people.googleapis.com/v1/people/"+(try id("contactID"))+":updateContact?updatePersonFields=names";method="PATCH"
   body=["etag":try value("etag"),"metadata":["sources":[["type":"CONTACT","id":try id("sourceID"),"etag":try value("sourceEtag")]]],"names":[["givenName":try value("givenName"),"familyName":fields["familyName"] ?? ""]]]
  }
  var request=URLRequest(url:URL(string:url)!);request.httpMethod=method;request.timeoutInterval=30;request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=try JSONSerialization.data(withJSONObject:body);return request
 }
}
