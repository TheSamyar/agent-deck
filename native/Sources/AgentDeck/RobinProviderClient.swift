import Foundation
import Security
import DeckCore

struct RobinProviderReply: Sendable {
  let text: String
  let usage: RobinProviderUsage
  let usageRecordID: UUID
  let durationMilliseconds: Double
}

/// Each actual network attempt creates its own content-free usage record.
/// This client never switches providers: comparisons cannot silently fall back.
final class RobinProviderClient: @unchecked Sendable {
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
  static let shared = RobinProviderClient()
  private let transport: Transport
  init(transport: Transport? = nil) {
    self.transport = transport ?? { request in
      let (data,response) = try await SupervisorNetwork.shared.session.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw RobinProviderError("No HTTP response from provider.",category:"networkError") }
      return (data,http)
    }
  }
  func complete(modelID: String, messages: [[String:String]], schema: [String:Any], credential: String? = nil,
    cloudflareAccountID: String = "", selectedModelID: String? = nil, retryIndex: Int = 0,
    benchmarkRunID: String? = nil, benchmarkCaseID: Int? = nil, maxOutputTokens: Int = 4096) async throws -> RobinProviderReply {
    guard let model = RobinModelCatalog.model(modelID) else { throw RobinProviderError("Unknown Alfred model.",category:"configurationError") }
    if model.providerID != "local", !messages.allSatisfy({ RobinReasoningPolicy.permitsCloud(text:$0["content"] ?? "") }) { throw RobinProviderError("Cloud context contains credential-like data. Use local mode or remove that data.",category:"configurationError") }
    let settings = UserDefaults.standard.data(forKey:"supervisor.configuration").flatMap { try? JSONDecoder().decode(SupervisorConfiguration.self,from:$0) }
    guard RobinModelCatalog.permits(providerID:model.providerID,subscriptionOnly:settings?.robinSubscriptionOnly == true) else { throw RobinProviderError("Subscription-only mode blocks API provider requests.",category:"configurationError") }
    if RobinModelCatalog.subscriptionProviderIDs.contains(model.providerID) {
      return try await RobinChatGPTSubscription.shared.complete(messages:messages,schema:schema,benchmarkRunID:benchmarkRunID,benchmarkCaseID:benchmarkCaseID,modelID:modelID)
    }
    let key = credential ?? RobinProviderKeychain.load(providerID:model.providerID)
    let request = try RobinProviderCodec.request(model:model,messages:messages,schema:schema,credential:key,
      cloudflareAccountID:cloudflareAccountID,maxOutputTokens:maxOutputTokens)
    let started = ProcessInfo.processInfo.systemUptime
    let id = UUID()
    var actualAPIModelID: String?
    var actualCatalogID = modelID
    func record(usage: RobinProviderUsage, outcome: RobinUsageOutcome, structured: Bool?) {
      RobinUsageLedger.shared.record(.init(id:id, selectedModelID:selectedModelID ?? modelID,actualModelID:actualCatalogID,
        providerID:model.providerID,wireModelID:model.modelID,actualAPIModelID:actualAPIModelID,inputTokens:usage.inputTokens,outputTokens:usage.outputTokens,
        cachedInputTokens:usage.cachedInputTokens,cacheWriteInputTokens:usage.cacheWriteInputTokens,
        reasoningOutputTokens:usage.reasoningOutputTokens,cacheWriteTTLSeconds:usage.cacheWriteTTLSeconds,durationMilliseconds:(ProcessInfo.processInfo.systemUptime-started)*1000,
        outcome:outcome,structuredValid:structured,benchmarkRunID:benchmarkRunID,benchmarkCaseID:benchmarkCaseID,benchmarkSuiteVersion:benchmarkRunID == nil ? nil : "robin-planning-v1",retryIndex:retryIndex))
    }
    do {
      let (data,response) = try await transport(request)
      if data.count < 4_000_000, let json=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] { actualAPIModelID=((json["model"] as? String) ?? (json["modelVersion"] as? String)).map { String($0.prefix(128)) } }
      if (200..<300).contains(response.statusCode), let reported=actualAPIModelID {
        let expected=model.modelID
        let dateSuffix=reported.hasPrefix(expected + "-") ? String(reported.dropFirst(expected.count + 1)) : ""
        let datedAlias=dateSuffix.range(of:"^[0-9]{4}-[0-9]{2}-[0-9]{2}$",options:.regularExpression) != nil
        let cloudflareAlias=model.providerID == "cloudflare" && reported == expected.replacingOccurrences(of:"@cf/",with:"")
        if reported != expected && !datedAlias && !cloudflareAlias {
          actualCatalogID=RobinModelCatalog.all.first { $0.providerID == model.providerID && $0.modelID == reported }?.id ?? "unknown-model:\(model.providerID)"
          let raw=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
          throw RobinProviderError("Provider reported a different model than requested; this attempt is not credited to the selected model.",statusCode:response.statusCode,usage:RobinProviderCodec.usage(model:model,json:raw))
        }
      }
      let elapsed=(ProcessInfo.processInfo.systemUptime-started)*1000
      let result=try RobinProviderCodec.decode(model:model,data:data,statusCode:response.statusCode,durationMilliseconds:elapsed)
      record(usage:result.usage,outcome:.success,structured:true)
      return .init(text:result.text,usage:result.usage,usageRecordID:id,durationMilliseconds:elapsed)
    } catch let error as RobinProviderError {
      record(usage:error.usage,outcome:error.category == "httpError" ? .httpError : error.category == "networkError" ? .networkError : .invalidResponse,structured:error.category == "httpError" ? nil : false)
      throw error
    } catch {
      let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
      let timedOut = (error as? URLError)?.code == .timedOut
      record(usage:.init(),outcome:cancelled ? .cancelled : timedOut ? .timeout : .networkError,structured:nil)
      if cancelled { throw CancellationError() }
      throw RobinProviderError(timedOut ? "Provider request timed out." : "Provider network request failed.",category:timedOut ? "timeout" : "networkError")
    }
  }
}

