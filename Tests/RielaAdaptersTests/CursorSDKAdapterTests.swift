import Foundation
import XCTest
@testable import RielaAdapters
@testable import RielaCore

private final class RecordingCursorHTTPTransport: OfficialSDKHTTPTransporting, @unchecked Sendable {
  private let queue = DispatchQueue(label: "riela.cursor-sdk-http-test-transport")
  private var capturedRequests: [URLRequest] = []
  private var responses: [OfficialSDKHTTPResponse]

  init(responses: [OfficialSDKHTTPResponse]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> OfficialSDKHTTPResponse {
    queue.sync {
      capturedRequests.append(request)
    }
    return queue.sync {
      responses.isEmpty ? OfficialSDKHTTPResponse(statusCode: 500, body: Data()) : responses.removeFirst()
    }
  }

  func requests() -> [URLRequest] {
    queue.sync {
      capturedRequests
    }
  }
}

final class CursorSDKAdapterTests: XCTestCase {
  func testDefaultCursorHTTPExecutorBuildsCloudAgentRequest() async throws {
    let transport = RecordingCursorHTTPTransport(responses: [
      try httpResponse([
        "id": .string("bc-123"),
        "status": .string("ACTIVE"),
        "url": .string("https://cursor.com/agents/bc-123"),
        "latestRunId": .string("run-123")
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

    let output = try await adapter.execute(
      cursorSDKInput(
        systemPromptText: "system",
        agentEnvironment: [
          "CURSOR_REPOSITORY_URL": "https://github.com/acme/riela.git",
          "CURSOR_STARTING_REF": "main",
          "CURSOR_WORK_ON_CURRENT_BRANCH": "true",
          "CURSOR_AUTO_CREATE_PR": "false"
        ]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.provider, "official-cursor-sdk")
    XCTAssertEqual(
      output.payload["text"],
      .string("Cursor agent bc-123\nstatus: ACTIVE\nlatest run: run-123\nhttps://cursor.com/agents/bc-123")
    )
    let request = try XCTUnwrap(transport.requests().first)
    XCTAssertEqual(request.url?.absoluteString, "https://cursor.test/v1/agents")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization"),
      "Basic \(Data("\(cursorTestKey()):".utf8).base64EncodedString())"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    let body = try requestJSONObject(request)
    XCTAssertEqual(body["prompt"], .object(["text": .string("system\n\nhello")]))
    XCTAssertEqual(body["model"], .object(["id": .string("composer-2")]))
    XCTAssertEqual(body["repos"], .array([.object([
      "url": .string("https://github.com/acme/riela.git"),
      "startingRef": .string("main")
    ])]))
    XCTAssertEqual(body["workOnCurrentBranch"], .bool(true))
    XCTAssertEqual(body["autoCreatePR"], .bool(false))
  }

  private func cursorSDKInput(
    systemPromptText: String? = nil,
    agentEnvironment: [String: String] = [:]
  ) -> AdapterExecutionInput {
    AdapterExecutionInput(
      node: AgentNodePayload(id: "worker", executionBackend: .officialCursorSDK, model: "composer-2"),
      promptText: "hello",
      systemPromptText: systemPromptText,
      agentEnvironment: agentEnvironment
    )
  }

  private func cursorTestKey() -> String {
    ["cursor", "test", "123456"].joined(separator: "-")
  }

  private func httpResponse(_ object: JSONObject, statusCode: Int = 200) throws -> OfficialSDKHTTPResponse {
    let body = try JSONEncoder().encode(JSONValue.object(object))
    return OfficialSDKHTTPResponse(statusCode: statusCode, body: body)
  }

  private func requestJSONObject(_ request: URLRequest) throws -> JSONObject {
    let data = try XCTUnwrap(request.httpBody)
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    guard case let .object(object) = value else {
      XCTFail("Expected JSON object request body")
      return [:]
    }
    return object
  }
}
