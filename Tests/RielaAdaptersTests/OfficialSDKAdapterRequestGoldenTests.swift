import Foundation
import XCTest
@testable import RielaAdapters
@testable import RielaCore

extension OfficialSDKAdapterTests {
  func testOpenAIRequestBodyMatchesGoldenJSON() async throws {
    let transport = RecordingOfficialSDKHTTPTransport(responses: [
      try httpResponse(["output_text": .string("golden openai")])
    ])
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        baseURL: URL(string: "https://openai.test/v1"),
        environment: ["TEST_OPENAI_KEY": openAITestKey()],
        httpTransport: transport
      )
    )

    _ = try await adapter.execute(openAIInput(systemPromptText: "system"), context: AdapterExecutionContext())

    let request = try XCTUnwrap(transport.requests().first)
    XCTAssertEqual(
      try requestBodyString(request),
      #"{"input":"hello","instructions":"system","model":"gpt-5"}"#
    )
  }

  func testOpenAIImageRequestBodyMatchesGoldenJSON() async throws {
    let imageURL = try temporaryImageFile(extension: "png", bytes: Data("png-bytes".utf8))
    defer { try? FileManager.default.removeItem(at: imageURL.deletingLastPathComponent()) }
    let transport = RecordingOfficialSDKHTTPTransport(responses: [
      try httpResponse(["output_text": .string("golden image")])
    ])
    let adapter = OpenAiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_OPENAI_KEY",
        baseURL: URL(string: "https://openai.test/v1"),
        environment: ["TEST_OPENAI_KEY": openAITestKey()],
        httpTransport: transport
      )
    )

    _ = try await adapter.execute(
      openAIInput(mergedVariables: ["imagePaths": .array([.string(imageURL.path)])]),
      context: AdapterExecutionContext()
    )

    let request = try XCTUnwrap(transport.requests().first)
    XCTAssertEqual(
      try requestBodyString(request),
      #"{"input":[{"content":[{"text":"hello","type":"input_text"},{"image_url":"data:image\/png;base64,cG5nLWJ5dGVz","type":"input_image"}],"role":"user"}],"model":"gpt-5"}"#
    )
  }

  func testAnthropicRequestBodyMatchesGoldenJSON() async throws {
    let transport = RecordingOfficialSDKHTTPTransport(responses: [
      try httpResponse(["content": .array([.object(["type": .string("text"), "text": .string("golden anthropic")])])])
    ])
    let adapter = AnthropicSDKAdapter(
      configuration: AnthropicSDKAdapterConfiguration(
        officialSDK: OfficialSDKAdapterConfiguration(
          apiKeyEnv: "TEST_ANTHROPIC_KEY",
          baseURL: URL(string: "https://anthropic.test/v1"),
          environment: ["TEST_ANTHROPIC_KEY": anthropicTestKey()],
          httpTransport: transport
        ),
        maxTokens: 2048
      )
    )

    _ = try await adapter.execute(anthropicInput(systemPromptText: "system"), context: AdapterExecutionContext())

    let request = try XCTUnwrap(transport.requests().first)
    XCTAssertEqual(
      try requestBodyString(request),
      #"{"max_tokens":2048,"messages":[{"content":"hello","role":"user"}],"model":"claude-sonnet-4-5","system":"system"}"#
    )
  }

  func testGeminiRequestBodyMatchesGoldenJSON() async throws {
    let transport = RecordingOfficialSDKHTTPTransport(responses: [
      try httpResponse([
        "candidates": .array([
          .object(["content": .object(["parts": .array([.object(["text": .string("golden gemini")])])])])
        ])
      ])
    ])
    let adapter = GeminiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_GEMINI_KEY",
        baseURL: URL(string: "https://gemini.test/v1beta"),
        environment: ["TEST_GEMINI_KEY": geminiTestKey()],
        httpTransport: transport
      )
    )

    _ = try await adapter.execute(
      geminiInput(
        systemPromptText: "system",
        mergedVariables: [
          "geminiInlineDataParts": .array([
            .object([
              "mimeType": .string("image/png"),
              "dataBase64": .string("iVBORw0KGgo=")
            ])
          ])
        ]
      ),
      context: AdapterExecutionContext()
    )

    let request = try XCTUnwrap(transport.requests().first)
    XCTAssertEqual(
      try requestBodyString(request),
      #"{"contents":[{"parts":[{"inline_data":{"data":"iVBORw0KGgo=","mime_type":"image\/png"}},{"text":"hello"}],"role":"user"}],"systemInstruction":{"parts":[{"text":"system"}]}}"#
    )
  }

  func testCursorRequestBodyMatchesGoldenJSON() async throws {
    let transport = RecordingOfficialSDKHTTPTransport(responses: [
      try httpResponse([
        "id": .string("agent-1"),
        "status": .string("running"),
        "latestRunId": .string("run-1")
      ])
    ])
    let adapter = CursorSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_CURSOR_KEY",
        baseURL: URL(string: "https://cursor.test/v1"),
        environment: ["TEST_CURSOR_KEY": cursorTestKey()],
        httpTransport: transport
      )
    )

    _ = try await adapter.execute(
      cursorSDKInput(
        agentEnvironment: [
          "CURSOR_REPOSITORY_URL": "https://github.com/example/project",
          "CURSOR_STARTING_REF": "main",
          "CURSOR_WORK_ON_CURRENT_BRANCH": "true"
        ]
      ),
      context: AdapterExecutionContext()
    )

    let request = try XCTUnwrap(transport.requests().first)
    XCTAssertEqual(
      try requestBodyString(request),
      #"{"model":{"id":"composer-2"},"prompt":{"text":"hello"},"repos":[{"startingRef":"main","url":"https:\/\/github.com\/example\/project"}],"workOnCurrentBranch":true}"#
    )
  }

  private func requestBodyString(_ request: URLRequest) throws -> String {
    let data = try XCTUnwrap(request.httpBody)
    return try XCTUnwrap(String(data: data, encoding: .utf8))
  }
}
