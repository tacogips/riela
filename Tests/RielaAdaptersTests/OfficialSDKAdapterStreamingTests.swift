import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import RielaAdapters
@testable import RielaCore

final class RecordingOfficialSDKStreamingTransport: OfficialSDKStreamingHTTPTransporting, @unchecked Sendable {
  private let queue = DispatchQueue(label: "riela.official-sdk-streaming-test-transport")
  private var capturedRequests: [URLRequest] = []
  private var responses: [Result<OfficialSDKStreamingHTTPResponse, Error>]

  init(responses: [Result<OfficialSDKStreamingHTTPResponse, Error>]) {
    self.responses = responses
  }

  func bytes(for request: URLRequest) async throws -> OfficialSDKStreamingHTTPResponse {
    let response = queue.sync { () -> Result<OfficialSDKStreamingHTTPResponse, Error> in
      capturedRequests.append(request)
      return responses.isEmpty
        ? .failure(AdapterExecutionError(.providerError, "missing streaming test response"))
        : responses.removeFirst()
    }
    switch response {
    case let .success(response):
      return response
    case let .failure(error):
      throw error
    }
  }

  func requests() -> [URLRequest] {
    queue.sync {
      capturedRequests
    }
  }
}

final class ReplacingStreamChunkMiddleware: OfficialSDKMiddleware, @unchecked Sendable {
  let replacement: Data

  init(replacement: Data) {
    self.replacement = replacement
  }

  func interceptStreamChunk(_ chunk: Data) -> Data {
    replacement
  }
}

