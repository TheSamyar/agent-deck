import Foundation

public enum RobinModelCatalog {
  public struct Model: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let providerID: String
    public let modelID: String
    public let requiresPaidConsent: Bool
    public init(id: String, name: String, providerID: String, modelID: String, requiresPaidConsent: Bool) {
      self.id=id; self.name=name; self.providerID=providerID; self.modelID=modelID; self.requiresPaidConsent=requiresPaidConsent
    }
  }
  public static let subscriptionProviderIDs: Set<String> = ["chatgpt", "claude-subscription", "gemini-subscription", "cursor-subscription"]
  public static func permits(providerID: String, subscriptionOnly: Bool) -> Bool {
    !subscriptionOnly || providerID == "local" || subscriptionProviderIDs.contains(providerID)
  }
  public static let all: [Model] = [
    .init(id:"chatgpt",name:"ChatGPT subscription · Codex",providerID:"chatgpt",modelID:"subscription-default",requiresPaidConsent:false),
    .init(id:"claude-subscription",name:"Claude subscription · Claude Code",providerID:"claude-subscription",modelID:"subscription-default",requiresPaidConsent:false),
    .init(id:"gemini-subscription",name:"Gemini subscription · Antigravity",providerID:"gemini-subscription",modelID:"subscription-default",requiresPaidConsent:false),
    .init(id:"cursor-subscription",name:"Cursor subscription · Cursor CLI",providerID:"cursor-subscription",modelID:"subscription-default",requiresPaidConsent:false),
    .init(id:"astra",name:"GPT-6 Astra",providerID:"openai",modelID:"gpt-6-astra",requiresPaidConsent:true),
    .init(id:"sol",name:"GPT-6.1 Sol",providerID:"openai",modelID:"gpt-6.1-sol",requiresPaidConsent:true),
    .init(id:"fable",name:"Claude Fable 5.1",providerID:"anthropic",modelID:"claude-fable-5-1",requiresPaidConsent:true),
    .init(id:"opus",name:"Claude Opus 5.5",providerID:"anthropic",modelID:"claude-opus-5-5",requiresPaidConsent:true),
    .init(id:"gemini",name:"Gemini 4 Argon",providerID:"gemini",modelID:"gemini-4-argon",requiresPaidConsent:true),
    .init(id:"cloudflare",name:"GPT-OSS 120B · Cloudflare",providerID:"cloudflare",modelID:"@cf/openai/gpt-oss-120b",requiresPaidConsent:false),
    .init(id:"groq",name:"GPT-OSS 120B · Groq",providerID:"groq",modelID:"openai/gpt-oss-120b",requiresPaidConsent:false),
    .init(id:"local",name:"Qwen 3.5 9B · Local",providerID:"local",modelID:"qwen3.5:9b",requiresPaidConsent:false)
  ]
  public static func model(_ id: String) -> Model? { all.first { $0.id == id } }
  public static let credentialProviders = ["openai", "anthropic", "gemini", "cloudflare", "groq"]
}

/// Totals include cache tokens; cache fields are subsets, not additional tokens.
/// Output includes reasoning; reasoningOutputTokens is a subset, not additive.
public struct RobinProviderUsage: Codable, Sendable, Equatable {
  public var inputTokens: Int?
  public var outputTokens: Int?
  public var cachedInputTokens: Int?
  public var cacheWriteInputTokens: Int?
  public var cacheWriteTTLSeconds: Int?
  public var reasoningOutputTokens: Int?
  public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cachedInputTokens: Int? = nil, cacheWriteInputTokens: Int? = nil, cacheWriteTTLSeconds: Int? = nil, reasoningOutputTokens: Int? = nil) {
    self.inputTokens=inputTokens; self.outputTokens=outputTokens; self.cachedInputTokens=cachedInputTokens; self.cacheWriteInputTokens=cacheWriteInputTokens; self.cacheWriteTTLSeconds=cacheWriteTTLSeconds; self.reasoningOutputTokens=reasoningOutputTokens
  }
}
public struct RobinProviderResult: Sendable {
  public let text: String
  public let usage: RobinProviderUsage
  public let durationMilliseconds: Double
  public let timeToFirstTokenMilliseconds: Double?
  public let statusCode: Int
  public init(text: String, usage: RobinProviderUsage, durationMilliseconds: Double, timeToFirstTokenMilliseconds: Double? = nil, statusCode: Int) {
    self.text=text; self.usage=usage; self.durationMilliseconds=durationMilliseconds; self.timeToFirstTokenMilliseconds=timeToFirstTokenMilliseconds; self.statusCode=statusCode
  }
}
public struct RobinProviderError: Error, LocalizedError, Sendable {
  public let message: String
  public let statusCode: Int?
  public let usage: RobinProviderUsage
  public let category: String
  public init(_ message: String, statusCode: Int? = nil, usage: RobinProviderUsage = .init(), category: String = "invalidResponse") { self.message=message; self.statusCode=statusCode; self.usage=usage; self.category=category }
  public var errorDescription: String? { message }
}
