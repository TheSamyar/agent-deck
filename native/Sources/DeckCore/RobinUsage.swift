import Foundation

public enum RobinUsageOutcome: String, Codable, Sendable { case success, httpError, invalidResponse, cancelled, networkError, timeout }

/// Metadata only. Output counts include reasoning tokens; cached/write counts are subsets of total input.
public struct RobinUsageRecord: Codable, Identifiable, Sendable, Equatable {
  public var id: UUID
  public var timestamp: Date
  public var selectedModelID: String
  public var actualModelID: String
  public var actualAPIModelID: String?
  public var wireModelID: String?
  public var providerID: String
  public var inputTokens: Int?
  public var outputTokens: Int?
  public var cachedInputTokens: Int?
  public var cacheWriteInputTokens: Int?
  public var cacheWriteTTLSeconds: Int?
  public var reasoningOutputTokens: Int?
  public var durationMilliseconds: Double
  public var timeToFirstTokenMilliseconds: Double?
  public var outcome: RobinUsageOutcome
  public var structuredValid: Bool?
  public var verifiedTaskPassed: Bool?
  public var benchmarkRunID: String?
  public var benchmarkSuiteVersion: String?
  public var benchmarkCaseID: Int?
  public var retryIndex: Int
  public var pricingVersion: String
  public init(id: UUID = UUID(), timestamp: Date = Date(), selectedModelID: String, actualModelID: String, providerID: String, wireModelID: String? = nil, actualAPIModelID: String? = nil,
    inputTokens: Int? = nil, outputTokens: Int? = nil, cachedInputTokens: Int? = nil, cacheWriteInputTokens: Int? = nil,
    reasoningOutputTokens: Int? = nil, cacheWriteTTLSeconds: Int? = nil, durationMilliseconds: Double, timeToFirstTokenMilliseconds: Double? = nil,
    outcome: RobinUsageOutcome, structuredValid: Bool? = nil, verifiedTaskPassed: Bool? = nil,
    benchmarkRunID: String? = nil, benchmarkCaseID: Int? = nil, benchmarkSuiteVersion: String? = nil, retryIndex: Int = 0, pricingVersion: String = "2026-11-03") {
    self.id=id; self.timestamp=timestamp; self.selectedModelID=selectedModelID; self.actualModelID=actualModelID; self.wireModelID=wireModelID; self.actualAPIModelID=actualAPIModelID; self.providerID=providerID
    self.inputTokens=inputTokens; self.outputTokens=outputTokens; self.cachedInputTokens=cachedInputTokens
    self.cacheWriteInputTokens=cacheWriteInputTokens; self.cacheWriteTTLSeconds=cacheWriteTTLSeconds; self.reasoningOutputTokens=reasoningOutputTokens
    self.durationMilliseconds=durationMilliseconds; self.timeToFirstTokenMilliseconds=timeToFirstTokenMilliseconds
    self.outcome=outcome; self.structuredValid=structuredValid; self.verifiedTaskPassed=verifiedTaskPassed
    self.benchmarkRunID=benchmarkRunID; self.benchmarkCaseID=benchmarkCaseID; self.benchmarkSuiteVersion=benchmarkSuiteVersion; self.retryIndex=retryIndex; self.pricingVersion=pricingVersion
  }
}

public struct RobinTokenPrice: Codable, Sendable, Equatable {
  public var input: Double
  public var output: Double
  public var cachedInput: Double?
  public var cacheWriteInput: Double?
  public var source: String
}
public enum RobinPricing {
  public static let version = "2026-11-03"
  public static let modelIDs = ["astra","fable","sol","opus","gemini","cloudflare","groq","local"]
  public static func rate(modelID: String, at date: Date = Date()) -> RobinTokenPrice? {
    let openAI="https://developers.openai.com/api/docs/pricing"
    let claude="https://platform.claude.com/docs/en/about-claude/pricing"
    switch modelID {
    case "astra": return .init(input:10,output:50,cachedInput:1,source:openAI)
    case "sol": return .init(input:2,output:10,cachedInput:0.1,source:openAI)
    case "fable": return .init(input:10,output:50,cachedInput:0.25,cacheWriteInput:12.5,source:claude)
    case "opus": return .init(input:4,output:20,cachedInput:0.2,cacheWriteInput:5,source:claude)
    case "gemini":
      let full = date >= Date(timeIntervalSince1970:1796083200) // 2026-12-01T00:00:00Z
      return .init(input:full ? 4:2,output:full ? 20:10,cachedInput:full ? 0.2:0.1,source:"https://aistudio.google.com/docs/pricing")
    case "cloudflare": return .init(input:0.35,output:0.75,source:"https://developers.cloudflare.com/workers-ai/models/gpt-oss-120b/")
    case "groq": return .init(input:0.15,output:0.6,source:"https://console.groq.com/docs/models")
    case "local": return .init(input:0,output:0,source:"https://ollama.com/library/qwen3.5")
    default: return nil
    }
  }
  /// A model-price estimate, not a reconciled invoice. Missing token usage remains unknown.
  public static func estimate(_ record: RobinUsageRecord) -> Double? {
    guard record.pricingVersion == version, let rate=rate(modelID:record.actualModelID,at:record.timestamp),
      let input=record.inputTokens, let output=record.outputTokens, input>=0,output>=0 else { return nil }
    let cached=record.cachedInputTokens ?? 0, written=record.cacheWriteInputTokens ?? 0
    guard cached>=0,written>=0,cached<=input,written<=input-cached,
      record.reasoningOutputTokens.map({ $0>=0 && $0<=output }) != false else { return nil }
    let writeRate: Double
    if written > 0 {
      guard [300,3600].contains(record.cacheWriteTTLSeconds ?? 0), let standardWrite=rate.cacheWriteInput else { return nil }
      writeRate = record.cacheWriteTTLSeconds == 3600 ? rate.input*2 : standardWrite
    } else { writeRate=rate.input }
    return (Double(input-cached-written)*rate.input+Double(cached)*(rate.cachedInput ?? rate.input)
      + Double(written)*writeRate+Double(output)*rate.output)/1_000_000
  }
}

