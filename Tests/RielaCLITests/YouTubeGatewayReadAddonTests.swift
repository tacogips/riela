import RielaCore
import XCTest
@testable import RielaCLI

final class YouTubeGatewayReadAddonTests: XCTestCase {
  func testParserDefaultsAndPagination() throws {
    XCTAssertEqual(try YouTubeGatewayReadEngine.parse(operation: "videos.list", arguments: [
      "ids": .array([.string("a"), .string("b")])
    ]), .videos(ids: ["a", "b"], parts: ["snippet", "contentDetails", "statistics"], pageToken: nil))
    XCTAssertEqual(try YouTubeGatewayReadEngine.parse(operation: "subscriptions.list", arguments: [
      "mine": .bool(true), "maxResults": .integer(25), "pageToken": .string("P2")
    ]), .subscriptions(filter: .mine, forChannelId: nil, order: nil,
      parts: ["snippet", "contentDetails"], maxResults: 25, pageToken: "P2"))
  }

  func testRejectsInvalidRequests() {
    let invalid: [(String, JSONObject)] = [
      ("subscriptions.insert", [:]),
      ("subscriptions.list", [:]),
      ("subscriptions.list", ["mine": .bool(true), "channelId": .string("x")]),
      ("subscriptions.list", ["mine": .bool(true), "maxResults": .integer(51)]),
      ("videos.list", ["ids": .array([])]),
      ("channels.list", ["mine": .bool(true), "parts": .array([.string("statistics")])]),
      ("playlistItems.list", ["playlistId": .string("x"), "unknown": .bool(true)])
    ]
    for (operation, arguments) in invalid {
      XCTAssertThrowsError(try YouTubeGatewayReadEngine.parse(operation: operation, arguments: arguments), operation)
    }
  }
}

extension YouTubeGatewayReadAddonTests {
  func testValidationAndRegistry() {
    func issues(_ operation: String, _ args: JSONObject) -> [WorkflowGatewayRequestIssue] {
      BuiltinGatewayRequestChecks.issues(.init(name: "riela/youtube-gateway-read", version: "1", config: [
        "operation": .string(operation), "arguments": .object(args)
      ]))
    }
    XCTAssertEqual(issues("subscriptions.insert", [:]).first?.relativePath, "")
    XCTAssertEqual(issues("subscriptions.list", [:]).first?.relativePath, "arguments")
    XCTAssertFalse(issues("subscriptions.list", ["mine": .bool(true), "unknown": .string("{{input.x}}")]).isEmpty)
    XCTAssertTrue(issues("subscriptions.list", ["mine": .bool(true), "pageToken": .string("{{input.token}}")]).isEmpty)
    XCTAssertFalse(issues("videos.list", ["ids": .array(Array(repeating: .string("x"), count: 51))]).isEmpty)
    XCTAssertFalse(issues("subscriptions.list", ["mine": .bool(true), "maxResults": .integer(0)]).isEmpty)
    XCTAssertEqual(BuiltinStatefulAddonRegistry.registrations.filter { $0.name == "riela/youtube-gateway-read" }.count, 1)
  }
}

#if canImport(YouTubeGatewayCore)
import Foundation
import YouTubeGatewayCore

private actor YouTubeReadTransport: HTTPTransport {
  let status: Int
  let body: String
  private var captured: [URL] = []
  init(status: Int = 200, body: String = #"{"items":[],"nextPageToken":"P3"}"#) {
    self.status = status
    self.body = body
  }
  func send(_ request: URLRequest) async throws -> HTTPResult {
    if let url = request.url { captured.append(url) }
    return HTTPResult(data: Data(body.utf8), status: status)
  }
  func urls() -> [URL] { captured }
}

private struct YouTubeReadCase {
  let operation: String
  let arguments: JSONObject
  let resource: String
  let query: [String: String]
}

extension YouTubeGatewayReadAddonTests {
  private func input(_ operation: String, _ arguments: JSONObject, env: JSONObject? = nil, postprocess: Bool = false) -> WorkflowAddonExecutionInput {
    var config: JSONObject = ["operation": .string(operation), "arguments": .object(arguments)]
    if postprocess { config["postprocess"] = .array([.object(["pick": .string("/data/nextPageToken")])]) }
    return .init(workflowId: "test", stepId: "list", nodeId: "list", addon: .init(
      name: "riela/youtube-gateway-read", version: "1", config: config,
      env: env ?? ["YOUTUBE_GATEWAY_ACCESS_TOKEN": .object(["fromEnv": .string("TEST_YOUTUBE_AUTH"), "required": .bool(false)])]
    ), variables: [:], resolvedInputPayload: [:])
  }

  private func invoke(_ input: WorkflowAddonExecutionInput, transport: YouTubeReadTransport, environment: [String: String] = ["TEST_YOUTUBE_AUTH": "fixture"]) async throws -> AdapterExecutionOutput {
    let plan = try BuiltinPostprocessPlan(input)
    let output = try await BuiltinWorkflowAddonResolver(environment: environment).executeYouTubeGatewayRead(
      plan.input, context: .init(), makeClient: { _ in YouTubeClient(transport: transport) { "fixture" } }
    )
    return plan.apply(to: output)
  }

