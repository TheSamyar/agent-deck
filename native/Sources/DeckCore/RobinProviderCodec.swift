import Foundation
import CoreFoundation

/// Provider-specific wire shapes. Endpoints are fixed; credentials never enter URLs.
public enum RobinProviderCodec {
  public static func request(model: RobinModelCatalog.Model, messages: [[String:String]], schema: [String:Any], credential: String, cloudflareAccountID: String = "", localThinking: Bool = false, maxOutputTokens: Int = 4096) throws -> URLRequest {
    guard (64...4096).contains(maxOutputTokens) else { throw RobinProviderError("Output budget must be between 64 and 4096 tokens.", category:"configurationError") }
    guard !messages.isEmpty else { throw RobinProviderError("A model request needs messages.", category:"configurationError") }
    if model.providerID != "local", credential.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { throw RobinProviderError("Add the \(model.providerID) key in Alfred settings.",category:"configurationError") }
    let url: URL
    var body: [String:Any]
    let systems = messages.filter { ["system","developer"].contains($0["role"] ?? "") }.compactMap { $0["content"] }.joined(separator:"\n\n")
    switch model.providerID {
    case "openai":
      url=URL(string:"https://api.openai.com/v1/responses")!
      body=["model":model.modelID,"input":messages,"stream":false,"store":false,"max_output_tokens":maxOutputTokens,"reasoning":["effort":"medium"],"text":["format":["type":"json_schema","name":"robin_step","strict":true,"schema":schema]]]
    case "anthropic":
      url=URL(string:"https://api.anthropic.com/v1/messages")!
      let turns = messages.filter { ["user","assistant"].contains($0["role"] ?? "") }
      body=["model":model.modelID,"system":systems,"messages":turns,"stream":false,"max_tokens":maxOutputTokens,"output_config":["format":["type":"json_schema","schema":schema]]]
    case "gemini":
      url=URL(string:"https://generativelanguage.googleapis.com/v1beta/models/\(model.modelID):generateContent")!
      let contents: [[String:Any]] = messages.filter { ["user","assistant"].contains($0["role"] ?? "") }.map { ["role":$0["role"] == "assistant" ? "model" : "user","parts":[["text":$0["content"] ?? ""]]] }
      body=["contents":contents,"systemInstruction":["parts":[["text":systems]]],"generationConfig":["responseMimeType":"application/json","responseJsonSchema":schema,"maxOutputTokens":maxOutputTokens]]
    case "cloudflare":
      guard cloudflareAccountID.count == 32, cloudflareAccountID.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw RobinProviderError("Enter a valid Cloudflare account ID in Alfred settings.",category:"configurationError") }
      url=URL(string:"https://api.cloudflare.com/client/v4/accounts/\(cloudflareAccountID)/ai/v1/chat/completions")!
      body=["model":model.modelID,"messages":messages,"stream":false,"max_tokens":maxOutputTokens,"response_format":["type":"json_object"]]
    case "groq":
      url=URL(string:"https://api.groq.com/openai/v1/chat/completions")!
      body=["model":model.modelID,"messages":messages,"stream":false,"max_completion_tokens":maxOutputTokens,"response_format":["type":"json_object"]]
    case "local":
      url=URL(string:"http://127.0.0.1:11434/api/chat")!
      body=["model":model.modelID,"messages":messages,"stream":false,"think":localThinking,"format":schema,"keep_alive":"10m","options":["num_ctx":16384,"num_predict":min(maxOutputTokens,localThinking ? 4000 : 2000),"temperature":0]]
    default: throw RobinProviderError("Unsupported provider.",category:"configurationError")
    }
    var request=URLRequest(url:url); request.httpMethod="POST"; request.timeoutInterval=90
    request.setValue("application/json",forHTTPHeaderField:"Content-Type")
    switch model.providerID {
    case "anthropic":request.setValue(credential,forHTTPHeaderField:"x-api-key");request.setValue("2023-06-01",forHTTPHeaderField:"anthropic-version")
    case "gemini":request.setValue(credential,forHTTPHeaderField:"x-goog-api-key")
    case "local":break
    default:request.setValue("Bearer "+credential,forHTTPHeaderField:"Authorization")
    }
    request.httpBody=try JSONSerialization.data(withJSONObject:body)
    return request
  }

  public static func decode(model: RobinModelCatalog.Model, data: Data, statusCode: Int, durationMilliseconds: Double = 0) throws -> RobinProviderResult {
    guard data.count < 4_000_000 else { throw RobinProviderError("Model response exceeded the size limit.",statusCode:statusCode) }
    let json=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
    let usage=usage(model:model,json:json)
    guard (200..<300).contains(statusCode) else { throw RobinProviderError("\(model.providerID) request failed (HTTP \(statusCode)). Check account access, quota and credentials.",statusCode:statusCode,usage:usage,category:"httpError") }
    guard !json.isEmpty, json["error"] == nil, json["success"] as? Bool != false else { throw RobinProviderError("\(model.providerID) returned an error or invalid JSON.",statusCode:statusCode,usage:usage) }
    let content: String
    switch model.providerID {
    case "openai":
      guard json["status"] as? String == "completed" else { throw RobinProviderError("The model response was incomplete. No action was executed.",statusCode:statusCode,usage:usage) }
      content=(json["output"] as? [[String:Any]] ?? []).filter { $0["type"] as? String == "message" }.flatMap { $0["content"] as? [[String:Any]] ?? [] }.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined(separator:"\n")
    case "anthropic":
      guard ["end_turn","stop_sequence"].contains(json["stop_reason"] as? String ?? "") else { throw RobinProviderError("Claude response stopped before a complete structured answer.",statusCode:statusCode,usage:usage) }
      content=(json["content"] as? [[String:Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator:"\n")
    case "gemini":
      let first=(json["candidates"] as? [[String:Any]])?.first
      guard first?["finishReason"] as? String == "STOP" else { throw RobinProviderError("Gemini returned an incomplete or blocked answer.",statusCode:statusCode,usage:usage) }
      content=((first?["content"] as? [String:Any])?["parts"] as? [[String:Any]] ?? []).filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined(separator:"\n")
    case "local":
      guard json["done_reason"] as? String != "length" else { throw RobinProviderError("Local answer exhausted its output budget.",statusCode:statusCode,usage:usage) }
      content=(json["message"] as? [String:Any])?["content"] as? String ?? ""
    default:
      let choice=(json["choices"] as? [[String:Any]])?.first
      guard choice?["finish_reason"] as? String == "stop" else { throw RobinProviderError("Model answer was truncated or blocked.",statusCode:statusCode,usage:usage) }
      content=(choice?["message"] as? [String:Any])?["content"] as? String ?? ""
    }
    guard !content.isEmpty, (try? JarvisStep.decode(Data(content.utf8))) != nil else { throw RobinProviderError("\(model.providerID) returned no valid Alfred step. No action was executed.",statusCode:statusCode,usage:usage) }
    return .init(text:content,usage:usage,durationMilliseconds:durationMilliseconds,statusCode:statusCode)
  }

  public static func usage(model: RobinModelCatalog.Model,json:[String:Any]) -> RobinProviderUsage {
    func number(_ value: Any?) -> Int? { guard let n=value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue.rounded(.towardZero) == n.doubleValue, n.doubleValue < Double(Int.max) else { return nil }; return n.intValue }
    func sum(_ items: Int?...) -> Int? { guard items.contains(where: { $0 != nil }) else { return nil }; var total=0; for item in items.compactMap({ $0 }) { let result=total.addingReportingOverflow(item); if result.overflow { return nil }; total=result.partialValue }; return total }
    let u=json["usage"] as? [String:Any] ?? [:]
    switch model.providerID {
    case "openai":return .init(inputTokens:number(u["input_tokens"]),outputTokens:number(u["output_tokens"]),cachedInputTokens:number((u["input_tokens_details"] as? [String:Any])?["cached_tokens"]),cacheWriteInputTokens:number((u["input_tokens_details"] as? [String:Any])?["cache_write_tokens"]),reasoningOutputTokens:number((u["output_tokens_details"] as? [String:Any])?["reasoning_tokens"]))
    case "anthropic":
      let creation=u["cache_creation"] as? [String:Any] ?? [:]
      let writes=number(u["cache_creation_input_tokens"])
      let ttl: Int? = writes.flatMap { total in
        guard total > 0 else { return nil }
        if number(creation["ephemeral_5m_input_tokens"]) == total { return 300 }
        if number(creation["ephemeral_1h_input_tokens"]) == total { return 3600 }
        return nil
      }
      let malformedCache = ["cache_read_input_tokens", "cache_creation_input_tokens"].contains { u[$0] != nil && number(u[$0]) == nil }
      return .init(inputTokens:number(u["input_tokens"]) == nil || malformedCache ? nil : sum(number(u["input_tokens"]),number(u["cache_read_input_tokens"]),number(u["cache_creation_input_tokens"])),outputTokens:number(u["output_tokens"]),cachedInputTokens:number(u["cache_read_input_tokens"]),cacheWriteInputTokens:writes,cacheWriteTTLSeconds:ttl)
    case "gemini":let g=json["usageMetadata"] as? [String:Any] ?? [:]; return .init(inputTokens:number(g["promptTokenCount"]) == nil ? nil : sum(number(g["promptTokenCount"]),number(g["toolUsePromptTokenCount"])),outputTokens:number(g["candidatesTokenCount"]) == nil || (g["thoughtsTokenCount"] != nil && number(g["thoughtsTokenCount"]) == nil) ? nil : sum(number(g["candidatesTokenCount"]),number(g["thoughtsTokenCount"])),cachedInputTokens:number(g["cachedContentTokenCount"]),reasoningOutputTokens:number(g["thoughtsTokenCount"]))
    case "local":return .init(inputTokens:number(json["prompt_eval_count"]),outputTokens:number(json["eval_count"]))
    default:return .init(inputTokens:number(u["prompt_tokens"]),outputTokens:number(u["completion_tokens"]),cachedInputTokens:number((u["prompt_tokens_details"] as? [String:Any])?["cached_tokens"]),reasoningOutputTokens:number((u["completion_tokens_details"] as? [String:Any])?["reasoning_tokens"]))
    }
  }
}