extension OfficialSDKAdapterTests {
  func testOpenAIStreamingEmitsDeltasUsageAndFinalOutput() async throws {
    let stream = streamingResponse(chunks: [
      #"event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"hel"}\n\n"#,
      #"data: {"type":"response.output_text.delta","delta":"lo"}\n\n"#,
      #"data: {"type":"response.completed","response":{"output_text":"hello","usage":{"input_tokens":3,"output_tokens":2,"total_tokens":5}}}\n\n"#
    ])
    let transport = RecordingOfficialSDKStreamingTransport(responses: [.success(stream)])
    let events = BackendEventRecorder()
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        baseURL: URL(string: "https://openai.test/v1"),
        environment: ["TEST_OPENAI_KEY": openAITestKey()],
        streamingTransport: transport
      )
    )

    let output = try await adapter.execute(
      openAIInput(),
      context: AdapterExecutionContext(backendEventHandler: { event in events.append(event) })
    )

    XCTAssertEqual(output.payload["text"], .string("hello"))
    XCTAssertEqual(output.usage?.inputTokens, 3)
    XCTAssertEqual(output.usage?.outputTokens, 2)
    let request = try XCTUnwrap(transport.requests().first)
    XCTAssertEqual(request.url?.absoluteString, "https://openai.test/v1/responses")
    XCTAssertEqual(try requestJSONObject(request)["stream"], .bool(true))
    let recorded = events.events()
    XCTAssertEqual(recorded.map(\.channel), [.assistant, .assistant, .usage])
    XCTAssertEqual(recorded.compactMap(\.contentDelta), ["hel", "lo"])
    XCTAssertEqual(recorded.last?.usage?["total_tokens"], .integer(5))
  }

  func testAnthropicStreamingMapsTextThinkingAndUsage() async throws {
    let stream = streamingResponse(chunks: [
      #"event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":7}}}\n\n"#,
      #"event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}\n\n"#,
      #"event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"think"}}\n\n"#,
      #"event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":4}}\n\n"#
    ])
    let transport = RecordingOfficialSDKStreamingTransport(responses: [.success(stream)])
    let events = BackendEventRecorder()
    let adapter = AnthropicSDKAdapter(
      configuration: AnthropicSDKAdapterConfiguration(
        officialSDK: OfficialSDKAdapterConfiguration(
          apiKeyEnv: "TEST_ANTHROPIC_KEY",
          environment: ["TEST_ANTHROPIC_KEY": anthropicTestKey()],
          streamingTransport: transport
        )
      )
    )

    let output = try await adapter.execute(
      anthropicInput(),
      context: AdapterExecutionContext(backendEventHandler: { event in events.append(event) })
    )

    XCTAssertEqual(output.payload["text"], .string("hi"))
    XCTAssertEqual(output.usage?.inputTokens, 7)
    XCTAssertEqual(output.usage?.outputTokens, 4)
    XCTAssertEqual(output.usage?.providerRaw["output_tokens"], .integer(4))
    let contentEvents = events.events().filter { $0.channel == .assistant || $0.channel == .thinking || $0.channel == .usage }
    XCTAssertEqual(contentEvents.map(\.channel), [.assistant, .thinking, .usage])
    let assistantEvent = try XCTUnwrap(contentEvents.first)
    let thinkingEvent = try XCTUnwrap(contentEvents.dropFirst().first)
    let usageEvent = try XCTUnwrap(contentEvents.dropFirst(2).first)
    XCTAssertEqual(assistantEvent.contentDelta, "hi")
    XCTAssertEqual(thinkingEvent.contentDelta, "think")
    XCTAssertEqual(usageEvent.usage?["input_tokens"], .integer(7))
    XCTAssertEqual(usageEvent.usage?["output_tokens"], .integer(4))
  }

  func testGeminiStreamingUsesSSEEndpointAndAccumulatesUsage() async throws {
    let stream = streamingResponse(chunks: [
      #"data: {"candidates":[{"content":{"parts":[{"text":"a"}]}}]}\n\n"#,
      #"data: {"candidates":[{"content":{"parts":[{"text":"b"}]}}]}\n\n"#,
      #"data: {"usageMetadata":{"promptTokenCount":6,"candidatesTokenCount":3,"totalTokenCount":9}}\n\n"#
    ])
    let transport = RecordingOfficialSDKStreamingTransport(responses: [.success(stream)])
    let events = BackendEventRecorder()
    let adapter = GeminiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_GEMINI_KEY",
        baseURL: URL(string: "https://gemini.test/v1beta"),
        environment: ["TEST_GEMINI_KEY": geminiTestKey()],
        streamingTransport: transport
      )
    )

    let output = try await adapter.execute(
      geminiInput(),
      context: AdapterExecutionContext(backendEventHandler: { event in events.append(event) })
    )

    XCTAssertEqual(output.payload["text"], .string("ab"))
    XCTAssertEqual(output.usage?.totalTokens, 9)
    let request = try XCTUnwrap(transport.requests().first)
    XCTAssertEqual(request.url?.absoluteString, "https://gemini.test/v1beta/models/gemini-3.5-flash:streamGenerateContent?alt=sse")
    let recorded = events.events()
    XCTAssertEqual(recorded.filter { $0.channel == .assistant }.compactMap(\.contentDelta), ["a", "b"])
    XCTAssertEqual(recorded.last?.channel, .usage)
    XCTAssertEqual(recorded.last?.usage?["total_tokens"], .integer(9))
  }

  func testStreamBackendContentFalseUsesBlockingPath() async throws {
    let streamingTransport = RecordingOfficialSDKStreamingTransport(responses: [
      .failure(AdapterExecutionError(.providerError, "stream should be disabled"))
    ])
    let httpTransport = RecordingOfficialSDKHTTPTransport(responses: [
      try httpResponse(["output_text": .string("blocking")])
    ])
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        environment: ["TEST_OPENAI_KEY": openAITestKey()],
        httpTransport: httpTransport,
        streamingTransport: streamingTransport
      )
    )

    let output = try await adapter.execute(
      openAIInput(mergedVariables: ["streamBackendContent": .bool(false)]),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["text"], .string("blocking"))
    XCTAssertTrue(streamingTransport.requests().isEmpty)
    XCTAssertEqual(httpTransport.requests().count, 1)
  }

  func testStreamingKillSwitchUsesBlockingPath() async throws {
    let streamingTransport = RecordingOfficialSDKStreamingTransport(responses: [
      .failure(AdapterExecutionError(.providerError, "stream should be disabled"))
    ])
    let httpTransport = RecordingOfficialSDKHTTPTransport(responses: [
      try httpResponse(["output_text": .string("kill switch blocking")])
    ])
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        environment: [
          "TEST_OPENAI_KEY": openAITestKey(),
          "RIELA_OFFICIAL_SDK_STREAMING": "off"
        ],
        httpTransport: httpTransport,
        streamingTransport: streamingTransport
      )
    )

    let output = try await adapter.execute(openAIInput(), context: AdapterExecutionContext())

    XCTAssertEqual(output.payload["text"], .string("kill switch blocking"))
    XCTAssertTrue(streamingTransport.requests().isEmpty)
    XCTAssertEqual(httpTransport.requests().count, 1)
  }

  func testStreamingFailureFallsBackToBlockingRequest() async throws {
    let stream = streamingResponse(chunks: [
      #"data: {"type":"response.output_text.delta","delta":"partial"}\n\n"#
    ], terminalError: AdapterExecutionError(.providerError, "stream interrupted"))
    let streamingTransport = RecordingOfficialSDKStreamingTransport(responses: [.success(stream)])
    let httpTransport = RecordingOfficialSDKHTTPTransport(responses: [
      try httpResponse(["output_text": .string("blocking fallback")])
    ])
    let events = BackendEventRecorder()
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        environment: ["TEST_OPENAI_KEY": openAITestKey()],
        httpTransport: httpTransport,
        streamingTransport: streamingTransport
      )
    )

    let output = try await adapter.execute(
      openAIInput(),
      context: AdapterExecutionContext(backendEventHandler: { event in events.append(event) })
    )

    XCTAssertEqual(output.payload["text"], .string("blocking fallback"))
    XCTAssertEqual(streamingTransport.requests().count, 1)
    XCTAssertEqual(httpTransport.requests().count, 1)
    XCTAssertEqual(events.events().first?.contentDelta, "partial")
  }

  func testProviderStreamErrorDoesNotFallbackToBlockingRequest() async throws {
    let stream = streamingResponse(chunks: [
      #"data: {"type":"response.failed","response":{"error":{"message":"model rejected request"}}}\n\n"#
    ])
    let streamingTransport = RecordingOfficialSDKStreamingTransport(responses: [.success(stream)])
    let httpTransport = RecordingOfficialSDKHTTPTransport(responses: [
      try httpResponse(["output_text": .string("must not be used")])
    ])
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        environment: ["TEST_OPENAI_KEY": openAITestKey()],
        httpTransport: httpTransport,
        streamingTransport: streamingTransport
      )
    )

    do {
      _ = try await adapter.execute(openAIInput(), context: AdapterExecutionContext())
      XCTFail("Expected provider stream error")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertEqual(error.isRetryable, false)
      XCTAssertTrue(error.message.contains("model rejected request"))
      XCTAssertEqual(streamingTransport.requests().count, 1)
      XCTAssertTrue(httpTransport.requests().isEmpty)
    }
  }

  func testStreamingChunksPassThroughMiddlewareBeforeParsing() async throws {
    let rawStream = streamingResponse(chunks: ["data: {}\n\n"])
    let replacement = Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"rewritten\"}\n\n".utf8)
    let transport = RecordingOfficialSDKStreamingTransport(responses: [.success(rawStream)])
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        environment: ["TEST_OPENAI_KEY": openAITestKey()],
        middlewares: [ReplacingStreamChunkMiddleware(replacement: replacement)],
        streamingTransport: transport
      )
    )

    let output = try await adapter.execute(openAIInput(), context: AdapterExecutionContext())

    XCTAssertEqual(output.payload["text"], .string("rewritten"))
  }

  private func streamingResponse(
    chunks: [String],
    statusCode: Int = 200,
    headers: [String: String] = [:],
    terminalError: Error? = nil
  ) -> OfficialSDKStreamingHTTPResponse {
    OfficialSDKStreamingHTTPResponse(
      statusCode: statusCode,
      headers: headers,
      body: AsyncThrowingStream { continuation in
        for chunk in chunks {
          continuation.yield(Data(chunk.replacingOccurrences(of: "\\n", with: "\n").utf8))
        }
        if let terminalError {
          continuation.finish(throwing: terminalError)
        } else {
          continuation.finish()
        }
      }
    )
  }
}