  func testTransportOperationsAndPostprocess() async throws {
    let transport = YouTubeReadTransport()
    let cases: [YouTubeReadCase] = [
      .init(operation: "subscriptions.list", arguments: ["mine": .bool(true), "maxResults": .integer(25), "pageToken": .string("P2")],
        resource: "subscriptions", query: ["mine": "true", "maxResults": "25", "pageToken": "P2"]),
      .init(operation: "videos.list", arguments: ["ids": .array([.string("a"), .string("b")])], resource: "videos", query: ["id": "a,b", "part": "snippet,contentDetails,statistics"]),
      .init(operation: "channels.list", arguments: ["forHandle": .string("@x")], resource: "channels", query: ["forHandle": "x"]),
      .init(operation: "playlistItems.list", arguments: ["playlistId": .string("UU1"), "maxResults": .integer(50)], resource: "playlistItems", query: ["playlistId": "UU1", "maxResults": "50"])
    ]
    for item in cases {
      let request = input(item.operation, item.arguments, postprocess: true)
      XCTAssertTrue(BuiltinGatewayRequestChecks.issues(request.addon).isEmpty)
      let output = try await invoke(request, transport: transport)
      XCTAssertEqual(output.payload["status"], .string("ok"))
      XCTAssertEqual(output.payload["operation"], .string(item.operation))
      XCTAssertEqual(output.payload["processed"], .string("P3"))
      XCTAssertEqual(output.when["postprocessPassed"], true)
    }
    let urls = await transport.urls()
    XCTAssertEqual(urls.count, cases.count)
    for (url, item) in zip(urls, cases) {
      XCTAssertEqual(url.lastPathComponent, item.resource)
      let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
      for (key, value) in item.query { XCTAssertEqual(query[key], value) }
    }
  }

  func testCredentialPolicyAndHTTPRedaction() async throws {
    let transport = YouTubeReadTransport()
    for (bindings, environment) in [
      (["OTHER": JSONValue.object(["fromEnv": .string("TEST_YOUTUBE_AUTH")])], ["TEST_YOUTUBE_AUTH": "fixture"]),
      (["YOUTUBE_GATEWAY_ACCESS_TOKEN": JSONValue.object(["fromEnv": .string("TEST_YOUTUBE_AUTH"), "required": .bool(false)])], ["TEST_YOUTUBE_AUTH": "  "])
    ] {
      do {
        _ = try await invoke(input("subscriptions.list", ["mine": .bool(true)], env: bindings), transport: transport, environment: environment)
        XCTFail("expected policy error")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .policyBlocked)
        XCTAssertFalse(error.message.contains("fixture"))
      }
    }
    for (status, body, code) in [
      (401, #"{"error":{"message":"SENTINEL","errors":[{"reason":"authError"}]}}"#, AdapterExecutionErrorCode.policyBlocked),
      (403, #"{"error":{"message":"SENTINEL","errors":[{"reason":"quotaExceeded"}]}}"#, .policyBlocked),
      (500, #"{"error":{"message":"SENTINEL","errors":[{"reason":"backendError"}]}}"#, .providerError)
    ] {
      do {
        _ = try await invoke(input("subscriptions.list", ["mine": .bool(true)]), transport: YouTubeReadTransport(status: status, body: body))
        XCTFail("expected provider failure")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, code)
        XCTAssertFalse(error.message.contains("SENTINEL"))
      }
    }
  }
}
#endif

extension YouTubeGatewayReadAddonTests {
  func testExampleCLIValidationAndMockRun() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("youtube-gateway-read")
    defer { try? FileManager.default.removeItem(at: root) }
    let examples = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("examples")
    let app = RielaCLIApplication()
    let valid = await app.run(["workflow", "validate", "youtube-gateway-read", "--workflow-definition-dir", examples.path, "--output", "json"])
    XCTAssertEqual(valid.exitCode, .success, valid.stderr + valid.stdout)
    let run = await app.run(["workflow", "run", "youtube-gateway-read", "--workflow-definition-dir", examples.path,
      "--mock-scenario", examples.appendingPathComponent("youtube-gateway-read/mock-scenario.json").path,
      "--session-store", root.appendingPathComponent("sessions").path, "--max-steps", "20", "--output", "json"])
    XCTAssertEqual(run.exitCode, .success, run.stderr + run.stdout)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
    let session = try XCTUnwrap(json["session"] as? [String: Any])
    XCTAssertEqual(session["status"] as? String, "completed")
    let output = try XCTUnwrap(json["rootOutput"] as? [String: Any])
    XCTAssertEqual(output["nextPageToken"] as? String, "fixture-next")
    XCTAssertEqual((output["items"] as? [Any])?.count, 2)
  }
}
