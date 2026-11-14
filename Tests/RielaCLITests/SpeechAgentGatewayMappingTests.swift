import AgentGateway
import AgentGatewayAppCore
import Foundation
import XCTest
@testable import RielaCLI

private actor StubTranscriber: GatewayTranscribing {
  var params: [GatewayTranscriptionParams] = []
  var delays: [Double] = []
  let failure: (any Error)?
  init(_ failure: (any Error)? = nil) { self.failure = failure }
  func transcribe(_ value: GatewayTranscriptionParams) async throws -> GatewayTranscriptionResult {
    params.append(value)
    if let failure { throw failure }
    return .init(vendor: value.vendor, model: value.model, text: "")
  }
  func sleep(_ value: Double) { delays.append(value) }
}

private struct FailureScenario {
  let error: GatewayTranscriptionFailure
  let kind: SpeechFailureClass
  let problem: String?
  let status: Int
  let calls: Int
  init(_ error: GatewayTranscriptionFailure, _ kind: SpeechFailureClass, _ problem: String?, _ status: Int, _ calls: Int) {
    self.error = error
    self.kind = kind
    self.problem = problem
    self.status = status
    self.calls = calls
  }
}

final class SpeechAgentGatewayMappingTests: XCTestCase {
  private func request(_ provider: SpeechToTextProvider = .openai, base: String? = nil) -> SpeechTranscriptionRequest {
    .init(provider: provider, model: "model", apiKeyEnvironmentName: "OPENAI_API_KEY",
          environment: ["OPENAI_API_KEY": "SECRET-KEY"], baseURL: base,
          audioFile: URL(fileURLWithPath: "/tmp/audio.mp3"), language: "", prompt: "hint", timeoutSeconds: 2.1)
  }

  func testRequestMapping() async throws {
    for (provider, vendor, base, expected) in [
      (SpeechToTextProvider.openai, GatewayVendor.openAI, "https://x.test/v1/", "https://x.test/v1"),
      (.gemini, .gemini, "https://x.test/", "https://x.test"),
      (.openrouter, .openRouter, "https://x.test/", "https://x.test")
    ] {
      let stub = StubTranscriber()
      let gateway = makeAgentGatewaySpeechTranscription { environment in
        XCTAssertEqual(environment, ["OPENAI_API_KEY": "SECRET-KEY"])
        return stub
      }
      let result = try await gateway(request(provider, base: base))
      XCTAssertEqual(result, "")
      let captured = await stub.params
      let params = try XCTUnwrap(captured.first)
      XCTAssertEqual(params.vendor, vendor)
      XCTAssertEqual(params.model, "model")
      XCTAssertEqual(params.baseURL, expected)
      XCTAssertEqual(params.apiKeyEnvironment, "OPENAI_API_KEY")
      XCTAssertEqual(params.mimeType, "audio/mpeg")
      XCTAssertEqual(params.timeoutSeconds, 3)
      XCTAssertNil(params.language)
      XCTAssertEqual(params.prompt, "hint")
    }
  }

  func testStructuredFailuresAndRetry() async throws {
    let daily = #"{"error":{"details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"requestsPerDay"}]}]}}"#
    let scenarios: [FailureScenario] = [
      FailureScenario(.init(vendor: .openAI, classification: .quotaExhausted, httpStatus: 429, vendorErrorCode: "insufficient_quota", message: "SECRET-KEY"), .quotaExhausted, "insufficient_quota", 429, 1),
      FailureScenario(.init(vendor: .openAI, classification: .quotaExhausted, httpStatus: 429, vendorErrorCode: "credit_balance_exhausted", message: "x"), .quotaExhausted, "credit_balance_exhausted", 429, 1),
      FailureScenario(.init(vendor: .openAI, classification: .rateLimited, httpStatus: 429, vendorErrorCode: "billing_hard_limit_reached", message: "x"), .quotaExhausted, "billing_hard_limit_reached", 429, 1),
      FailureScenario(.init(vendor: .gemini, classification: .rateLimited, httpStatus: 429, vendorErrorType: "RESOURCE_EXHAUSTED", vendorErrorCode: "429",
                             rawBody: daily, message: "x"), .quotaExhausted, "RESOURCE_EXHAUSTED", 429, 1),
      FailureScenario(.init(vendor: .gemini, classification: .rateLimited, httpStatus: 429, retryAfterSeconds: 0,
                             vendorErrorType: "RESOURCE_EXHAUSTED", vendorErrorCode: "429", rawBody: "SECRET-BODY", message: "SECRET-KEY"), .rateLimited, "RESOURCE_EXHAUSTED", 429, 3),
      FailureScenario(.init(vendor: .openRouter, classification: .quotaExhausted, httpStatus: 402, vendorErrorCode: "402", message: "x"), .quotaExhausted, nil, 402, 1),
      FailureScenario(.init(vendor: .openAI, classification: .rateLimited, httpStatus: 429, retryAfterSeconds: 0,
                             vendorErrorCode: "rate_limit_exceeded", vendorMessage: "SECRET-KEY", rawBody: "SECRET-BODY", message: "SECRET-KEY"), .rateLimited, "rate_limit_exceeded", 429, 3),
      FailureScenario(.init(vendor: .openAI, classification: .serverError, httpStatus: 503, retryAfterSeconds: 0, message: "x"), .serverError, nil, 503, 3),
      FailureScenario(.init(vendor: .openAI, classification: .authFailed, httpStatus: 401, message: "x"), .rejected, nil, 401, 1)
    ]
    for scenario in scenarios {
      let stub = StubTranscriber(scenario.error)
      let gateway = makeAgentGatewaySpeechTranscription { _ in stub }
      let input = request()
      do {
        let _: String = try await SpeechRetry.run(maxAttempts: 3, deadline: nil, sleep: { await stub.sleep($0) }, operation: { _ in try await gateway(input) })
        XCTFail("expected failure")
      } catch let failure as SpeechProviderFailure {
        XCTAssertEqual(failure.failureClass, scenario.kind)
        XCTAssertEqual(failure.httpStatus, scenario.status)
        XCTAssertEqual(failure.providerProblem, scenario.problem)
        XCTAssertFalse(failure.localizedDescription.contains("SECRET-KEY"))
        XCTAssertFalse(failure.localizedDescription.contains("SECRET-BODY"))
      }
      let count = await stub.params.count
      let delays = await stub.delays
      XCTAssertEqual(count, scenario.calls)
      if scenario.calls == 3 { XCTAssertEqual(delays, [0, 0]) }
    }
  }

  func testRPCAndTransportFailures() async throws {
    for (error, expected): (any Error, SpeechFailureClass) in [
      (GatewayRPCError(code: -32011, message: "SECRET-KEY"), .unavailable),
      (GatewayRPCError(code: -32021, message: "x"), .unavailable),
      (GatewayRPCError(code: -32602, message: "x"), .rejected),
      (GatewayTranscriptionFailure(vendor: .openAI, classification: .transport, message: "SECRET-BODY"), .transportError),
      (URLError(.timedOut), .transportError)
    ] {
      let stub = StubTranscriber(error)
      do {
        _ = try await makeAgentGatewaySpeechTranscription { _ in stub }(request())
        XCTFail("expected failure")
      } catch let failure as SpeechProviderFailure {
        XCTAssertEqual(failure.failureClass, expected)
        XCTAssertFalse(failure.localizedDescription.contains("SECRET"))
      }
    }
  }
}
