import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

// swiftlint:disable multiple_closures_with_trailing_closure
final class PublicWebResourceTests: XCTestCase {
  func testPolicyMatchesEntireURLBeforeEveryRedirectTransport() async throws {
    let pattern = #"https://images\.example/(?:media|preview)/[A-Za-z0-9_.-]+(?:\?format=png)?"#
    let response = try await PublicWebHTTP.read("https://images.example/media/start", allowedURLPattern: pattern, transport: { request in
      if request.url.hasSuffix("start") {
        return .init(status: 302, headers: ["location": "/preview/photo.png?format=png"], body: Data(), url: request.url)
      }
      XCTAssertEqual(request.url, "https://images.example/preview/photo.png?format=png")
      return .init(status: 200, headers: [:], body: Data([1]), url: request.url)
    })
    XCTAssertEqual(response.body, Data([1]))
    for location in ["https://other.example/media/a", "/profile_images/a", "/media/a?token=PRIVATE", "/media/a#fragment", "https://127.0.0.1/media/a"] {
      do {
        _ = try await PublicWebHTTP.read("https://images.example/media/start", allowedURLPattern: pattern, transport: { request in
          XCTAssertEqual(request.url, "https://images.example/media/start", "redirect was fetched before policy")
          return .init(status: 302, headers: ["location": location], body: Data(), url: request.url)
        })
        XCTFail("disallowed redirect accepted")
      } catch { XCTAssertEqual(error as? PublicWebError, .urlPolicy) }
    }
    do {
      _ = try await PublicWebHTTP.read("https://images.example/media/a/extra", allowedURLPattern: pattern, transport: { _ in
        XCTFail("partial URL match reached transport"); throw PublicWebError.transport
      })
      XCTFail("partial URL accepted")
    } catch { XCTAssertEqual(error as? PublicWebError, .urlPolicy) }
  }

  func testEntireURLAlternativeCanBacktrackToTheLongerAllowedMatch() async throws {
    let response = try await PublicWebHTTP.read("https://example.com/a/b", allowedURLPattern: #"https://example\.com/a|https://example\.com/a/b"#,
      transport: { request in .init(status: 200, headers: [:], body: Data([1]), url: request.url) })
    XCTAssertEqual(response.body, Data([1]))
  }

  func testSerializedResponseOverflowBecomesFiniteOptionalFailure() async throws {
    try await PublicWebExecutionContext.$transport.withValue({ request in
      .init(status: 200, headers: ["untrusted": String(repeating: "PRIVATE", count: 1_000_001)], body: Data(), url: request.url)
    }) {
      let result = try await run(["action": .string("response"), "url": .string("https://example.com/image"), "failureMode": .string("result")])
      XCTAssertEqual(result, ["ok": .bool(false), "failure": .string("response-budget")])
    }
  }

  func testInvalidPatternsAndAuthenticationRefuseBeforeTransport() async throws {
    for pattern in ["", "[", String(repeating: "x", count: 1025)] {
      do {
        _ = try await PublicWebHTTP.read("https://example.com", allowedURLPattern: pattern, transport: { _ in
          XCTFail("invalid pattern reached transport"); throw PublicWebError.transport
        })
        XCTFail("invalid pattern accepted")
      } catch { XCTAssertEqual(error as? PublicWebError, .invalidInput) }
    }
    try await PublicWebExecutionContext.$transport.withValue({ _ in
      XCTFail("auth reached transport"); throw PublicWebError.transport
    }) {
      let result = try await run(["action": .string("response"), "url": .string("https://example.com"),
        "failureMode": .string("result"), "headers": .object(["Authorization": .string("PRIVATE")])])
      XCTAssertEqual(result, ["ok": .bool(false), "failure": .string("invalid-input-or-document")])
    }
  }

  func testOptionalFailuresAreFiniteAndCancellationStillPropagates() async throws {
    let failures: [(PublicWebError, String)] = [(.urlPolicy, "url-policy"), (.oversized, "response-budget"),
      (.blockedDestination, "blocked-destination"), (.httpStatus(403), "http-403"), (.timeout, "deadline")]
    for (failure, reason) in failures {
      try await PublicWebExecutionContext.$transport.withValue({ _ in throw failure }) {
        let result = try await run(["action": .string("response"), "url": .string("https://example.com"), "failureMode": .string("result")])
        XCTAssertEqual(result, ["ok": .bool(false), "failure": .string(reason)])
      }
    }
    try await PublicWebExecutionContext.$transport.withValue({ _ in throw CancellationError() }) {
      let result = await RielaCLIApplication().run(["node", "run", "riela/public-web", "--config",
        #"{"action":"response","url":"https://example.com","failureMode":"result"}"#, "--output", "json"], environment: ["PATH": ""])
      XCTAssertNotEqual(result.exitCode, .success)
      XCTAssertFalse(result.stdout.contains(#""ok":false"#))
    }
  }

  func testCancellationWinsOverConcurrentTransportFailureOrSuccess() async throws {
    for failure in [true, false] {
      let task = Task {
        await PublicWebExecutionContext.$transport.withValue({ request in
          withUnsafeCurrentTask { $0?.cancel() }
          if failure { throw PublicWebError.transport }
          return .init(status: 200, headers: [:], body: Data([1]), url: request.url)
        }) {
          await RielaCLIApplication().run(["node", "run", "riela/public-web", "--config",
            #"{"action":"response","url":"https://example.com","failureMode":"result"}"#, "--output", "json"], environment: ["PATH": ""])
        }
      }
      let result = await task.value
      XCTAssertNotEqual(result.exitCode, .success, "cancelled transport was accepted")
      XCTAssertFalse(result.stdout.contains(#""ok":false"#))
      XCTAssertFalse(result.stdout.contains(#""ok":true"#))
    }
  }

  func testFiveMegabyteBinaryRoundTripAndBoundedOversizeFailure() async throws {
    let body = Data(repeating: 137, count: 5_000_000)
    try await PublicWebExecutionContext.$transport.withValue({ request in
      XCTAssertEqual(request.maximumBytes, body.count)
      XCTAssertTrue(request.headers.isEmpty)
      return .init(status: 200, headers: [:], body: body, url: request.url)
    }) {
      let result = try await run(["action": .string("response"), "url": .string("https://example.com/image"),
        "maximumBytes": .integer(5_000_000), "failureMode": .string("result")])
      XCTAssertEqual(result["ok"], .bool(true))
      guard case let .string(encoded)? = result["bodyBase64"] else { return XCTFail("missing bytes") }
      XCTAssertEqual(Data(base64Encoded: encoded), body)
    }
    try await PublicWebExecutionContext.$transport.withValue({ request in
      .init(status: 200, headers: [:], body: Data(repeating: 1, count: request.maximumBytes + 1), url: request.url)
    }) {
      let result = try await run(["action": .string("response"), "url": .string("https://example.com/image"),
        "maximumBytes": .integer(5_000_000), "failureMode": .string("result")])
      XCTAssertEqual(result, ["ok": .bool(false), "failure": .string("response-budget")])
    }
  }

  private func run(_ config: JSONObject) async throws -> JSONObject {
    let result = await RielaCLIApplication().run(["node", "run", "riela/public-web", "--config", try JSONValue.object(config).compactJSONString(),
      "--output", "json"], environment: ["PATH": ""])
    XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
    return try JSONDecoder().decode(NodeRunCommandResult.self, from: Data(result.stdout.utf8)).payload
  }
}
// swiftlint:enable multiple_closures_with_trailing_closure
