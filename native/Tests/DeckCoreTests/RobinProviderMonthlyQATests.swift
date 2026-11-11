import XCTest
@testable import DeckCore

final class RobinProviderMonthlyQATests: XCTestCase {
  private let step = "{\"kind\":\"respond\",\"reply\":\"Fixture only\",\"action\":null,\"arguments\":{}}"
  private func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

  func testEveryCredentialStaysInItsOwnHeaderAndNeverURLOrBody() throws {
    let secret = "qa-secret-do-not-log"
    for model in RobinModelCatalog.all.filter({ !RobinModelCatalog.subscriptionProviderIDs.contains($0.providerID) }) {
      let request = try RobinProviderCodec.request(model: model, messages: [["role": "user", "content": "Fixture"]], schema: JarvisStep.schema, credential: secret, cloudflareAccountID: String(repeating: "a", count: 32))
      XCTAssertFalse(request.url!.absoluteString.contains(secret))
      XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains(secret))
      let header = model.providerID == "anthropic" ? "x-api-key" : model.providerID == "gemini" ? "x-goog-api-key" : "Authorization"
      if model.providerID == "local" { XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")) }
      else { XCTAssertTrue(request.value(forHTTPHeaderField: header)?.contains(secret) == true) }
      if header != "Authorization" { XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")) }
    }
  }

  func testIncompleteHTTP200ResponsesNeverBecomeSuccessfulSteps() throws {
    let fixtures: [(String, [String: Any])] = [
      ("astra", ["status": "in_progress", "output": [["type": "message", "content": [["type": "output_text", "text": step]]]]]),
      ("fable", ["content": [["type": "text", "text": step]], "stop_reason": NSNull()]),
      ("groq", ["choices": [["message": ["content": step], "finish_reason": NSNull()]]]),
      ("cloudflare", ["success": false, "choices": [["message": ["content": step], "finish_reason": "stop"]]])
    ]
    for (id, fixture) in fixtures {
      XCTAssertThrowsError(try RobinProviderCodec.decode(model: RobinModelCatalog.model(id)!, data: data(fixture), statusCode: 200), id)
    }
  }

  func testBenchmarkOutputReservationIsEnforcedOnEveryWireFormat() throws {
    for model in RobinModelCatalog.all.filter({ !RobinModelCatalog.subscriptionProviderIDs.contains($0.providerID) }) {
      let request = try RobinProviderCodec.request(model: model, messages: [["role": "user", "content": "Fixture"]], schema: JarvisStep.schema, credential: "fixture", cloudflareAccountID: String(repeating: "a", count: 32), maxOutputTokens: 2000)
      let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
      let budget: Int?
      switch model.providerID {
      case "openai": budget = json["max_output_tokens"] as? Int
      case "anthropic", "cloudflare": budget = json["max_tokens"] as? Int
      case "gemini": budget = (json["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int
      case "groq": budget = json["max_completion_tokens"] as? Int
      default: budget = (json["options"] as? [String: Any])?["num_predict"] as? Int
      }
      XCTAssertEqual(budget, 2000, model.id)
    }
  }

  func testUsageNormalizesReasoningAndCacheWithoutDoubleCounting() {
    let openAI = RobinProviderCodec.usage(model: RobinModelCatalog.model("astra")!, json: ["usage": ["input_tokens": 100, "input_tokens_details": ["cached_tokens": 40], "output_tokens": 90, "output_tokens_details": ["reasoning_tokens": 70]]])
    XCTAssertEqual(openAI.inputTokens, 100)
    XCTAssertEqual(openAI.outputTokens, 90)
    XCTAssertEqual(openAI.reasoningOutputTokens, 70)
    let claude = RobinProviderCodec.usage(model: RobinModelCatalog.model("fable")!, json: ["usage": ["input_tokens": 100, "cache_read_input_tokens": 40, "cache_creation_input_tokens": 20, "output_tokens": 90]])
    XCTAssertEqual(claude.inputTokens, 160)
    let gemini = RobinProviderCodec.usage(model: RobinModelCatalog.model("gemini")!, json: ["usageMetadata": ["promptTokenCount": 100, "cachedContentTokenCount": 40, "candidatesTokenCount": 20, "thoughtsTokenCount": 70]])
    XCTAssertEqual(gemini.inputTokens, 100)
    XCTAssertEqual(gemini.outputTokens, 90)
  }

  func testMissingOrImpossibleUsageIsUnknownInsteadOfZeroOrCrash() {
    for model in RobinModelCatalog.all.filter({ !RobinModelCatalog.subscriptionProviderIDs.contains($0.providerID) }) {
      let missing = RobinProviderCodec.usage(model: model, json: [:])
      XCTAssertNil(missing.inputTokens, model.id)
      XCTAssertNil(missing.outputTokens, model.id)
    }
    let partial = RobinProviderCodec.usage(model: RobinModelCatalog.model("fable")!, json: ["usage": ["cache_read_input_tokens": 40]])
    XCTAssertNil(partial.inputTokens)
    let overflow = RobinProviderCodec.usage(model: RobinModelCatalog.model("fable")!, json: ["usage": ["input_tokens": Int.max, "cache_read_input_tokens": Int.max]])
    XCTAssertNil(overflow.inputTokens)
    let fractional = RobinProviderCodec.usage(model: RobinModelCatalog.model("astra")!, json: ["usage": ["input_tokens": 1.75]])
    XCTAssertNil(fractional.inputTokens)
  }
}
