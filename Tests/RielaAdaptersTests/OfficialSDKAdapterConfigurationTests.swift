import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import RielaAdapters
@testable import RielaCore

final class RecordingOfficialSDKMiddleware: OfficialSDKMiddleware, @unchecked Sendable {
  private let queue = DispatchQueue(label: "riela.official-sdk-test-middleware")
  private var recordedEvents: [String] = []

  func intercept(request: URLRequest) -> URLRequest {
    queue.sync {
      recordedEvents.append("request")
    }
    var request = request
    request.setValue("middleware", forHTTPHeaderField: "X-Middleware")
    return request
  }

  func intercept(response: HTTPURLResponse, data: Data) -> Data {
    queue.sync {
      recordedEvents.append("response:\(response.statusCode)")
    }
    return Data(#"{"output_text":"middleware response"}"#.utf8)
  }

  func events() -> [String] {
    queue.sync {
      recordedEvents
    }
  }
}

final class OfficialSDKLogRecorder: @unchecked Sendable {
  private let queue = DispatchQueue(label: "riela.official-sdk-log-recorder")
  private var messages: [String] = []

  func append(_ message: String) {
    queue.sync {
      messages.append(message)
    }
  }

  func entries() -> [String] {
    queue.sync {
      messages
    }
  }
}

extension OfficialSDKAdapterTests {
  func testDefaultHTTPExecutorAppliesCustomHeadersAfterDefaults() async throws {
    let transport = RecordingOfficialSDKHTTPTransport(responses: [
      try httpResponse(["output_text": .string("custom header response")])
    ])
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        baseURL: URL(string: "https://openai.test/v1"),
        environment: ["TEST_OPENAI_KEY": openAITestKey()],
        httpTransport: transport,
        customHeaders: [
          "Authorization": "Bearer proxy-token",
          "X-Proxy-Route": "tenant-a"
        ]
      )
    )

    _ = try await adapter.execute(openAIInput(), context: AdapterExecutionContext())

