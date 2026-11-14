import Foundation
import RielaCore
import XCTest

@testable import RielaCLI

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class HomeAssistantAddonTests: XCTestCase {
  private let env: JSONObject = [
    "HOME_ASSISTANT_URL": .object(["fromEnv": .string("HA_URL")]),
    "HOME_ASSISTANT_TOKEN": .object(["fromEnv": .string("HA_TOKEN")])
  ]

  func testReadStateRequestShapeAndStateLabel() async throws {
    let transport = HomeAssistantHTTPFixture(responses: [
      .init(status: 200, body: Data(#"{"entity_id":"light.kitchen","state":"On","attributes":{}}"#.utf8), retryAfter: nil)
    ])
    let output = try await execute(
      "riela/home-assistant-read", options: ["operation": .string("state"), "entityId": .string("light.kitchen")],
      transport: transport)
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.httpMethod, "GET")
    XCTAssertEqual(requests.first?.url?.absoluteString, "http://ha.local:8123/api/states/light.kitchen")
    XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer ha-secret-token")
    XCTAssertEqual(output.when["always"], true)
    XCTAssertEqual(output.when["state_on"], true)
    XCTAssertEqual(HomeAssistantPolicy.stateLabel("unavailable"), "state_unavailable")
    XCTAssertEqual(HomeAssistantPolicy.stateLabel("Not Home!"), "state_not_home_")
    XCTAssertEqual(HomeAssistantPolicy.stateLabel(String(repeating: "x", count: 80))?.count, 6 + 64)
    XCTAssertNil(HomeAssistantPolicy.stateLabel(""))
    guard case let .object(fields)? = output.payload["homeAssistant"], case let .object(state)? = fields["state"] else {
      return XCTFail("missing state payload")
    }
    XCTAssertEqual(state["state"], .string("On"))
  }

  func testReadStatesFiltersAndBounds() async throws {
    var entries: [String] = (0..<600).map { #"{"entity_id":"light.l\#($0)","state":"off"}"# }
    entries.append(#"{"entity_id":"switch.fan","state":"on"}"#)
    let transport = HomeAssistantHTTPFixture(responses: [
      .init(status: 200, body: Data("[\(entries.joined(separator: ","))]".utf8), retryAfter: nil),
      .init(status: 200, body: Data("[\(entries.joined(separator: ","))]".utf8), retryAfter: nil)
    ])
    let all = try await execute(
      "riela/home-assistant-read", options: ["operation": .string("states"), "domain": .string("light")],
      transport: transport)
    let fields = try XCTUnwrap(homeAssistantFields(all))
    XCTAssertEqual(fields["count"], .integer(500))
    XCTAssertEqual(fields["matched"], .integer(600))
    XCTAssertEqual(fields["truncated"], .bool(true))
    let picked = try await execute(
      "riela/home-assistant-read",
      options: ["operation": .string("states"), "entityIds": .array([.string("switch.fan"), .string("light.l3")])],
      transport: transport)
    let pickedFields = try XCTUnwrap(homeAssistantFields(picked))
    XCTAssertEqual(pickedFields["count"], .integer(2))
    let requests = await transport.requests
    XCTAssertEqual(requests.map { $0.url?.path }, ["/api/states", "/api/states"])
  }

  func testReadConfig() async throws {
    let transport = HomeAssistantHTTPFixture(responses: [
      .init(status: 200, body: Data(#"{"location_name":"Home","version":"2026.10.0"}"#.utf8), retryAfter: nil)
    ])
    let output = try await execute("riela/home-assistant-read", options: ["operation": .string("config")], transport: transport)
    let fields = try XCTUnwrap(homeAssistantFields(output))
    XCTAssertEqual(fields["config"], .object(["location_name": .string("Home"), "version": .string("2026.10.0")]))
    let path = await transport.requests.first?.url?.path
    XCTAssertEqual(path, "/api/config")
  }

  func testWriteServiceRequestShape() async throws {
    let transport = HomeAssistantHTTPFixture(responses: [
      .init(status: 200, body: Data(#"[{"entity_id":"remote.living","state":"on"}]"#.utf8), retryAfter: nil)
    ])
    let output = try await execute("riela/home-assistant-write", options: [
      "operation": .string("service"), "domain": .string("remote"), "service": .string("send_command"),
      "target": .object(["entity_id": .string("remote.living")]),
      "data": .object(["device": .string("aircon"), "command": .string("off")]),
      "allowedServices": .array([.string("remote.send_command")]),
      "allowedEntities": .array([.string("remote.*")])
    ], transport: transport)
    let firstRequest = await transport.requests.first
    let request = try XCTUnwrap(firstRequest)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.absoluteString, "http://ha.local:8123/api/services/remote/send_command")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
    XCTAssertEqual(body, .object([
      "entity_id": .string("remote.living"), "device": .string("aircon"), "command": .string("off")
    ]))
    let fields = try XCTUnwrap(homeAssistantFields(output))
    XCTAssertEqual(fields["changedCount"], .integer(1))
  }

  func testWriteAllowlistEnforcement() async throws {
    let base: JSONObject = [
      "operation": .string("service"), "domain": .string("light"), "service": .string("turn_on"),
      "allowedServices": .array([.string("light.*"), .string("switch.turn_off")]),
      "allowedEntities": .array([.string("light.kitchen"), .string("switch.*")])
    ]
    func with(_ changes: JSONObject) -> JSONObject { base.merging(changes) { $1 } }
    let allowed: [(String, JSONObject)] = [
      ("exact entity", with(["target": .object(["entity_id": .string("light.kitchen")])])),
      ("array in data", with(["data": .object(["entity_id": .array([.string("light.kitchen"), .string("switch.a")])])])),
      ("comma string", with(["target": .object(["entity_id": .string("light.kitchen, switch.b")])]))
    ]
    for (label, options) in allowed {
      let transport = HomeAssistantHTTPFixture(responses: [.init(status: 200, body: Data("[]".utf8), retryAfter: nil)])
      _ = try await execute("riela/home-assistant-write", options: options, transport: transport)
      let count = await transport.requests.count
      XCTAssertEqual(count, 1, label)
    }
    let blocked: [(String, JSONObject)] = [
      ("service not allowed", with(["domain": .string("lock"), "service": .string("unlock"),
        "target": .object(["entity_id": .string("light.kitchen")])])),
      ("exact service mismatch", with(["domain": .string("switch"), "service": .string("turn_on"),
        "target": .object(["entity_id": .string("switch.a")])])),
      ("entity not allowed", with(["target": .object(["entity_id": .string("light.hall")])])),
      ("array with one bad entity", with(["target": .object(["entity_id": .array([.string("light.kitchen"), .string("light.hall")])])])),
      ("bad entity in data", with(["target": .object(["entity_id": .string("light.kitchen")]),
        "data": .object(["entity_id": .string("light.hall")])])),
      ("all entities", with(["target": .object(["entity_id": .string("all")])])),
      ("area bypass", with(["target": .object(["entity_id": .string("light.kitchen"), "area_id": .string("living")])])),
      ("no entity", with(["data": .object(["brightness": .integer(10)])])),
      ("non-string entity", with(["target": .object(["entity_id": .array([.integer(1)])])])),
      ("missing allowedServices", ["operation": .string("service"), "domain": .string("light"),
        "service": .string("turn_on"), "target": .object(["entity_id": .string("light.kitchen")])]),
      ("empty allowedServices", with(["allowedServices": .array([])])),
      ("templated allowedServices", with(["allowedServices": .array([.string("{{policy}}")]),
        "target": .object(["entity_id": .string("light.kitchen")])]))
    ]
    for (label, options) in blocked {
      let transport = HomeAssistantHTTPFixture(responses: [])
      do {
        _ = try await execute(
          "riela/home-assistant-write", options: options, transport: transport,
          variables: ["policy": .string("light.turn_on")])
        XCTFail("\(label) should be blocked")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .policyBlocked, "\(label): \(error.message)")
      }
      let count = await transport.requests.count
      XCTAssertEqual(count, 0, label)
    }
  }

  func testWriteWithoutEntityAllowlistStillChecksService() async throws {
    let transport = HomeAssistantHTTPFixture(responses: [.init(status: 200, body: Data("[]".utf8), retryAfter: nil)])
    _ = try await execute("riela/home-assistant-write", options: [
      "operation": .string("service"), "domain": .string("scene"), "service": .string("turn_on"),
      "target": .object(["entity_id": .string("scene.movie")]),
      "allowedServices": .array([.string("scene.turn_on")])
    ], transport: transport)
    let count = await transport.requests.count
    XCTAssertEqual(count, 1)
  }

  func testErrorMapping() async throws {
    let cases: [Int: (body: String, code: AdapterExecutionErrorCode)] = [
      401: ("401: Unauthorized", .policyBlocked),
      404: (#"{"message":"Entity not found."}"#, .invalidInput),
      503: ("busy", .providerError),
      200: ("<html>not json</html>", .providerError)
    ]
    for (status, expected) in cases {
      let (body, code) = expected
      let transport = HomeAssistantHTTPFixture(responses: [.init(status: status, body: Data(body.utf8), retryAfter: nil)])
      do {
        _ = try await execute(
          "riela/home-assistant-read", options: ["operation": .string("state"), "entityId": .string("light.x")],
          transport: transport)
        XCTFail("HTTP \(status) should fail")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, code, "HTTP \(status): \(error.message)")
        XCTAssertFalse(error.message.contains("ha-secret-token"))
        if status == 404 { XCTAssertTrue(error.message.contains("Entity not found."), error.message) }
        if status == 503 { XCTAssertEqual(error.isRetryable, true) }
      }
    }
  }

  func testEnvironmentPolicy() async throws {
    let transport = HomeAssistantHTTPFixture(responses: [])
    let options: JSONObject = ["operation": .string("config")]
    let badEnvs: [(JSONObject, [String: String])] = [
      ([:], ["HA_URL": "http://ha.local:8123", "HA_TOKEN": "t"]),
      (env.merging(["OTHER": .object(["fromEnv": .string("HA_URL")])]) { $1 }, ["HA_URL": "http://ha.local:8123", "HA_TOKEN": "t"]),
      (env, ["HA_URL": "ftp://ha.local", "HA_TOKEN": "t"]),
      (env, ["HA_URL": "http://user:pw@ha.local", "HA_TOKEN": "t"])
    ]
    for (bindings, environment) in badEnvs {
      do {
        _ = try await execute(
          "riela/home-assistant-read", options: options, transport: transport, env: bindings, environment: environment)
        XCTFail("environment \(bindings.keys.sorted()) should be blocked")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .policyBlocked, error.message)
      }
    }
  }

  func testRegistrationsAndInvalidOperation() async throws {
    XCTAssertNotNil(BuiltinStatefulAddonRegistry.handlers["riela/home-assistant-read"])
    XCTAssertNotNil(BuiltinStatefulAddonRegistry.handlers["riela/home-assistant-write"])
    do {
      _ = try await execute(
        "riela/home-assistant-read", options: ["operation": .string("delete")],
        transport: HomeAssistantHTTPFixture(responses: []))
      XCTFail("unknown operation should fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
    }
  }

  private func execute(
    _ name: String, options: JSONObject, transport: HomeAssistantHTTPFixture,
    env bindings: JSONObject? = nil,
    environment: [String: String] = ["HA_URL": "http://ha.local:8123/", "HA_TOKEN": "ha-secret-token"],
    variables: JSONObject = [:]
  ) async throws -> AdapterExecutionOutput {
    let resolver = BuiltinWorkflowAddonResolver(
      environment: environment, mediaPipelineHTTP: { request in try await transport.send(request) })
    let input = WorkflowAddonExecutionInput(
      workflowId: "ha", stepId: "ha", nodeId: "ha",
      addon: .init(name: name, version: "1", config: ["options": .object(options)], env: bindings ?? env),
      variables: variables)
    return try await resolver.execute(input, context: .init())
  }

  private func homeAssistantFields(_ output: AdapterExecutionOutput) -> JSONObject? {
    guard case let .object(fields)? = output.payload["homeAssistant"] else { return nil }
    return fields
  }
}

private actor HomeAssistantHTTPFixture {
  private var responses: [MediaPipelineHTTPResponse]
  private(set) var requests: [URLRequest] = []

  init(responses: [MediaPipelineHTTPResponse]) { self.responses = responses }

  func send(_ request: URLRequest) throws -> MediaPipelineHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw URLError(.cannotConnectToHost) }
    return responses.removeFirst()
  }
}
