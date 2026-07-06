import Foundation
import XCTest
@testable import RielaAdapters
@testable import RielaCore

final class OfficialSDKErrorEnvelopeTests: XCTestCase {
  func testOpenAIErrorEnvelopeAcceptsMessageArray() throws {
    let error = decodeOfficialSDKAPIError(
      provider: OpenAiSDKAdapter.provider,
      statusCode: 400,
      headers: [:],
      body: try errorBody([
        "error": .object([
          "type": .string("invalid_request_error"),
          "message": .array([.string("first"), .string("second")])
        ])
      ]),
      sensitiveValues: []
    )

    XCTAssertEqual(error.type, "invalid_request_error")
    XCTAssertEqual(error.message, "first\nsecond")
    XCTAssertEqual(error.classification, .nonRetryable)
  }

  func testAnthropicErrorEnvelopeDecodesNestedError() throws {
    let error = decodeOfficialSDKAPIError(
      provider: AnthropicSDKAdapter.provider,
      statusCode: 529,
      headers: ["Retry-After": "2"],
      body: try errorBody([
        "type": .string("error"),
        "error": .object([
          "type": .string("overloaded_error"),
          "message": .string("overloaded")
        ])
      ]),
      sensitiveValues: []
    )

    XCTAssertEqual(error.type, "overloaded_error")
    XCTAssertEqual(error.message, "overloaded")
    XCTAssertEqual(error.classification, .retryable)
    XCTAssertNotNil(error.retryAfter)
  }

  func testRetryAfterHTTPDateHeaderDecodesFutureDelay() throws {
    let error = decodeOfficialSDKAPIError(
      provider: OpenAiSDKAdapter.provider,
      statusCode: 429,
      headers: ["Retry-After": "Wed, 31 Dec 2099 23:59:59 GMT"],
      body: try errorBody([
        "error": .object([
          "type": .string("rate_limit_error"),
          "message": .string("retry later")
        ])
      ]),
      sensitiveValues: []
    )

    XCTAssertGreaterThan(error.retryAfter ?? .zero, .zero)
  }

  func testGeminiErrorEnvelopeDecodesArrayShape() throws {
    let error = decodeOfficialSDKAPIError(
      provider: GeminiSDKAdapter.provider,
      statusCode: 403,
      headers: [:],
      body: try errorBody([
        "error": .array([
          .object([
            "status": .string("PERMISSION_DENIED"),
            "message": .string("forbidden")
          ])
        ])
      ]),
      sensitiveValues: []
    )

    XCTAssertEqual(error.type, "PERMISSION_DENIED")
    XCTAssertEqual(error.message, "forbidden")
    XCTAssertEqual(error.classification, .nonRetryable)
  }

  func testGeminiErrorEnvelopeDecodesTopLevelArrayShape() throws {
    let body = try JSONEncoder().encode(JSONValue.array([
      .object([
        "error": .object([
          "status": .string("RESOURCE_EXHAUSTED"),
          "message": .string("quota")
        ])
      ])
    ]))
    let error = decodeOfficialSDKAPIError(
      provider: GeminiSDKAdapter.provider,
      statusCode: 429,
      headers: [:],
      body: body,
      sensitiveValues: []
    )

    XCTAssertEqual(error.type, "RESOURCE_EXHAUSTED")
    XCTAssertEqual(error.message, "quota")
    XCTAssertEqual(error.classification, .retryable)
  }

  func testGenericErrorEnvelopeRedactsSensitiveValues() throws {
    let secret = "cursor-secret-value"
    let error = decodeOfficialSDKAPIError(
      provider: CursorSDKAdapter.provider,
      statusCode: 500,
      headers: [:],
      body: try errorBody([
        "code": .string("server_error"),
        "message": .string("upstream echoed \(secret)")
      ]),
      sensitiveValues: [secret]
    )

    XCTAssertEqual(error.type, "server_error")
    XCTAssertEqual(error.message, "upstream echoed <redacted>")
    XCTAssertEqual(error.classification, .retryable)
  }

  private func errorBody(_ object: JSONObject) throws -> Data {
    try JSONEncoder().encode(JSONValue.object(object))
  }
}