    let request = try XCTUnwrap(transport.requests().first)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer proxy-token")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Proxy-Route"), "tenant-a")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
  }

  func testDefaultHTTPExecutorUsesConfiguredTimeoutWhenItIsSmallerThanDeadline() async throws {
    let transport = RecordingOfficialSDKHTTPTransport(responses: [
      try httpResponse(["output_text": .string("timeout response")])
    ])
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        environment: ["TEST_OPENAI_KEY": openAITestKey()],
        httpTransport: transport,
        timeout: .seconds(2)
      )
    )

    _ = try await adapter.execute(
      openAIInput(),
      context: AdapterExecutionContext(deadline: Date(timeIntervalSinceNow: 30))
    )

    let request = try XCTUnwrap(transport.requests().first)
    XCTAssertEqual(request.timeoutInterval, 2, accuracy: 0.01)
  }

  func testDefaultHTTPExecutorPropagatesDeadlineToRequestTimeout() async throws {
    let transport = RecordingOfficialSDKHTTPTransport(responses: [
      try httpResponse(["output_text": .string("deadline response")])
    ])
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        environment: ["TEST_OPENAI_KEY": openAITestKey()],
        httpTransport: transport
      )
    )

    _ = try await adapter.execute(
      openAIInput(),
      context: AdapterExecutionContext(deadline: Date(timeIntervalSinceNow: 3))
    )

    let request = try XCTUnwrap(transport.requests().first)
    XCTAssertGreaterThanOrEqual(request.timeoutInterval, 1)
    XCTAssertLessThanOrEqual(request.timeoutInterval, 3)
  }

  func testDefaultHTTPExecutorAppliesMiddlewareAroundTransport() async throws {
    let transport = RecordingOfficialSDKHTTPTransport(responses: [
      try httpResponse(["output_text": .string("raw response")])
    ])
    let middleware = RecordingOfficialSDKMiddleware()
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        environment: ["TEST_OPENAI_KEY": openAITestKey()],
        httpTransport: transport,
        middlewares: [middleware]
      )
    )

    let output = try await adapter.execute(openAIInput(), context: AdapterExecutionContext())

    let request = try XCTUnwrap(transport.requests().first)
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Middleware"), "middleware")
    XCTAssertEqual(output.payload["text"], .string("middleware response"))
    XCTAssertEqual(middleware.events(), ["request", "response:200"])
  }

  func testLoggingMiddlewareRecordsRedactedRequestAndResponse() async throws {
    let secret = "proxy-secret-value"
    let transport = RecordingOfficialSDKHTTPTransport(responses: [
      try httpResponse(["output_text": .string("logged response")])
    ])
    let logRecorder = OfficialSDKLogRecorder()
    let middleware = OfficialSDKLoggingMiddleware(
      additionalSensitiveValues: [secret],
      sink: { logRecorder.append($0) }
    )
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        environment: ["TEST_OPENAI_KEY": openAITestKey()],
        httpTransport: transport,
        customHeaders: ["Authorization": "Bearer \(secret)"],
        middlewares: [middleware]
      )
    )

    _ = try await adapter.execute(
      AdapterExecutionInput(
        node: AgentNodePayload(id: "worker", executionBackend: .officialOpenAISDK, model: "gpt-5"),
        promptText: "hello \(secret)"
      ),
      context: AdapterExecutionContext()
    )

    let entries = logRecorder.entries()
    XCTAssertEqual(entries.count, 2)
    XCTAssertTrue(entries[0].contains("request POST https://api.openai.com/v1/responses"))
    XCTAssertTrue(entries[0].contains(#""input":"hello <redacted>""#))
    XCTAssertTrue(entries[1].contains("response status=200"))
    XCTAssertTrue(entries[1].contains("logged response"))
    XCTAssertFalse(entries.joined(separator: "\n").contains(secret))
    XCTAssertTrue(entries.joined(separator: "\n").contains("<redacted>"))
  }

  func testLoggingMiddlewareRedactsSensitiveHeadersWithoutConfiguredValues() throws {
    let apiKey = "anthropic-header-secret"
    let cursorCredential = "cursor-header-secret"
    let basicCredential = Data("\(cursorCredential):".utf8).base64EncodedString()
    let cookie = "session=response-cookie-secret"
    let logRecorder = OfficialSDKLogRecorder()
    let middleware = OfficialSDKLoggingMiddleware(sink: { logRecorder.append($0) })
    var request = URLRequest(url: try XCTUnwrap(URL(string: "https://adapter.test/v1/messages")))
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("Basic \(basicCredential)", forHTTPHeaderField: "Authorization")
    request.setValue(cookie, forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    _ = middleware.intercept(request: request)
    let response = try XCTUnwrap(HTTPURLResponse(
      url: try XCTUnwrap(URL(string: "https://adapter.test/v1/messages")),
      statusCode: 200,
      httpVersion: nil,
      headerFields: [
        "Set-Cookie": cookie,
        "X-Request-ID": "request-123"
      ]
    ))
    _ = middleware.intercept(response: response, data: Data(#"{"ok":true}"#.utf8))

    let joinedEntries = logRecorder.entries().joined(separator: "\n")
    XCTAssertFalse(joinedEntries.contains(apiKey))
    XCTAssertFalse(joinedEntries.contains(cursorCredential))
    XCTAssertFalse(joinedEntries.contains(basicCredential))
    XCTAssertFalse(joinedEntries.contains(cookie))
    XCTAssertTrue(joinedEntries.contains("Content-Type"))
    XCTAssertTrue(joinedEntries.contains("application/json"))
    XCTAssertTrue(joinedEntries.contains("X-Request-ID"))
    XCTAssertTrue(joinedEntries.contains("request-123"))
    XCTAssertTrue(joinedEntries.contains("<redacted>"))
  }

  func testLoggingMiddlewareRecordsRedactedStreamChunks() async throws {
    let secret = "stream-secret-value"
    let logRecorder = OfficialSDKLogRecorder()
    let middleware = OfficialSDKLoggingMiddleware(
      additionalSensitiveValues: [secret],
      sink: { logRecorder.append($0) }
    )

    let chunk = Data("data: \(secret)\n\n".utf8)
    let returned = middleware.interceptStreamChunk(chunk)

    XCTAssertEqual(returned, chunk)
    let entries = logRecorder.entries()
    XCTAssertEqual(entries.count, 1)
    XCTAssertTrue(entries[0].contains("stream chunk bytes="))
    XCTAssertFalse(entries[0].contains(secret))
    XCTAssertTrue(entries[0].contains("<redacted>"))
  }

  func testOpenAICompatibleBaseURLEnablesRelaxedResponseParsing() async throws {
    let transport = RecordingOfficialSDKHTTPTransport(responses: [
      try httpResponse([
        "output": .array([
          .object([
            "content": .array([
              .object(["text": .string("compatible provider text")])
            ])
          ])
        ])
      ])
    ])
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        baseURL: URL(string: "https://openrouter.test/v1"),
        environment: ["TEST_OPENAI_KEY": openAITestKey()],
        httpTransport: transport
      )
    )

    let output = try await adapter.execute(openAIInput(), context: AdapterExecutionContext())

    XCTAssertEqual(output.payload["text"], .string("compatible provider text"))
  }
}
