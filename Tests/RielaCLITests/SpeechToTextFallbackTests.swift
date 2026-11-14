import Foundation
import RielaAdapters
import RielaCore
import XCTest

@testable import RielaCLI

private actor FallbackGateway {
  let failure: SpeechProviderFailure?
  private(set) var calls = 0
  init(_ failure: SpeechProviderFailure?) { self.failure = failure }
  func transcribe(_ request: SpeechTranscriptionRequest) throws -> String {
    calls += 1
    if let failure { throw failure }
    return "remote text"
  }
}

final class SpeechToTextFallbackTests: XCTestCase {
  private var root: URL!
  private var audio: URL!
  private var model: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    audio = root.appendingPathComponent("audio.wav")
    model = root.appendingPathComponent("model.bin")
    try Data("audio".utf8).write(to: audio)
    try Data("model".utf8).write(to: model)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  private func failure(_ kind: SpeechFailureClass) -> SpeechProviderFailure {
    .init(failureClass: kind, httpStatus: 429,
          providerProblem: kind == .quotaExhausted ? "insufficient_quota" : "rate_limit_exceeded",
          retryAfter: 0, message: "vendor error")
  }
  private func options() -> JSONObject {
    ["path": .string(audio.path), "fallback": .array([.object([
      "provider": .string("whisper-cpp"), "whisperCpp": .object([
        "binary": .string("/bin/echo"), "model": .string(model.path)
      ])
    ])])]
  }
  private func run(
    _ options: JSONObject, gateway: FallbackGateway, key: Bool = true,
    runner: SpeechFakeRunner = SpeechFakeRunner(stdout: "local text")
  ) async throws -> JSONObject {
    let resolver = BuiltinWorkflowAddonResolver(
      environment: key ? ["OPENAI_API_KEY": "api-secret"] : [:], workingDirectory: root,
      containerProcessRunner: runner,
      speechTranscriptionGateway: { request in try await gateway.transcribe(request) })
    let bindings: JSONObject = key ? ["OPENAI_API_KEY": .object(["fromEnv": .string("OPENAI_API_KEY")])] : [:]
    let input = WorkflowAddonExecutionInput(
      workflowId: "speech", stepId: "stt", nodeId: "stt",
      addon: .init(name: "riela/speech-to-text", version: "1",
                   config: ["options": .object(options)], env: bindings), variables: [:])
    let output = try await resolver.execute(input, context: .init())
    guard case .object(let result)? = output.payload["speechToText"] else {
      throw NSError(domain: "FallbackTests", code: 1)
    }
    return result
  }
  private func firstFallback(_ result: JSONObject) throws -> JSONObject {
    guard case .array(let entries)? = result["fallbackFrom"],
      case .object(let first)? = entries.first else { throw NSError(domain: "FallbackTests", code: 2) }
    return first
  }

  func testQuotaFallsBackWithoutRetryAndRecordsFailure() async throws {
    let gateway = FallbackGateway(failure(.quotaExhausted))
    let result = try await run(options(), gateway: gateway)
    XCTAssertEqual(result["provider"], .string("whisper-cpp"))
    XCTAssertEqual(result["model"], .null)
    XCTAssertEqual(result["text"], .string("local text"))
    XCTAssertEqual(try firstFallback(result), [
      "provider": .string("openai"), "model": .string("gpt-4o-transcribe"),
      "failureClass": .string("quota-exhausted"), "httpStatus": .integer(429),
      "providerProblem": .string("insufficient_quota")
    ])
    let calls = await gateway.calls
    XCTAssertEqual(calls, 1)
  }

  func testRateLimitRetriesThenFallsBack() async throws {
    let gateway = FallbackGateway(failure(.rateLimited))
    var input = options()
    input["maxAttempts"] = .integer(3)
    let result = try await run(input, gateway: gateway)
    XCTAssertEqual(try firstFallback(result)["failureClass"], .string("rate-limited"))
    let calls = await gateway.calls
    XCTAssertEqual(calls, 3)
  }

