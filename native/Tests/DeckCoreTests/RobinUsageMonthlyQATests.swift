import XCTest
@testable import DeckCore

final class RobinUsageMonthlyQATests: XCTestCase {
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  private func record(_ model: String, input: Int? = 100, output: Int? = 90) -> RobinUsageRecord {
    .init(timestamp: date("2026-11-03T12:00:00Z"), selectedModelID: "astra", actualModelID: model, providerID: "fixture", inputTokens: input, outputTokens: output, durationMilliseconds: 10, outcome: .success)
  }
  func testActualProviderAndReasoningSubsetDeterminePrice() throws {
    var value = record("sol")
    value.cachedInputTokens = 40
    value.reasoningOutputTokens = 70
    // 60 uncached input +40 cached input +90 TOTAL output; do not add70 thoughts again.
    let inputCost = 60.0 * 2.0
    let cachedCost = 40.0 * 0.1
    let outputCost = 90.0 * 10.0
    let expectedCost = (inputCost + cachedCost + outputCost) / 1_000_000.0
    XCTAssertEqual(try XCTUnwrap(RobinPricing.estimate(value)), expectedCost, accuracy: 1e-12)
    value.actualModelID = "unknown"
    XCTAssertNil(RobinPricing.estimate(value), "Do not charge selected Astra when the actual model is unknown")
    XCTAssertNil(RobinPricing.estimate(record("astra", input: nil)))
  }
  func testClaudeCacheCreationRequiresKnownTTLAndChargesCorrectSubsets() throws {
    var value = record("fable", input: 160, output: 90)
    value.cachedInputTokens = 40; value.cacheWriteInputTokens = 20
    XCTAssertNil(RobinPricing.estimate(value), "Unknown cache-write TTL must not silently use base price")
    value.cacheWriteTTLSeconds = 300
    let inputCost = 100.0 * 10.0
    let cachedCost = 40.0 * 0.25
    let outputCost = 90.0 * 50.0
    let fiveMinuteWriteCost = 20.0 * 12.5
    let fiveMinuteCost = (inputCost + cachedCost + fiveMinuteWriteCost + outputCost) / 1_000_000.0
    XCTAssertEqual(try XCTUnwrap(RobinPricing.estimate(value)), fiveMinuteCost, accuracy: 1e-12)
    value.cacheWriteTTLSeconds = 3600
    let oneHourWriteCost = 20.0 * 20.0
    let oneHourCost = (inputCost + cachedCost + oneHourWriteCost + outputCost) / 1_000_000.0
    XCTAssertEqual(try XCTUnwrap(RobinPricing.estimate(value)), oneHourCost, accuracy: 1e-12)
  }
  func testRollingThirtyDaysCrossesGeminiPromotionExpiry() throws {
    var workload = RobinWorkload()
    workload.callsPerDay = 1; workload.inputTokensPerCall = 1_000_000; workload.answerTokensPerCall = 0
    let projection = try XCTUnwrap(RobinUsageMath.projection(modelID: "gemini", workload: workload, from: date("2026-11-03T12:00:00Z"), days: 30))
    XCTAssertEqual(projection.grossUSD, 28*2 + 2*4, accuracy: 1e-9)
    XCTAssertNil(projection.potentialUSDWithEntireDailyFreeAllocation, "Argon has no free API tier")
  }
  func testMonthlyActualsExcludeFutureRecordsAndOtherMonths() {
    let now = date("2026-11-03T12:00:00Z")
    var past = record("local"); past.timestamp = date("2026-11-01T00:00:00Z")
    var future = past; future.timestamp = date("2026-11-04T00:00:00Z")
    var previousMonth = past; previousMonth.timestamp = date("2026-10-31T23:59:59Z")
    XCTAssertEqual(RobinUsageMath.monthRecords([past, future, previousMonth], now: now).count, 1)
  }
  func testInvalidNumericInputsCannotProduceInfinityOrCrashPercentile() {
    var workload = RobinWorkload(); workload.callsPerDay = Double.greatestFiniteMagnitude
    XCTAssertNil(RobinUsageMath.projection(modelID: "astra", workload: workload))
    XCTAssertNil(RobinUsageMath.percentile([1, 2], .nan))
    XCTAssertNil(RobinUsageMath.percentile([], 0.95))
  }
}
