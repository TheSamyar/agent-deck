import Foundation
import Security
import DeckCore

final class SupervisorNetwork: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  static let shared = SupervisorNetwork()
  private let reasoningModeLock = NSLock()
  private var reasoningCircuitModel = ""
  private var directStructuredMode = false
  func retryLocalReasoning() { reasoningModeLock.withLock { directStructuredMode = false } }

  lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

  func chat(configuration: SupervisorConfiguration, key: String, messages: [[String: String]], format: SupervisorResponseFormat? = nil) async throws -> (String, Int?) {
    guard configuration.robinSubscriptionOnly != true || configuration.backend == .local else { throw problem("Subscription-only mode blocks cloud API chat. Choose a subscription brain.") }
    guard let url = configuration.validatedURL, !configuration.model.isEmpty else { throw problem("Choose a model and valid endpoint in Setup.") }
    if configuration.robinSubscriptionOnly == true, !["127.0.0.1","localhost","::1"].contains(url.host ?? "") { throw problem("Subscription-only mode permits only local voice/chat endpoints.") }
    if configuration.backend == .cloud && key.isEmpty { throw problem("Add a cloud API key in Setup.") }
    var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 180
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if configuration.backend == .cloud { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
    var body: [String: Any] = ["model": configuration.model, "messages": messages, "stream": false]
    if configuration.backend == .local && url.port == 11434 {
      body["reasoning_effort"] = "none"
      body["max_tokens"] = 1200
    }
    if let format { body["response_format"] = format.requestValue }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let started=ProcessInfo.processInfo.systemUptime
    let trustedProvider=url.host == "api.openai.com" ? "openai" : url.host == "api.groq.com" ? "groq" : ""
    let catalog=RobinModelCatalog.all.first { $0.modelID == configuration.model && $0.providerID == trustedProvider }
    let metricID=catalog?.id ?? (configuration.backend == .local ? "local" : "legacy-cloud-chat")
    let host=url.host ?? ""
    let provider=configuration.backend == .local ? "local" : host == "api.openai.com" ? "openai" : "legacy-cloud"
    var usage=RobinProviderUsage(), outcome=RobinUsageOutcome.networkError
    var actualAPIModelID: String?
    defer {
      RobinUsageLedger.shared.record(.init(selectedModelID:metricID,actualModelID:metricID,providerID:provider,
        wireModelID:configuration.model,actualAPIModelID:actualAPIModelID,inputTokens:usage.inputTokens,
        outputTokens:usage.outputTokens,cachedInputTokens:usage.cachedInputTokens,reasoningOutputTokens:usage.reasoningOutputTokens,
        durationMilliseconds:(ProcessInfo.processInfo.systemUptime-started)*1000,outcome:outcome))
    }
    let data: Data
    let response: URLResponse
    do { (data,response)=try await session.data(for:request) }
    catch {
      outcome = error is CancellationError || (error as? URLError)?.code == .cancelled ? .cancelled : (error as? URLError)?.code == .timedOut ? .timeout : .networkError
      if outcome == .cancelled { throw CancellationError() }
      throw problem("Chat provider network request failed.")
    }
    let json=data.count < 4_000_000 ? (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] : nil
    if let json {
      usage=RobinProviderCodec.usage(model:RobinModelCatalog.model("groq")!,json:json)
      actualAPIModelID=(json["model"] as? String).map { String($0.prefix(128)) }
    }
    guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else {
      outcome = .httpError
      throw problem("Model request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Check your model, key, and account access.")
    }
    outcome = .invalidResponse
    guard let body=json, let choices=body["choices"] as? [[String:Any]],let choice=choices.first,
      choice["finish_reason"] as? String != "length", let message=choice["message"] as? [String:Any],
      let reply=message["content"] as? String,!reply.isEmpty else { throw problem("The model returned no complete readable reply.") }
    outcome = .success
    return (reply,(body["usage"] as? [String:Any])?["total_tokens"] as? Int)
  }

  @MainActor func reason(configuration: SupervisorConfiguration, key: String, messages: [[String:String]], cloudMessages: [[String:String]], schema: [String:Any], preferCloud: Bool, cloudAllowed: Bool, onRouting: (String)->Void, onReceipt: ((RobinReasoningReceipt)->Void)? = nil, subscriptionComplete: (([[String:String]], [String:Any], String) async throws -> RobinProviderReply)? = nil) async throws -> String {
    let selectedID = configuration.robinProviderID ?? (configuration.robinHybridEnabled == true ? "groq" : "local")
    let started = ProcessInfo.processInfo.systemUptime
    var actualModelID: String?
    var receiptOutcome = RobinReasoningReceipt.Outcome.failed
    var usageRecordID: UUID?
    defer {
      onReceipt?(.init(selectedModelID: selectedID, actualModelID: actualModelID,
        outcome: Task.isCancelled ? .cancelled : receiptOutcome,
        durationMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000,
        usageRecordID: usageRecordID))
    }
    let selected = RobinModelCatalog.model(selectedID)
    guard let selected, RobinModelCatalog.permits(providerID:selected.providerID,subscriptionOnly:configuration.robinSubscriptionOnly == true) else {
      throw problem("Subscription-only mode blocks this API provider. Choose Codex, Claude, Gemini, Cursor or local.")
    }
    let explicitSelection = configuration.robinProviderID != nil
    let allowedPaid = configuration.robinPaidProvidersConfirmed ?? []
    let consent = { (model: RobinModelCatalog.Model) -> Bool in
      if model.requiresPaidConsent { return allowedPaid.contains(model.providerID) }
      if model.providerID == "groq" { return configuration.robinFreePlanConfirmed == true || allowedPaid.contains("groq") }
      if model.providerID == "cloudflare" { return configuration.robinCloudflareFreePlanConfirmed == true || allowedPaid.contains("cloudflare") }
      return true
    }(selected)
    if selected.providerID != "local", (preferCloud || explicitSelection), cloudAllowed,
      configuration.robinHybridEnabled == true, consent,
      cloudMessages.allSatisfy({ RobinReasoningPolicy.permitsCloud(text: $0["content"] ?? "") }) {
      do {
        if RobinModelCatalog.subscriptionProviderIDs.contains(selected.providerID) {
          onRouting("\(selected.name) · official sign-in · plan limits apply")
          let reply: RobinProviderReply
          if let subscriptionComplete { reply = try await subscriptionComplete(cloudMessages, schema, selected.id) }
          else { reply = try await RobinChatGPTSubscription.shared.complete(messages:cloudMessages,schema:schema,modelID:selected.id) }
          try Task.checkCancellation()
          actualModelID = selected.id; usageRecordID = reply.usageRecordID; receiptOutcome = .success
          return reply.text
        }
        let reply = try await RobinProviderClient.shared.complete(modelID:selected.id,messages:cloudMessages,schema:schema,
          credential:selected.providerID == "groq" && !key.isEmpty ? key : nil,
          cloudflareAccountID:configuration.robinCloudflareAccountID ?? "",selectedModelID:selectedID)
        onRouting("\(selected.name) · approved project context")
        actualModelID = selected.id; usageRecordID = reply.usageRecordID; receiptOutcome = .success
        return reply.text
      } catch is CancellationError { receiptOutcome = .cancelled; throw CancellationError() }
      catch {
        if explicitSelection && selected.providerID == "chatgpt" {
          onRouting("Codex failed · no local fallback")
          throw problem("Codex could not answer: " + error.localizedDescription + " No local model was substituted.")
        }
        onRouting("Selected provider unavailable; continuing locally. Comparison benchmarks never use this fallback.")
      }
    } else {
      if explicitSelection && selected.providerID == "chatgpt" {
        receiptOutcome = .blocked
        onRouting("Codex blocked · no local fallback")
        throw problem(cloudAllowed
          ? "Codex is selected, but cloud reasoning is disabled or this request contains protected data. Enable the selected brain or revise the request. No local model was substituted."
          : "Codex is selected, but this project's context is not approved for Codex. In Alfred Settings, approve this project's context for ChatGPT subscription, or select an approved project. No local model was substituted.")
      }
      onRouting(selectedID == "local" ? "Local reasoning · no cloud context sent" : "Local fallback · selected provider needs credentials, destination permission and account consent")
    }
    let model = configuration.robinReasoningModel ?? "qwen3.5:9b"
    let direct = reasoningModeLock.withLock {
      if reasoningCircuitModel != model { reasoningCircuitModel = model; directStructuredMode = false }
      return directStructuredMode
    }
    if direct { onRouting("Local direct mode after reasoning truncation · retry reasoning explicitly in settings") }
    for attempt in 0..<(direct ? 1 : 2) {
      let thinking = !direct && attempt == 0
      let attemptID = UUID()
      let attemptStart = ProcessInfo.processInfo.systemUptime
      var attemptUsage = RobinProviderUsage()
      var attemptOutcome = RobinUsageOutcome.networkError
      var structured: Bool? = nil
      var actualAPIModelID: String?
      defer {
        RobinUsageLedger.shared.record(.init(id:attemptID,selectedModelID:selectedID,actualModelID:"local",providerID:"local",wireModelID:model,actualAPIModelID:actualAPIModelID,
          inputTokens:attemptUsage.inputTokens,outputTokens:attemptUsage.outputTokens,
          cachedInputTokens:attemptUsage.cachedInputTokens,reasoningOutputTokens:attemptUsage.reasoningOutputTokens,
          durationMilliseconds:(ProcessInfo.processInfo.systemUptime-attemptStart)*1000,outcome:attemptOutcome,
          structuredValid:structured,retryIndex:attempt + (selectedID == "local" ? 0 : 1)))
      }
      var request = URLRequest(url: URL(string:"http://127.0.0.1:11434/api/chat")!)
      request.httpMethod = "POST"; request.timeoutInterval = thinking ? 30 : 90
      request.setValue("application/json",forHTTPHeaderField:"Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject:["model":model, "stream":false,"think":thinking,"format":schema,"messages":messages,"keep_alive":"10m","options":["num_ctx":16384,"num_predict":thinking ? 4000 : 2000,"temperature":0]])
      let data: Data
      let response: URLResponse
      do { (data, response) = try await session.data(for: request) }
      catch is CancellationError { attemptOutcome = .cancelled; throw CancellationError() }
      catch {
        attemptOutcome = (error as? URLError)?.code == .cancelled ? .cancelled : (error as? URLError)?.code == .timedOut ? .timeout : .networkError
        if attemptOutcome == .cancelled { throw CancellationError() }
        if thinking, (error as? URLError)?.code == .timedOut {
          reasoningModeLock.withLock { if reasoningCircuitModel == model { directStructuredMode = true } }
          onRouting("Local thinking exceeded 30 seconds. Switching to direct structured mode; no action replayed.")
          continue
        }
        throw error
      }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      let parsed = data.count < 4_000_000 ? (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] : nil
      if let parsed { attemptUsage=RobinProviderCodec.usage(model:RobinModelCatalog.model("local")!,json:parsed); actualAPIModelID=(parsed["model"] as? String).map { String($0.prefix(128)) } }
      if status != 200 { attemptOutcome = .httpError }
      guard status == 200 else { throw problem("Local reasoning request failed (HTTP \(status)). No action was executed from this response.") }
      attemptOutcome = .invalidResponse; structured = false
      guard let json=parsed else { throw problem("Local reasoning returned an oversized or invalid response.") }
      let message = json["message"] as? [String:Any]
      let content = message?["content"] as? String ?? ""
      if !content.isEmpty, json["done_reason"] as? String != "length", (try? JarvisStep.decode(Data(content.utf8))) != nil { attemptOutcome = .success; structured = true; actualModelID = "local"; usageRecordID = attemptID; receiptOutcome = .success
        return content }
      if thinking {
        reasoningModeLock.withLock { if reasoningCircuitModel == model { directStructuredMode = true } }
        let count = json["eval_count"] as? Int ?? 0
        let reason = ["length", "stop"].contains(json["done_reason"] as? String ?? "") ? json["done_reason"] as? String ?? "other" : "other"
        onRouting("Local structured answer unavailable (tokens: \(count), finish: \(reason), thinking present: \(!(message?["thinking"] as? String ?? "").isEmpty)). Retrying once directly; no action replayed.")
        continue
      }
      let count = json["eval_count"] as? Int ?? 0
      let thinkingPresent = !(message?["thinking"] as? String ?? "").isEmpty
      throw problem("Local reasoning produced no valid structured step after one bounded retry (tokens: \(count), thinking present: \(thinkingPresent)). No action was executed from this response.")
    }
    throw problem("Local reasoning budget exhausted.")
  }

  func problem(_ message: String) -> NSError { NSError(domain: "Supervisor", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

enum SupervisorKeychain {
  private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.aiagentdeck.supervisor", kSecAttrAccount as String: "cloud-api-key"] }
  static func load() -> String {
    var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
    return String(decoding: data, as: UTF8.self)
  }
  static func save(_ value: String) throws {
    if value.isEmpty {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else { throw SupervisorNetwork.shared.problem("Could not remove the API key from Keychain.") }
      return
    }
    let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var item = query; item[kSecValueData as String] = Data(value.utf8)
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SupervisorNetwork.shared.problem("Could not save the API key to Keychain.") }
    } else if status != errSecSuccess { throw SupervisorNetwork.shared.problem("Could not update the API key in Keychain.") }
  }
}

// Separate credential namespace: existing cloud chat keys are never sent to Groq.
enum RobinReasoningKeychain {
  private static var query: [String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.aiagentdeck.robin.groq",kSecAttrAccount as String:"free-api-key"] }
  static func load() -> String {
    var q=query;q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
    var value:CFTypeRef?;guard SecItemCopyMatching(q as CFDictionary,&value)==errSecSuccess,let data=value as? Data else{return ""};return String(decoding:data,as:UTF8.self)
  }
  static func save(_ key:String) throws {
    let status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:Data(key.utf8)] as CFDictionary)
    if status==errSecItemNotFound {var q=query;q[kSecValueData as String]=Data(key.utf8);q[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;guard SecItemAdd(q as CFDictionary,nil)==errSecSuccess else{throw SupervisorNetwork.shared.problem("Could not save Groq key.")}}
    else if status != errSecSuccess {throw SupervisorNetwork.shared.problem("Could not update Groq key.")}
  }
}