/// Credentials are scoped by hosting provider, never by an editable endpoint.
enum RobinProviderKeychain {
  private static func query(_ providerID: String) -> [String:Any] {
    if providerID == "groq" { return [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.aiagentdeck.robin.groq",kSecAttrAccount as String:"free-api-key"] }
    return [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.aiagentdeck.robin.provider.\(providerID)",kSecAttrAccount as String:"api-key"]
  }
  static func hasCredential(providerID: String) -> Bool {
    guard RobinModelCatalog.credentialProviders.contains(providerID) else { return providerID == "local" }
    var q=query(providerID);q[kSecMatchLimit as String]=kSecMatchLimitOne
    return SecItemCopyMatching(q as CFDictionary,nil) == errSecSuccess
  }
  static func load(providerID: String) -> String {
    guard RobinModelCatalog.credentialProviders.contains(providerID) else { return "" }
    var q=query(providerID);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
    var value:CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary,&value)==errSecSuccess,let data=value as? Data else { return "" }
    return String(decoding:data,as:UTF8.self)
  }
  static func save(_ value: String, providerID: String) throws {
    guard RobinModelCatalog.credentialProviders.contains(providerID), !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw RobinProviderError("Choose a provider and enter its key.",category:"configurationError") }
    let q=query(providerID)
    let status=SecItemUpdate(q as CFDictionary,[kSecValueData as String:Data(value.utf8)] as CFDictionary)
    if status == errSecItemNotFound {
      var item=q;item[kSecValueData as String]=Data(value.utf8);item[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(item as CFDictionary,nil)==errSecSuccess else { throw RobinProviderError("Could not save provider key in Keychain.",category:"configurationError") }
    } else if status != errSecSuccess { throw RobinProviderError("Could not update provider key in Keychain.",category:"configurationError") }
  }
}
