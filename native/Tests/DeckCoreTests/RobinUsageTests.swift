import XCTest
@testable import DeckCore

final class RobinUsageTests: XCTestCase {
  func testUnknownUsageIsNotFreeAndReasoningIsNotDoubleCounted() throws {
    var value=RobinUsageRecord(selectedModelID:"astra",actualModelID:"astra",providerID:"openai",durationMilliseconds:100,outcome:.success)
    XCTAssertNil(RobinPricing.estimate(value))
    value.inputTokens=1000; value.outputTokens=1000; value.reasoningOutputTokens=700
    XCTAssertEqual(try XCTUnwrap(RobinPricing.estimate(value)),0.06,accuracy:0.0000001)
    value.cachedInputTokens=500
    XCTAssertEqual(try XCTUnwrap(RobinPricing.estimate(value)),0.0555,accuracy:0.0000001)
    value.cachedInputTokens=1001
    XCTAssertNil(RobinPricing.estimate(value))
  }
  func testProjectionWeightsGeminiPromoExpiryAndDailyFreeAllowance() throws {
    var workload=RobinWorkload(); workload.callsPerDay=1;workload.inputTokensPerCall=1_000_000;workload.answerTokensPerCall=0
    let start=try XCTUnwrap(ISO8601DateFormatter().date(from:"2026-11-20T12:00:00Z"))
    let result=try XCTUnwrap(RobinUsageMath.projection(modelID:"gemini",workload:workload,from:start,days:30))
    XCTAssertEqual(result.grossUSD,11*2+19*4,accuracy:0.00001)
    let free=try XCTUnwrap(RobinUsageMath.projection(modelID:"cloudflare",workload:workload,from:start,days:30))
    XCTAssertEqual(free.grossUSD,10.5,accuracy:0.00001)
    XCTAssertEqual(try XCTUnwrap(free.potentialUSDWithEntireDailyFreeAllocation),7.2,accuracy:0.00001)
  }
  func testCacheWritesNeedKnownTTLAndMonthExcludesNextMonth() throws {
    var value=RobinUsageRecord(selectedModelID:"fable",actualModelID:"fable",providerID:"anthropic",inputTokens:1000,outputTokens:0,cacheWriteInputTokens:1000,durationMilliseconds:1,outcome:.success)
    XCTAssertNil(RobinPricing.estimate(value))
    value.cacheWriteTTLSeconds=300
    XCTAssertEqual(try XCTUnwrap(RobinPricing.estimate(value)),0.0125,accuracy:0.0000001)
    value.cacheWriteTTLSeconds=3600
    XCTAssertEqual(try XCTUnwrap(RobinPricing.estimate(value)),0.02,accuracy:0.0000001)
    let f=ISO8601DateFormatter(); let now=try XCTUnwrap(f.date(from:"2026-11-30T23:59:59Z"))
    value.timestamp=try XCTUnwrap(f.date(from:"2026-12-01T00:00:00Z"))
    XCTAssertTrue(RobinUsageMath.monthRecords([value],now:now).isEmpty)
  }
  func testPercentilesIgnoreInvalidSamples() {
    XCTAssertNil(RobinUsageMath.percentile([],0.95))
    XCTAssertEqual(RobinUsageMath.percentile([10,20,30,40,-1,.infinity],0.5),20)
    XCTAssertEqual(RobinUsageMath.percentile([10,20,30,40],0.95),40)
  }
}
