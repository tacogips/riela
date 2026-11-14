import Foundation
import XCTest
@testable import RielaAdapters
@testable import RielaCore

extension OfficialSDKAdapterTests {
  func testOpenAIAdapterExtractsUsageAndEmitsUsageBackendEvent() async throws {
    let usage: JSONObject = [
      "input_tokens": .integer(11),
      "output_tokens": .integer(7),
      "total_tokens": .integer(18),
      "input_tokens_details": .object(["cached_tokens": .integer(3)])
    ]
    let executor = RecordingOfficialSDKExecutor(outcomes: [
      .success(OfficialSDKResponse(body: .object([
        "output_text": .string("hello from openai"),
        "usage": .object(usage)
      ])))
    ])
    let events = BackendEventRecorder()
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        environment: ["TEST_OPENAI_KEY": openAITestKey()],
        requestExecutor: executor
      )
    )

    let output = try await adapter.execute(
      openAIInput(),
      context: AdapterExecutionContext(backendEventHandler: { event in
        events.append(event)
      })
    )

    XCTAssertEqual(output.usage?.inputTokens, 11)
    XCTAssertEqual(output.usage?.outputTokens, 7)
    XCTAssertEqual(output.usage?.totalTokens, 18)
    XCTAssertEqual(output.usage?.cacheReadInputTokens, 3)
    let usageEvent = try XCTUnwrap(events.events().first)
    XCTAssertEqual(usageEvent.provider, "official-openai-sdk")
    XCTAssertEqual(usageEvent.eventType, "response.usage")
    XCTAssertEqual(usageEvent.channel, .usage)
    XCTAssertEqual(usageEvent.usage?["input_tokens"], .integer(11))
    XCTAssertEqual(usageEvent.usage?["output_tokens"], .integer(7))
    XCTAssertEqual(usageEvent.usage?["provider_raw"], .object(usage))
  }

  func testAnthropicAdapterExtractsUsageAndEmitsUsageBackendEvent() async throws {
    let usage: JSONObject = [
      "input_tokens": .integer(13),
      "output_tokens": .integer(5),
      "cache_read_input_tokens": .integer(2),
      "cache_creation_input_tokens": .integer(4)
    ]
    let executor = RecordingOfficialSDKExecutor(outcomes: [
      .success(OfficialSDKResponse(body: .object([
        "content": .array([.object(["type": .string("text"), "text": .string("anthropic usage")])]),
        "usage": .object(usage)
      ])))
    ])
    let events = BackendEventRecorder()
    let adapter = AnthropicSDKAdapter(
      configuration: AnthropicSDKAdapterConfiguration(
        officialSDK: OfficialSDKAdapterConfiguration(
          apiKeyEnv: "TEST_ANTHROPIC_KEY",
          environment: ["TEST_ANTHROPIC_KEY": anthropicTestKey()],
          requestExecutor: executor
        )
      )
    )

    let output = try await adapter.execute(
      anthropicInput(),
      context: AdapterExecutionContext(backendEventHandler: { event in
        events.append(event)
      })
    )

    XCTAssertEqual(output.payload["text"], .string("anthropic usage"))
    XCTAssertEqual(output.usage?.inputTokens, 13)
    XCTAssertEqual(output.usage?.outputTokens, 5)
    XCTAssertEqual(output.usage?.cacheReadInputTokens, 2)
    XCTAssertEqual(output.usage?.cacheCreationInputTokens, 4)
    let usageEvent = try XCTUnwrap(events.events().first)
    XCTAssertEqual(usageEvent.provider, "official-anthropic-sdk")
    XCTAssertEqual(usageEvent.channel, .usage)
    XCTAssertEqual(usageEvent.usage?["cache_read_input_tokens"], .integer(2))
    XCTAssertEqual(usageEvent.usage?["cache_creation_input_tokens"], .integer(4))
    XCTAssertEqual(usageEvent.usage?["provider_raw"], .object(usage))
  }

  func testGeminiAdapterExtractsUsageAndEmitsUsageBackendEvent() async throws {
    let usage: JSONObject = [
      "promptTokenCount": .integer(17),
      "candidatesTokenCount": .integer(9),
      "totalTokenCount": .integer(26)
    ]
    let executor = RecordingOfficialSDKExecutor(outcomes: [
      .success(OfficialSDKResponse(body: .object([
        "candidates": .array([
          .object([
            "content": .object([
              "parts": .array([.object(["text": .string("gemini usage")])])
            ])
          ])
        ]),
        "usageMetadata": .object(usage)
      ])))
    ])
    let events = BackendEventRecorder()
    let adapter = GeminiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_GEMINI_KEY",
        environment: ["TEST_GEMINI_KEY": geminiTestKey()],
        requestExecutor: executor
      )
    )

    let output = try await adapter.execute(
      geminiInput(),
      context: AdapterExecutionContext(backendEventHandler: { event in
        events.append(event)
      })
    )

    XCTAssertEqual(output.payload["text"], .string("gemini usage"))
    XCTAssertEqual(output.usage?.inputTokens, 17)
    XCTAssertEqual(output.usage?.outputTokens, 9)
    XCTAssertEqual(output.usage?.totalTokens, 26)
    let usageEvent = try XCTUnwrap(events.events().first)
    XCTAssertEqual(usageEvent.provider, "official-gemini-sdk")
    XCTAssertEqual(usageEvent.channel, .usage)
    XCTAssertEqual(usageEvent.usage?["input_tokens"], .integer(17))
    XCTAssertEqual(usageEvent.usage?["output_tokens"], .integer(9))
    XCTAssertEqual(usageEvent.usage?["total_tokens"], .integer(26))
    XCTAssertEqual(usageEvent.usage?["provider_raw"], .object(usage))
  }

  func testDefaultHTTPExecutorDoesNotRetryNonRetryableHTTPFailures() async throws {
    let transport = RecordingOfficialSDKHTTPTransport(responses: [
      try httpResponse([
        "error": .object([
          "type": .string("invalid_request_error"),
          "message": .string("bad request")
        ])
      ], statusCode: 401),
      try httpResponse(["output_text": .string("should not retry")])
    ])
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        retryPolicy: RetryPolicy(maxAttempts: 2, retryDelay: .zero),
        environment: ["TEST_OPENAI_KEY": openAITestKey()],
        httpTransport: transport
      )
    )

    do {
      _ = try await adapter.execute(openAIInput(), context: AdapterExecutionContext())
      XCTFail("Expected HTTP provider error")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertEqual(error.isRetryable, false)
      XCTAssertTrue(error.message.contains("official-openai-sdk HTTP 401 invalid_request_error: bad request"))
      XCTAssertEqual(transport.requests().count, 1)
    }
  }

  func testDefaultHTTPExecutorHonorsRetryAfterForRetryableHTTPFailures() async throws {
    let transport = RecordingOfficialSDKHTTPTransport(responses: [
      try httpResponse([
        "error": .object([
          "type": .string("rate_limit_error"),
          "message": .string("slow down")
        ])
      ], statusCode: 429, headers: ["Retry-After": "0.01"]),
      try httpResponse(["output_text": .string("ok after retry")])
    ])
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        retryPolicy: RetryPolicy(maxAttempts: 2, retryDelay: .seconds(30)),
        environment: ["TEST_OPENAI_KEY": openAITestKey()],
        httpTransport: transport
      )
    )

    let output = try await adapter.execute(openAIInput(), context: AdapterExecutionContext())

    XCTAssertEqual(output.payload["text"], .string("ok after retry"))
    XCTAssertEqual(transport.requests().count, 2)
  }

  func testOfficialSDKAdapterSkipsRetryWhenDeadlineCannotCoverDelay() async throws {
    let secret = openAITestKey()
    let executor = RecordingOfficialSDKExecutor(outcomes: [
      .failure(AdapterExecutionError(.providerError, "Authorization: Bearer \(secret)")),
      .success(OfficialSDKResponse(body: .object(["output_text": .string("late ok")])))
    ])
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        retryPolicy: RetryPolicy(maxAttempts: 2, retryDelay: .milliseconds(100)),
        environment: ["TEST_OPENAI_KEY": secret],
        requestExecutor: executor
      )
    )

    do {
      _ = try await adapter.execute(
        openAIInput(),
        context: AdapterExecutionContext(deadline: Date(timeIntervalSinceNow: 0.05))
      )
      XCTFail("Expected provider error")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertFalse(error.message.contains(secret))
      XCTAssertEqual(executor.requests().count, 1)
    }
  }

  func testInjectedExecutorMalformedBodyFailsTypedWithoutRetry() async throws {
    let executor = RecordingOfficialSDKExecutor(outcomes: [
      .success(OfficialSDKResponse(body: .object([
        "output_text": .string("ok"),
        "usage": .object(["input_tokens": .string("bad")])
      ])))
    ])
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        retryPolicy: RetryPolicy(maxAttempts: 3, retryDelay: .zero),
        environment: ["TEST_OPENAI_KEY": openAITestKey()],
        requestExecutor: executor
      )
    )

    do {
      _ = try await adapter.execute(openAIInput(), context: AdapterExecutionContext())
      XCTFail("Expected malformed response failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidOutput)
      XCTAssertEqual(error.isRetryable, false)
      XCTAssertFalse(error.message.contains("DecodingError"))
      XCTAssertEqual(executor.requests().count, 1)
    }
  }
}
