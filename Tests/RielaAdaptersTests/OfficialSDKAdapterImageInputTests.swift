import Foundation
import XCTest
@testable import RielaAdapters
@testable import RielaCore

extension OfficialSDKAdapterTests {
  func testAnthropicAdapterBuildsMessagesRequestWithImagePaths() async throws {
    let imageURL = try temporaryImageFile(extension: "png", bytes: Data("anthropic-image".utf8))
    defer { try? FileManager.default.removeItem(at: imageURL.deletingLastPathComponent()) }
    let executor = RecordingOfficialSDKExecutor(outcomes: [
      .success(OfficialSDKResponse(body: .object([
        "content": .array([.object(["type": .string("text"), "text": .string("saw image")])])
      ])))
    ])
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
      anthropicInput(mergedVariables: ["imagePaths": .array([.string(imageURL.path)])]),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["text"], .string("saw image"))
    let request = try XCTUnwrap(executor.requests().first)
    guard case let .anthropicMessages(body) = request.body else {
      return XCTFail("Expected Anthropic Messages request")
    }
    XCTAssertEqual(body.imageInputs, [
      AnthropicImageInput(mimeType: "image/png", dataBase64: Data("anthropic-image".utf8).base64EncodedString())
    ])
  }

  func testDefaultAnthropicHTTPExecutorIncludesImageBlocks() async throws {
    let imageURL = try temporaryImageFile(extension: "jpg", bytes: Data("anthropic-jpg".utf8))
    defer { try? FileManager.default.removeItem(at: imageURL.deletingLastPathComponent()) }
    let transport = RecordingOfficialSDKHTTPTransport(responses: [
      try httpResponse(["content": .array([.object(["type": .string("text"), "text": .string("default anthropic image")])])])
    ])
    let adapter = AnthropicSDKAdapter(
      configuration: AnthropicSDKAdapterConfiguration(
        officialSDK: OfficialSDKAdapterConfiguration(
          apiKeyEnv: "TEST_ANTHROPIC_KEY",
          baseURL: URL(string: "https://anthropic.test/v1"),
          environment: ["TEST_ANTHROPIC_KEY": anthropicTestKey()],
          httpTransport: transport
        )
      )
    )

    let output = try await adapter.execute(
      anthropicInput(mergedVariables: ["imagePaths": .array([.string(imageURL.path)])]),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["text"], .string("default anthropic image"))
    let request = try XCTUnwrap(transport.requests().first)
    let body = try requestJSONObject(request)
    XCTAssertEqual(
      body["messages"],
      .array([
        .object([
          "role": .string("user"),
          "content": .array([
            .object([
              "type": .string("image"),
              "source": .object([
                "type": .string("base64"),
                "media_type": .string("image/jpeg"),
                "data": .string(Data("anthropic-jpg".utf8).base64EncodedString())
              ])
            ]),
            .object([
              "type": .string("text"),
              "text": .string("hello")
            ])
          ])
        ])
      ])
    )
  }

  func testGeminiAdapterBuildsInlineDataPartsFromImagePaths() async throws {
    let imageURL = try temporaryImageFile(extension: "webp", bytes: Data("gemini-webp".utf8))
    defer { try? FileManager.default.removeItem(at: imageURL.deletingLastPathComponent()) }
    let executor = RecordingOfficialSDKExecutor(outcomes: [
      .success(OfficialSDKResponse(body: .object(["candidates": .array([.object(["content": .object(["parts": .array([.object(["text": .string("saw gemini image")])])])])])])))
    ])
    let adapter = GeminiSDKAdapter(
      configuration: OfficialSDKAdapterConfiguration(
        apiKeyEnv: "TEST_GEMINI_KEY",
        environment: ["TEST_GEMINI_KEY": geminiTestKey()],
        requestExecutor: executor
      )
    )

    let output = try await adapter.execute(
      geminiInput(mergedVariables: ["imagePaths": .array([.string(imageURL.path)])]),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["text"], .string("saw gemini image"))
    let request = try XCTUnwrap(executor.requests().first)
    guard case let .geminiGenerateContent(body) = request.body else {
      return XCTFail("Expected Gemini generateContent request")
    }
    XCTAssertEqual(body.inlineDataParts, [
      GeminiInlineDataPart(mimeType: "image/webp", dataBase64: Data("gemini-webp".utf8).base64EncodedString())
    ])
  }
}
