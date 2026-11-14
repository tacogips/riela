import Foundation
import XCTest
@testable import RielaAdapters
@testable import RielaCore

final class OfficialSDKCodecTests: XCTestCase {
  func testOpenAICodecDecodesSegmentedTextAndUsage() throws {
    let response = try decodeOfficialSDKResponse(
      provider: OpenAiSDKAdapter.provider,
      raw: .object([
        "output": .array([
          .object([
            "content": .array([
              .object(["type": .string("output_text"), "text": .string("first")]),
              .object(["type": .string("ignored"), "text": .string("no")]),
              .object(["type": .string("output_text"), "text": .string("second")])
            ])
          ])
        ]),
        "usage": .object([
          "input_tokens": .integer(10),
          "output_tokens": .integer(4),
          "total_tokens": .integer(14),
          "input_tokens_details": .object(["cached_tokens": .integer(3)])
        ])
      ]),
      options: []
    )

    XCTAssertEqual(response.text, "first\nsecond")
    XCTAssertEqual(response.usage?.inputTokens, 10)
    XCTAssertEqual(response.usage?.outputTokens, 4)
    XCTAssertEqual(response.usage?.totalTokens, 14)
    XCTAssertEqual(response.usage?.cacheReadInputTokens, 3)
    XCTAssertEqual(response.usage?.providerRaw["input_tokens"], .integer(10))
  }

  func testOpenAICodecRelaxedParsingAcceptsMissingContentType() throws {
    let response = try decodeOfficialSDKResponse(
      provider: OpenAiSDKAdapter.provider,
      raw: .object([
        "output": .array([
          .object([
            "content": .array([
              .object(["text": .string("custom provider text")])
            ])
          ])
        ])
      ]),
      options: .relaxed
    )

    XCTAssertEqual(response.text, "custom provider text")
  }

  func testOpenAICodecStrictParsingIgnoresMissingContentType() throws {
    let response = try decodeOfficialSDKResponse(
      provider: OpenAiSDKAdapter.provider,
      raw: .object([
        "output": .array([
          .object([
            "content": .array([
              .object(["text": .string("custom provider text")])
            ])
          ])
        ])
      ]),
      options: []
    )

    XCTAssertEqual(response.text, "")
  }

  func testOpenAICodecMapsStatusToStopReason() throws {
    let response = try decodeOfficialSDKResponse(
      provider: OpenAiSDKAdapter.provider,
      raw: .object([
        "output_text": .string("done"),
        "status": .string("completed")
      ]),
      options: []
    )

    XCTAssertEqual(response.stopReason, "completed")
  }

  func testRelaxedParsingAcceptsStringEncodedUsageTokens() throws {
    let response = try decodeOfficialSDKResponse(
      provider: OpenAiSDKAdapter.provider,
      raw: .object([
        "output_text": .string("usage"),
        "usage": .object([
          "input_tokens": .string("12"),
          "output_tokens": .string("7"),
          "total_tokens": .string("19"),
          "input_tokens_details": .object(["cached_tokens": .string("3")])
        ])
      ]),
      options: .relaxed
    )

    XCTAssertEqual(response.usage?.inputTokens, 12)
    XCTAssertEqual(response.usage?.outputTokens, 7)
    XCTAssertEqual(response.usage?.totalTokens, 19)
    XCTAssertEqual(response.usage?.cacheReadInputTokens, 3)
  }

  func testAnthropicCodecDecodesTextAndUsage() throws {
    let response = try decodeOfficialSDKResponse(
      provider: AnthropicSDKAdapter.provider,
      raw: .object([
        "content": .array([
          .object(["type": .string("text"), "text": .string("first")]),
          .object(["type": .string("tool_use"), "text": .string("ignored")]),
          .object(["type": .string("text"), "text": .string("second")])
        ]),
        "usage": .object([
          "input_tokens": .integer(7),
          "output_tokens": .integer(5),
          "cache_read_input_tokens": .integer(2),
          "cache_creation_input_tokens": .integer(1)
        ])
      ]),
      options: []
    )

    XCTAssertEqual(response.text, "first\nsecond")
    XCTAssertEqual(response.usage?.inputTokens, 7)
    XCTAssertEqual(response.usage?.outputTokens, 5)
    XCTAssertEqual(response.usage?.cacheReadInputTokens, 2)
    XCTAssertEqual(response.usage?.cacheCreationInputTokens, 1)
  }

  func testGeminiCodecDecodesTextAndUsage() throws {
    let response = try decodeOfficialSDKResponse(
      provider: GeminiSDKAdapter.provider,
      raw: .object([
        "candidates": .array([
          .object([
            "finishReason": .string("STOP"),
            "content": .object([
              "parts": .array([
                .object(["text": .string("first")]),
                .object(["text": .string("second")])
              ])
            ])
          ])
        ]),
        "usageMetadata": .object([
          "promptTokenCount": .integer(6),
          "candidatesTokenCount": .integer(3),
          "totalTokenCount": .integer(9)
        ])
      ]),
      options: []
    )

    XCTAssertEqual(response.text, "first\nsecond")
    XCTAssertEqual(response.stopReason, "STOP")
    XCTAssertEqual(response.usage?.inputTokens, 6)
    XCTAssertEqual(response.usage?.outputTokens, 3)
    XCTAssertEqual(response.usage?.totalTokens, 9)
  }

  func testCursorCodecSummarizesAgentResponse() throws {
    let response = try decodeOfficialSDKResponse(
      provider: CursorSDKAdapter.provider,
      raw: .object([
        "id": .string("agent-1"),
        "status": .string("running"),
        "latestRunId": .string("run-1"),
        "url": .string("https://cursor.test/agent-1")
      ]),
      options: []
    )

    XCTAssertEqual(response.text, "Cursor agent agent-1\nstatus: running\nlatest run: run-1\nhttps://cursor.test/agent-1")
  }
}
