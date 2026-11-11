import XCTest
@testable import DeckCore

final class RobinProviderTests: XCTestCase {
  private let messages = [["role":"system","content":"Return JSON"],["role":"user","content":"Status?"]]
  func testEveryPickerModelHasItsRealProtocolAndScopedAuthentication() throws {
    XCTAssertEqual(Set(RobinModelCatalog.all.map(\.id)), Set(["astra","sol","fable","opus","gemini","cloudflare","groq","local","chatgpt","claude-subscription","gemini-subscription","cursor-subscription"]))
    let subscription = try XCTUnwrap(RobinModelCatalog.model("chatgpt"))
    XCTAssertThrowsError(try RobinProviderCodec.request(model:subscription,messages:messages,schema:JarvisStep.schema,credential:"fixture-only-key"))
    for model in RobinModelCatalog.all.filter({ !RobinModelCatalog.subscriptionProviderIDs.contains($0.providerID) }) {
      let request=try RobinProviderCodec.request(model:model,messages:messages,schema:JarvisStep.schema,credential:"fixture-only-key",cloudflareAccountID:String(repeating:"a",count:32),maxOutputTokens:2000)
      let body=try XCTUnwrap(JSONSerialization.jsonObject(with:request.httpBody!) as? [String:Any])
      XCTAssertFalse(request.url!.absoluteString.contains("fixture-only-key"))
      switch model.providerID {
      case "openai":
        XCTAssertEqual(request.url?.absoluteString,"https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer fixture-only-key")
        XCTAssertEqual(body["max_output_tokens"] as? Int,2000)
        XCTAssertEqual(body["store"] as? Bool,false)
        XCTAssertEqual((body["input"] as? [[String:String]])?.last?["content"],"Status?")
      case "anthropic":
        XCTAssertEqual(request.url?.host,"api.anthropic.com")
        XCTAssertEqual(request.value(forHTTPHeaderField:"x-api-key"),"fixture-only-key")
        XCTAssertNil(request.value(forHTTPHeaderField:"Authorization"))
        XCTAssertEqual(body["max_tokens"] as? Int,2000)
        XCTAssertEqual(body["system"] as? String,"Return JSON")
        XCTAssertEqual((body["messages"] as? [[String:String]])?.count,1)
      case "gemini":
        XCTAssertEqual(request.url?.host,"generativelanguage.googleapis.com")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField:"x-goog-api-key"),"fixture-only-key")
        XCTAssertEqual((body["generationConfig"] as? [String:Any])?["maxOutputTokens"] as? Int,2000)
      case "cloudflare":
        XCTAssertEqual(request.url?.host,"api.cloudflare.com")
        XCTAssertTrue(request.url!.path.contains(String(repeating:"a",count:32)))
        XCTAssertEqual(body["model"] as? String,"@cf/openai/gpt-oss-120b")
        XCTAssertEqual(body["max_tokens"] as? Int,2000)
      case "groq":
        XCTAssertEqual(request.url?.host,"api.groq.com")
        XCTAssertEqual(body["max_completion_tokens"] as? Int,2000)
      default:
        XCTAssertEqual(request.url?.host,"127.0.0.1")
        XCTAssertNil(request.value(forHTTPHeaderField:"Authorization"))
        XCTAssertEqual(body["think"] as? Bool,false)
        XCTAssertEqual((body["options"] as? [String:Any])?["num_predict"] as? Int,2000)
      }
    }
  }
  func testProviderSetupErrorsNeverConstructAnUnscopedDestination() throws {
    let model=try XCTUnwrap(RobinModelCatalog.model("cloudflare"))
    for account in ["", "../other-account", "abc?token=secret", String(repeating:"z",count:32)] {
      XCTAssertThrowsError(try RobinProviderCodec.request(model:model,messages:messages,schema:JarvisStep.schema,credential:"fixture",cloudflareAccountID:account))
    }
    XCTAssertThrowsError(try RobinProviderCodec.request(model:RobinModelCatalog.model("astra")!,messages:messages,schema:JarvisStep.schema,credential:""))
    XCTAssertThrowsError(try RobinProviderCodec.request(model:RobinModelCatalog.model("astra")!,messages:messages,schema:JarvisStep.schema,credential:"fixture",maxOutputTokens:8000))
  }
  func testThinkingBlocksAreNotTreatedAsFinalTextAndUsageIsNotDoubleCounted() throws {
    let step="{\"kind\":\"respond\",\"reply\":\"Ready\",\"action\":null,\"arguments\":{}}"
    let fixtures: [(String,[String:Any],Int,Int,Int?)] = [
      ("astra",["status":"completed","output":[["type":"reasoning","content":[["type":"output_text","text":"not the answer"]]],["type":"message","content":[["type":"output_text","text":step]]]],"usage":["input_tokens":100,"output_tokens":40,"input_tokens_details":["cached_tokens":20],"output_tokens_details":["reasoning_tokens":30]]],100,40,30),
      ("fable",["stop_reason":"end_turn","content":[["type":"thinking","thinking":"not the answer"],["type":"text","text":step]],"usage":["input_tokens":70,"cache_read_input_tokens":20,"cache_creation_input_tokens":10,"output_tokens":40]],100,40,nil),
      ("gemini",["candidates":[["finishReason":"STOP","content":["parts":[["thought":true,"text":"not the answer"],["text":step]]]]],"usageMetadata":["promptTokenCount":100,"candidatesTokenCount":10,"thoughtsTokenCount":30,"cachedContentTokenCount":20]],100,40,30)
    ]
    for (id,json,input,output,thoughts) in fixtures {
      let result=try RobinProviderCodec.decode(model:RobinModelCatalog.model(id)!,data:JSONSerialization.data(withJSONObject:json),statusCode:200,durationMilliseconds:123)
      XCTAssertEqual(result.text,step)
      XCTAssertEqual(result.usage.inputTokens,input)
      XCTAssertEqual(result.usage.outputTokens,output)
      XCTAssertEqual(result.usage.reasoningOutputTokens,thoughts)
      XCTAssertNil(result.timeToFirstTokenMilliseconds)
      XCTAssertEqual(result.durationMilliseconds,123)
    }
  }
  func testFailureMessagesNeverEchoProviderSecretsOrPrompts() throws {
    let secret="fixture-password-that-must-not-be-logged"
    let model=RobinModelCatalog.model("groq")!
    do {
      _=try RobinProviderCodec.decode(model:model,data:JSONSerialization.data(withJSONObject:["error":["message":secret]]),statusCode:401)
      XCTFail("HTTP401 must fail")
    } catch { XCTAssertFalse(error.localizedDescription.contains(secret)) }
    let usage=RobinProviderCodec.usage(model:model,json:[:])
    XCTAssertNil(usage.inputTokens); XCTAssertNil(usage.outputTokens)
  }
}
