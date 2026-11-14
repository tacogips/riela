import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class SpeechToTextContractTests: XCTestCase {
  func testParserDefaultsAndValidation() throws {
    let chain = try SpeechToTextOptionsParser.parse([:])
    XCTAssertEqual(chain.primary.provider, .openai)
    XCTAssertEqual(chain.primary.model, "gpt-4o-transcribe")
    XCTAssertEqual(chain.fallbackOn, SpeechFailureClass.fallbackEligible)
    XCTAssertFalse(chain.cacheAcceptsFallback)
    let invalid: [JSONObject] = [
      ["provider": .string("x")], ["provider": .string("gemini")],
      ["provider": .string("whisper-cpp")], ["fallback": .array([])],
      ["fallbackOn": .array([.string("rejected")])],
      ["whisperCpp": .object(["model": .string("m")])]
    ]
    for options in invalid { XCTAssertThrowsError(try SpeechToTextOptionsParser.parse(options)) }
    let command: JSONValue = .object(["provider": .string("command"), "command": .array([.string("w")])])
    let badFallbacks: [JSONValue] = [
      .array([.null]), .array([command, command, command, command]),
      .array([.object(["provider": .string("apple"), "fallback": .array([])])]),
      .array([.object(["provider": .string("apple"), "unknown": .bool(true)])])
    ]
    for value in badFallbacks { XCTAssertThrowsError(try SpeechToTextOptionsParser.parse(["fallback": value])) }
    let invalidPolicies: [[JSONValue]] = [[], [.string("rejected")], [.string("rate-limited"), .string("rate-limited")]]
    for value in invalidPolicies {
      XCTAssertThrowsError(try SpeechToTextOptionsParser.parse(["fallback": .array([command]), "fallbackOn": .array(value)]))
    }
    for value in [JSONValue.integer(0), .integer(65)] {
      XCTAssertThrowsError(try SpeechToTextOptionsParser.parse(["provider": .string("whisper-cpp"), "whisperCpp": .object(["model": .string("m"), "threads": value])]))
    }
    XCTAssertThrowsError(try SpeechToTextOptionsParser.parse(["provider": .string("whisper-cpp"), "whisperCpp": .object(["model": .string("m"), "foo": .bool(true)])]))
    XCTAssertEqual(try SpeechToTextOptionsParser.parse(["provider": .string("openrouter"), "model": .string("m")]).primary.model, "m")
    let local = try SpeechToTextOptionsParser.parse([
      "provider": .string("whisper-cpp"), "whisperCpp": .object(["model": .string("/m.bin")])
    ])
    XCTAssertEqual(local.primary.whisperCpp?.model, "/m.bin")
    XCTAssertTrue(local.usesWhisperCpp)
    let fallback = try SpeechToTextOptionsParser.parse([
      "fallback": .array([.object(["provider": .string("command"), "command": .array([.string("w"), .string("{{path}}")])])])
    ])
    XCTAssertEqual(fallback.fallback.first?.command, ["w", "{{path}}"])
    XCTAssertTrue(fallback.environmentAllowlist.allowsCommandPrefix)
    XCTAssertEqual(fallback.environmentAllowlist.keys, ["OPENAI_API_KEY", "OPENAI_BASE_URL"])
  }

  func testClassifier() {
    func classify(_ status: Int, _ body: String) -> SpeechProviderFailure {
      SpeechFailureClassifier.classify(httpStatus: status, body: Data(body.utf8), retryAfter: nil, label: "test")
    }
    XCTAssertEqual(classify(429, #"{"error":{"code":"insufficient_quota"}}"#).failureClass, .quotaExhausted)
    XCTAssertEqual(classify(429, #"{"error":{"code":"credit_balance_exhausted"}}"#).failureClass, .quotaExhausted)
    XCTAssertEqual(classify(429, #"{"error":{"code":"rate_limit_exceeded"}}"#).failureClass, .rateLimited)
    XCTAssertEqual(classify(402, "").failureClass, .quotaExhausted)
    let daily = #"{"error":{"status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"requestsPerDay"}]}]}}"#
    XCTAssertTrue(SpeechFailureClassifier.isGeminiDailyQuota(Data(daily.utf8)))
    XCTAssertFalse(SpeechFailureClassifier.isGeminiDailyQuota(Data(daily.replacingOccurrences(of: "PerDay", with: "PerMinute").utf8)))
    XCTAssertFalse(SpeechFailureClassifier.isGeminiDailyQuota(Data("invalid".utf8)))
    XCTAssertEqual(classify(429, daily).failureClass, .quotaExhausted)
    XCTAssertEqual(classify(429, daily).providerProblem, "RESOURCE_EXHAUSTED")
    XCTAssertEqual(classify(429, daily.replacingOccurrences(of: "PerDay", with: "PerMinute")).failureClass, .rateLimited)
    XCTAssertEqual(classify(503, "sk-secret").failureClass, .serverError)
    XCTAssertFalse(classify(503, "sk-secret").message.contains("sk-secret"))
    XCTAssertEqual(classify(401, "").failureClass, .rejected)
  }
}

private actor RetryRecorder {
  var attempts = 0
  var delays: [Double] = []
  func fail(_ kind: SpeechFailureClass, retryAfter: Double? = nil) throws -> String {
    attempts += 1
    throw SpeechProviderFailure(failureClass: kind, httpStatus: nil, providerProblem: nil,
                                retryAfter: retryAfter, message: "failure")
  }
  func record(_ delay: Double) { delays.append(delay) }
}

extension SpeechToTextContractTests {
  func testRetryPolicy() async throws {
    let recorder = RetryRecorder()
    do {
      let _: String = try await SpeechRetry.run(maxAttempts: 3, deadline: nil,
        sleep: { await recorder.record($0) }, operation: { _ in try await recorder.fail(.rateLimited) })
      XCTFail("expected failure")
    } catch is SpeechProviderFailure { }
    let attempts = await recorder.attempts
    let delays = await recorder.delays
    XCTAssertEqual(attempts, 3)
    XCTAssertEqual(delays, [1, 2])
    let quota = RetryRecorder()
    do {
      let _: String = try await SpeechRetry.run(maxAttempts: 3, deadline: nil,
        sleep: { await quota.record($0) }, operation: { _ in try await quota.fail(.quotaExhausted) })
      XCTFail("expected failure")
    } catch is SpeechProviderFailure { }
    let quotaAttempts = await quota.attempts
    let quotaDelays = await quota.delays
    XCTAssertEqual(quotaAttempts, 1)
    XCTAssertTrue(quotaDelays.isEmpty)
  }
  func testRetryAfterDeadlineAndCancellation() async throws {
    for (retryAfter, expected) in [(0.0, 0.0), (120.0, 60.0)] {
      let recorder = RetryRecorder()
      do {
        let _: String = try await SpeechRetry.run(maxAttempts: 3, deadline: nil,
          sleep: { await recorder.record($0) }, operation: { _ in try await recorder.fail(.rateLimited, retryAfter: retryAfter) })
        XCTFail("expected failure")
      } catch is SpeechProviderFailure { }
      let delays = await recorder.delays
      XCTAssertEqual(delays, [expected, expected])
    }
    let recorder = RetryRecorder()
    let now = Date(timeIntervalSince1970: 0)
    do {
      let _: String = try await SpeechRetry.run(maxAttempts: 3, deadline: now.addingTimeInterval(1), now: { now },
        sleep: { await recorder.record($0) }, operation: { _ in try await recorder.fail(.serverError) })
      XCTFail("expected failure")
    } catch is SpeechProviderFailure { }
    let attempts = await recorder.attempts
    let delays = await recorder.delays
    XCTAssertEqual(attempts, 1)
    XCTAssertTrue(delays.isEmpty)
    do {
      let _: String = try await SpeechRetry.run(maxAttempts: 3, deadline: nil, operation: { _ in throw CancellationError() })
      XCTFail("expected cancellation")
    } catch is CancellationError { }
  }

}
