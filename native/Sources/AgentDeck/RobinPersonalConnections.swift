import Foundation
import Security
import DeckCore

private final class PersonalOAuthProcess: @unchecked Sendable {
 let lock=NSLock();var process:Process?;var cancelled=false
 func cancel() {lock.withLock {cancelled=true;if let process,process.isRunning {process.terminate()}}}
}
actor RobinPersonalConnections {
  static let shared = RobinPersonalConnections()
  private var stored:[RobinPersonalAccount] {
    get {UserDefaults.standard.data(forKey:"robin.personal.accounts").flatMap {try? JSONDecoder().decode([RobinPersonalAccount].self,from:$0)} ?? []}
    set {if let data=try? JSONEncoder().encode(newValue) {UserDefaults.standard.set(data,forKey:"robin.personal.accounts")}}
  }
  func accounts()->[RobinPersonalAccount] {stored}
  func configure(_ account:RobinPersonalAccount) {var all=stored;all.removeAll{$0.id==account.id};all.append(account);stored=all}
  func disconnect(_ id:String) {tokenTasks[id]?.1.cancel();tokenTasks.removeValue(forKey:id);stored=stored.filter{$0.id != id};PersonalCredential.remove(id)}
  func connect(provider:String,label:String,clientID:String,clientSecret:String = "",sources:Set<RobinPersonalSource>,allowWrites:Bool = false) async throws {
    guard ["google","slack"].contains(provider), !clientID.isEmpty, !sources.isEmpty, sources.allSatisfy({$0.provider==provider}) else {throw RobinPersonalRequest.failure("Enter an OAuth client ID and select sources for this provider.")}
    var account=RobinPersonalAccount(label:label.isEmpty ? provider : label,provider:provider,sources:sources)
    account.canWrite=allowWrites;account.grantedSources=sources
    let scopes=Set(sources.map(\.scope)).union(allowWrites ? Set(RobinPersonalWrite.allCases.filter{sources.contains($0.source)}.map(\.scope)) : [])
    let bundle=Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Jarvis/personal-oauth.py")
    let debug=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Jarvis/personal-oauth.py")
    let helper=FileManager.default.fileExists(atPath:bundle.path) ? bundle : debug
    let payload=try JSONSerialization.data(withJSONObject:["provider":provider,"clientID":clientID,"clientSecret":clientSecret,"scopes":Array(scopes)])
    let owner=PersonalOAuthProcess()
    let token=try await withTaskCancellationHandler {
      try await Task.detached { () throws -> Data in
      let p=Process(),input=Pipe(),output=Pipe();p.executableURL=URL(fileURLWithPath:"/usr/bin/python3");p.arguments=[helper.path];p.standardInput=input;p.standardOutput=output;p.standardError=FileHandle.nullDevice
      p.environment=ProcessInfo.processInfo.environment.filter{["HOME","PATH","USER","LANG","TMPDIR"].contains($0.key)}
      guard owner.lock.withLock({if owner.cancelled {return false};owner.process=p;return true}) else {throw CancellationError()}
      defer {owner.lock.withLock {owner.process=nil}}
      try p.run()
      if owner.lock.withLock({owner.cancelled}) {p.terminate();p.waitUntilExit();throw CancellationError()}
      let deadline=DispatchWorkItem {if p.isRunning {p.terminate()}}
      DispatchQueue.global().asyncAfter(deadline:.now()+220,execute:deadline)
      defer {deadline.cancel();if p.isRunning {p.terminate();p.waitUntilExit()}}
      try input.fileHandleForWriting.write(contentsOf:payload);try input.fileHandleForWriting.close()
      var data=Data()
      while let chunk=try output.fileHandleForReading.read(upToCount:4096),!chunk.isEmpty {
        data.append(chunk)
        if data.count>100000 {p.terminate();p.waitUntilExit();throw RobinPersonalRequest.failure("OAuth response exceeded its limit.")}
      }
      p.waitUntilExit()
      guard p.terminationStatus==0,data.count<100000 else {throw RobinPersonalRequest.failure("Sign-in did not complete. Check the OAuth application setup and consent.")};return data
    }.value
    } onCancel: {owner.cancel()}
    try Task.checkCancellation()
    guard var json=(try JSONSerialization.jsonObject(with:token)) as? [String:Any],json["access_token"] is String else {throw RobinPersonalRequest.failure("The provider did not return an access token.")}
    if let granted=json["scope"] as? String {
      let grantedSet=Set(granted.split(whereSeparator:{$0==" " || $0==","}).map(String.init))
      guard scopes.allSatisfy({scope in scope.split(separator:",").allSatisfy{grantedSet.contains(String($0))}}) else {throw RobinPersonalRequest.failure("The provider did not grant all selected scopes. Reconnect with consent for those sources.")}
    } else {throw RobinPersonalRequest.failure("The provider did not confirm granted scopes. Reconnect before enabling sources.")}
    json["client_id"]=clientID;if !clientSecret.isEmpty {json["client_secret"]=clientSecret}
    json["expires_at"]=Date().timeIntervalSince1970 + ((json["expires_in"] as? Double) ?? (provider == "slack" ? Date.distantFuture.timeIntervalSinceNow : 3600))
    try Task.checkCancellation()
    try PersonalCredential.save(try JSONSerialization.data(withJSONObject:json),id:account.id);configure(account)
  }
  private var drafts:[UUID:RobinPersonalDraft]=[:]
  func prepare(accountID:String,operation:RobinPersonalWrite,fields:[String:String]) throws -> RobinPersonalDraft {
    guard let account=stored.first(where:{$0.id==accountID}),account.sources.contains(operation.source) else {throw RobinPersonalRequest.failure("Enable this account/source before preparing a draft.")}
    guard fields.count<=20,fields.allSatisfy({$0.key.count<=100 && $0.value.count<=32000}),fields.values.reduce(0,{$0+$1.count})<=100000 else {throw RobinPersonalRequest.failure("Prepared change exceeds its size limit.")}
    let draft=RobinPersonalDraft(accountID:accountID,operation:operation,fields:fields)
    _ = try draft.request()
    if drafts.count>=50,let oldest=drafts.values.min(by:{$0.createdAt<$1.createdAt}) {drafts.removeValue(forKey:oldest.id)}
    drafts[draft.id]=draft
    return draft
  }
  func preparedDrafts()->[RobinPersonalDraft] {drafts.values.sorted{$0.createdAt>$1.createdAt}}
  /// Call only from the app's explicit confirmation UI; never expose as a model tool.
  func executeConfirmedDraft(id:UUID,revision:UUID) async throws -> String {
    guard let draft=drafts[id],draft.revision==revision,Date().timeIntervalSince(draft.createdAt)<900,
      let account=stored.first(where:{$0.id==draft.accountID}),account.sources.contains(draft.operation.source),account.canWrite==true else {throw RobinPersonalRequest.failure("Draft expired or write access is unavailable. Reconnect with write scopes if needed.")}
    if draft.operation == .slackPost, !account.slackChannels.contains(draft.fields["channel"] ?? "") {throw RobinPersonalRequest.failure("Select this Slack channel before posting.")}
    drafts.removeValue(forKey:id) // single-use confirmation is consumed before any asynchronous work
    let key=try await token(account)
    guard stored.contains(account) else {throw RobinPersonalRequest.failure("Account or draft changed. Review again.")}
    var request=try draft.request();request.setValue("Bearer "+key,forHTTPHeaderField:"Authorization")
    // Network uncertainty never retries automatically.
    let (data,response)=try await SupervisorNetwork.shared.session.data(for:request)
    guard let response=response as? HTTPURLResponse,(200..<300).contains(response.statusCode),data.count<2000000 else {throw RobinPersonalRequest.failure("External change was not verified. Check the provider before retrying.")}
    if draft.operation == .slackPost,let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],value["ok"] as? Bool != true {throw RobinPersonalRequest.failure("Slack rejected the confirmed change.")}
    return "Provider accepted the confirmed change. " + String(decoding:data,as:UTF8.self).prefix(4000)
  }
  private var tokenTasks:[String:(UUID,Task<String,Error>)]=[:]
  private func token(_ account:RobinPersonalAccount) async throws -> String {
    if let existing=tokenTasks[account.id] {return try await existing.1.value}
    let id=UUID();let task=Task {try await self.fetchToken(account)};tokenTasks[account.id]=(id,task)
    defer {if tokenTasks[account.id]?.0==id {tokenTasks.removeValue(forKey:account.id)}}
    return try await task.value
  }
  private func fetchToken(_ account:RobinPersonalAccount) async throws -> String {
    guard let credentialData=PersonalCredential.load(account.id),var value=(try? JSONSerialization.jsonObject(with:credentialData)) as? [String:Any],let access=value["access_token"] as? String else {throw RobinPersonalRequest.failure("Reconnect \(account.label): no credential is available.")}
    if (value["expires_at"] as? Double ?? 0)>Date().timeIntervalSince1970+60 {return access}
    guard let refresh=value["refresh_token"] as? String,let client=value["client_id"] as? String else {throw RobinPersonalRequest.failure("Reconnect \(account.label): its authorization expired.")}
    var form=["grant_type":"refresh_token","refresh_token":refresh,"client_id":client]
    if account.provider=="google",let secret=value["client_secret"] as? String {form["client_secret"]=secret}
    var request=URLRequest(url:URL(string:account.provider=="google" ? "https://oauth2.googleapis.com/token" : "https://slack.com/api/oauth.v2.access")!);request.httpMethod="POST";request.timeoutInterval=20
    let encoded=form.map{ $0.key.addingPercentEncoding(withAllowedCharacters:.alphanumerics)!+"="+$0.value.addingPercentEncoding(withAllowedCharacters:.alphanumerics)! }.joined(separator:"&");request.httpBody=encoded.data(using:.utf8);request.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
    let (data,response)=try await SupervisorNetwork.shared.session.data(for:request)
    guard (response as? HTTPURLResponse)?.statusCode==200,let envelope=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else {throw RobinPersonalRequest.failure("Reconnect \(account.label): token refresh failed.")}
    let updated = account.provider == "slack" ? ((envelope["authed_user"] as? [String:Any]) ?? envelope) : envelope
    guard let newToken=updated["access_token"] as? String else {throw RobinPersonalRequest.failure("Reconnect \(account.label): token refresh failed.")}
    guard stored.contains(account) else {throw RobinPersonalRequest.failure("Account access changed while refreshing. Retry using its current settings.")}
    for (k,v) in updated {value[k]=v};value["expires_at"]=Date().timeIntervalSince1970 + ((updated["expires_in"] as? Double) ?? 3600)
    try PersonalCredential.save(try JSONSerialization.data(withJSONObject:value),id:account.id);return newToken
  }
  func read(accountID:String,source:RobinPersonalSource,query:String,resourceID:String? = nil) async throws -> RobinPersonalResult {
    guard let account=stored.first(where:{$0.id==accountID}),account.sources.contains(source),account.provider==source.provider else {throw RobinPersonalRequest.failure("This account has not enabled the requested personal source.")}
    let key=try await token(account)
    let channels=source == .slack ? account.slackChannels : [""]
    guard !channels.isEmpty else {throw RobinPersonalRequest.failure("Select Slack channels before searching.")}
    var parts:[String]=[]
    for channel in channels.prefix(30) {
      var request=try RobinPersonalRequest.request(source:source,query:query,resourceID:resourceID,channels:source == .slack ? [channel] : [])
      request.setValue("Bearer "+key,forHTTPHeaderField:"Authorization")
      let (data,response)=try await SupervisorNetwork.shared.session.data(for:request)
      guard let http=response as? HTTPURLResponse else {throw RobinPersonalRequest.failure("The personal source did not return a valid response.")}
      guard http.statusCode==200 else {throw RobinPersonalRequest.failure("\(source.rawValue) request failed (HTTP \(http.statusCode)). Reconnect if access was revoked; retry later if rate limited.")}
      guard data.count<=2_000_000 else {throw RobinPersonalRequest.failure("The result is too large. Narrow the query.")}
      if source == .slack,let json=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],json["ok"] as? Bool != true {throw RobinPersonalRequest.failure("Slack rejected the request. Check scopes, workspace access, and selected channels.")}
      guard stored.contains(account) else {throw RobinPersonalRequest.failure("Account permissions changed while reading. The result was discarded.")}
      if source == .slack {
        guard let json=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let messages=json["messages"] as? [String:Any],let matches=messages["matches"] as? [[String:Any]] else {throw RobinPersonalRequest.failure("Slack returned no readable message result.")}
        let approved=matches.filter { match in guard let info=match["channel"] as? [String:Any] else {return false};return info["name"] as? String == channel || info["id"] as? String == channel }
        parts.append(String(decoding:try JSONSerialization.data(withJSONObject:approved),as:UTF8.self))
      } else if source == .gmail, let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
        if resourceID == nil,let messages=object["messages"] as? [[String:Any]] {
          for item in messages.prefix(5) {if let messageID=item["id"] as? String {parts.append(try await read(accountID:accountID,source:.gmail,query:"",resourceID:messageID).text)}}
        } else {
          func plain(_ payload:[String:Any])->String {
            var text=""
            if payload["mimeType"] as? String == "text/plain",let body=payload["body"] as? [String:Any],var encoded=body["data"] as? String {
              encoded=encoded.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/");encoded += String(repeating:"=",count:(4-encoded.count%4)%4)
              if let decoded=Data(base64Encoded:encoded) {text=String(decoding:decoded,as:UTF8.self)}
            }
            for part in payload["parts"] as? [[String:Any]] ?? [] {text += plain(part)}
            return text
          }
          let payload=object["payload"] as? [String:Any] ?? [:]
          let headers=(payload["headers"] as? [[String:String]] ?? []).filter{["subject","from","to","date"].contains(($0["name"] ?? "").lowercased())}
          let rendered:[String:Any]=["id":object["id"] ?? "","headers":headers,"snippet":object["snippet"] ?? "","text":String(plain(payload).prefix(16000))]
          parts.append(String(decoding:try JSONSerialization.data(withJSONObject:rendered),as:UTF8.self))
        }
      } else {parts.append(String(decoding:data,as:UTF8.self))}
    }
    guard stored.contains(account) else {throw RobinPersonalRequest.failure("Account permissions changed; result discarded.")}
    return .init(accountID:accountID,source:source,text:String(parts.joined(separator:"\n").prefix(24000)))
  }
}
private enum PersonalCredential {
  static func query(_ id:String)->[String:Any] {[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.aiagentdeck.personal.oauth",kSecAttrAccount as String:id]}
  static func save(_ data:Data,id:String) throws {
    let q=query(id);let status=SecItemUpdate(q as CFDictionary,[kSecValueData as String:data] as CFDictionary)
    if status==errSecItemNotFound {var item=q;item[kSecValueData as String]=data;item[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;guard SecItemAdd(item as CFDictionary,nil)==errSecSuccess else {throw RobinPersonalRequest.failure("Could not store OAuth credentials in Keychain.")}}
    else if status != errSecSuccess {throw RobinPersonalRequest.failure("Could not update OAuth credentials in Keychain.")}
  }
  static func load(_ id:String)->Data? {var q=query(id);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne;var value:CFTypeRef?;guard SecItemCopyMatching(q as CFDictionary,&value)==errSecSuccess else{return nil};return value as? Data}
  static func remove(_ id:String) {SecItemDelete(query(id) as CFDictionary)}
}