public struct RobinWorkload: Codable, Sendable, Equatable {
  public var callsPerDay: Double = 100
  public var inputTokensPerCall: Double = 5000
  public var answerTokensPerCall: Double = 1000
  public var reasoningTokensPerCall: Double = 0
  public var cachedInputFraction: Double = 0
  public init() {}
}
public struct RobinProjection: Codable, Sendable, Equatable {
  public var modelID: String
  public var grossUSD: Double
  public var potentialUSDWithEntireDailyFreeAllocation: Double?
  public var dailyFreeQuotaNote: String?
}
public enum RobinUsageMath {
  public static var utc: Calendar { var c=Calendar(identifier:.gregorian); c.timeZone=TimeZone(secondsFromGMT:0)!; return c }
  public static func projection(modelID:String,workload:RobinWorkload,from:Date=Date(),days:Int=30) -> RobinProjection? {
    guard (1...366).contains(days), [workload.callsPerDay,workload.inputTokensPerCall,workload.answerTokensPerCall,workload.reasoningTokensPerCall,workload.cachedInputFraction].allSatisfy({ $0.isFinite && $0>=0 }),workload.cachedInputFraction<=1 else { return nil }
    var total=0.0, freeTotal=0.0
    let input=workload.inputTokensPerCall*workload.callsPerDay
    let output=(workload.answerTokensPerCall+workload.reasoningTokensPerCall)*workload.callsPerDay
    guard input.isFinite, output.isFinite else { return nil }
    for offset in 0..<days {
      guard let day=utc.date(byAdding:.day,value:offset,to:utc.startOfDay(for:from)),let rate=RobinPricing.rate(modelID:modelID,at:day) else { return nil }
      let cost=(input*((1-workload.cachedInputFraction)*rate.input+workload.cachedInputFraction*(rate.cachedInput ?? rate.input))+output*rate.output)/1e6
      guard cost.isFinite else { return nil }
      total+=cost
      guard total.isFinite else { return nil }
      if modelID=="cloudflare" {
        let neurons=input/1e6*31818+output/1e6*68182
        freeTotal+=max(0,cost-min(neurons,10000)*0.011/1000)
      }
    }
    let note: String?
    switch modelID {
    case "cloudflare": note="10,000 Neurons/day UTC shared across account. Free-plan limit stops requests; paid-plan overages may bill. Remaining allowance is unknown."
    case "groq": note="Free plan: 1,000 requests/day, 200,000 tokens/day and 8,000 tokens/minute. Shared account limits and scheduling matter; no monthly token pool."
    default: note=nil
    }
    return .init(modelID:modelID,grossUSD:total,potentialUSDWithEntireDailyFreeAllocation:modelID=="cloudflare" ? freeTotal:nil,dailyFreeQuotaNote:note)
  }
  public static func percentile(_ values:[Double],_ fraction:Double) -> Double? {
    guard fraction.isFinite else { return nil }
    let sorted=values.filter { $0.isFinite && $0>=0 }.sorted()
    guard !sorted.isEmpty else { return nil }
    let f=min(1,max(0,fraction)); return sorted[max(0,Int(ceil(Double(sorted.count)*f))-1)]
  }
  public static func monthRecords(_ values:[RobinUsageRecord],now:Date=Date()) -> [RobinUsageRecord] {
    guard let range=utc.dateInterval(of:.month,for:now) else { return [] }
    return values.filter { $0.timestamp>=range.start && $0.timestamp<range.end && $0.timestamp<=now }
  }
}