  func testFallbackOnAndSingleQuotaFailure() async throws {
    let rate = FallbackGateway(failure(.rateLimited))
    var input = options()
    input["fallbackOn"] = .array([.string("quota-exhausted")])
    input["maxAttempts"] = .integer(1)
    do {
      _ = try await run(input, gateway: rate)
      XCTFail("rate limit should not fall back")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertTrue(error.message.contains("failureClass=rate-limited"))
      XCTAssertNil(error.isRetryable)
    }
    let quota = FallbackGateway(failure(.quotaExhausted))
    input.removeValue(forKey: "fallback")
    input.removeValue(forKey: "fallbackOn")
    do {
      _ = try await run(input, gateway: quota)
      XCTFail("quota should fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.isRetryable, false)
      XCTAssertTrue(error.message.contains("httpStatus=429"))
      XCTAssertTrue(error.message.contains("providerProblem=insufficient_quota"))
    }
    let calls = await quota.calls
    XCTAssertEqual(calls, 1)
  }

  func testFailedChainRedactsAndReportsBothProviders() async throws {
    let gateway = FallbackGateway(failure(.quotaExhausted))
    try FileManager.default.removeItem(at: model)
    do {
      _ = try await run(options(), gateway: gateway)
      XCTFail("both providers should fail")
    } catch let error as AdapterExecutionError {
      XCTAssertTrue(error.message.contains("fallback chain failed"))
      XCTAssertTrue(error.message.contains("openai"))
      XCTAssertTrue(error.message.contains("whisper-cpp"))
      XCTAssertFalse(error.message.contains("api-secret"))
    }
  }

  func testFallbackCacheRequiresOptInAndPreservesMetadata() async throws {
    let gateway = FallbackGateway(failure(.quotaExhausted))
    let first = try await run(options(), gateway: gateway)
    let second = try await run(options(), gateway: gateway)
    XCTAssertEqual(second["cached"], .bool(false))
    var input = options()
    input["cacheAcceptsFallback"] = .bool(true)
    let third = try await run(input, gateway: gateway)
    XCTAssertEqual(third["cached"], .bool(true))
    XCTAssertEqual(third["provider"], .string("whisper-cpp"))
    XCTAssertEqual(third["fallbackFrom"], first["fallbackFrom"])
    let calls = await gateway.calls
    XCTAssertEqual(calls, 2)
  }

  func testMissingKeyAndUnchangedSuccessOutput() async throws {
    let gateway = FallbackGateway(nil)
    let missing = try await run(options(), gateway: gateway, key: false)
    XCTAssertEqual(try firstFallback(missing)["failureClass"], .string("unavailable"))
    var input = options()
    input.removeValue(forKey: "fallback")
    do {
      _ = try await run(input, gateway: gateway, key: false)
      XCTFail("missing key should fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("addon.env.OPENAI_API_KEY"))
    }
    let success = try await run(input, gateway: gateway)
    XCTAssertEqual(Set(success.keys), Set(["status", "provider", "model", "language", "text", "path", "cached"]))
  }

  func testLegacyPrimaryCacheHitAndFallbackOnlyMiss() async throws {
    let command: [JSONValue] = [.string("/bin/echo"), .string("{{path}}")]
    let legacy: JSONValue = .object([
      "optionsFingerprint": .string("cc39db488faa679b9a1e382d535c9d05df780eb8f54fee3faf9efc93098beb3e"),
      "text": .string("cmd text")
    ])
    let cache = URL(fileURLWithPath: audio.path + ".stt.json")
    try JSONEncoder().encode(legacy).write(to: cache)
    let gateway = FallbackGateway(nil)
    let primary: JSONObject = ["path": .string(audio.path), "provider": .string("command"),
                               "command": .array(command)]
    let hit = try await run(primary, gateway: gateway, key: false)
    XCTAssertEqual(hit["cached"], .bool(true))
    XCTAssertEqual(hit["provider"], .string("command"))
    XCTAssertEqual(hit["text"], .string("cmd text"))
    var fallback: JSONObject = ["path": .string(audio.path), "cacheAcceptsFallback": .bool(true)]
    fallback["fallback"] = .array([.object(["provider": .string("command"), "command": .array(command)])])
    let miss = try await run(fallback, gateway: gateway)
    XCTAssertEqual(miss["cached"], .bool(false))
    XCTAssertEqual(miss["text"], .string("remote text"))
    let calls = await gateway.calls
    XCTAssertEqual(calls, 1)
  }

  func testFallbackCommandReceivesPathPlaceholder() async throws {
    let gateway = FallbackGateway(failure(.quotaExhausted))
    let runner = SpeechFakeRunner(stdout: "command text")
    var input = options()
    input["fallback"] = .array([.object([
      "provider": .string("command"), "command": .array([.string("/bin/echo"), .string("{{path}}")])
    ])])
    let result = try await run(input, gateway: gateway, runner: runner)
    XCTAssertEqual(result["text"], .string("command text"))
    let calls = await runner.calls
    XCTAssertEqual(calls.first?.arguments, [audio.standardizedFileURL.path])
  }
}
