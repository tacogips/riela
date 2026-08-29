import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

/// wrike-gateway is linked into this process, so these tests record what the
/// add-on hands its GraphQL runtime — tier, document, variables, and the
/// environment the gateway is allowed to see — instead of stubbing an
/// executable on `PATH`. wrike-gateway's own tests cover the runtime.
final class WrikeGatewayAddonTests: XCTestCase {
  private static let tasksResponse = """
  {
    "data": {
      "tasks": {
        "nodes": [
          {"id": "TASK-1", "title": "In progress work", "customStatusId": "STATUS-DOING"},
          {"id": "TASK-2", "title": "Waiting work", "customStatusId": "STATUS-TODO"}
        ],
        "pageInfo": {"resultCount": 2, "nextPageToken": null}
      }
    },
    "extensions": {"requestId": "REQUEST_ID"}
  }
  """

  private static let commentsResponse = """
  {
    "data": {
      "comments": [
        {"id": "COMMENT-1", "authorId": "USER-1", "text": "<a rel=\\"KUAYWWKI\\">@Bot</a> first question"},
        {"id": "COMMENT-2", "authorId": "BOT-1", "text": "answer text [re:COMMENT-1] <a rel=\\"KUAYWWKI\\">@Bot</a>"},
        {"id": "COMMENT-3", "authorId": "USER-2", "text": "<a rel=\\"KUAYWWKI\\">@Bot</a> newest question"},
        {"id": "COMMENT-4", "authorId": "BOT-1", "text": "<a rel=\\"KUAYWWKI\\">@Bot</a> self note"}
      ]
    },
    "extensions": {"requestId": "REQUEST_ID"}
  }
  """

  private static func response(_ body: String, requestId: String) -> String {
    body.replacingOccurrences(of: "REQUEST_ID", with: requestId)
  }
  func testReadRendersDocumentVariablesAndSelectionFlags() async throws {
    let gateway = RecordingGatewayGraphQLRunner(
      response: Self.response(Self.tasksResponse, requestId: "req-read")
    )

    let output = try await runWrike(
      gateway: gateway,
      name: "riela/wrike-gateway-read",
      config: [
        "queryTemplate": .string("query T($fid: ID!) { tasks(scope: { folderId: $fid }, status: Active) { nodes { id title customStatusId } } }"),
        "variablesTemplate": .object(["fid": .string("{{workflowInput.projectFolderId}}")]),
        "selectFirst": .object([
          "path": .string("data.tasks.nodes"),
          "where": .object(["customStatusId": .string("{{workflowInput.todoStatusId}}")])
        ]),
        "whenFlags": .object([
          "has_todo_task": .string("selected.id"),
          "has_tasks": .string("data.tasks.nodes.0.id")
        ])
      ],
      variables: [
        "workflowInput": .object([
          "projectFolderId": .string("FOLDER-1"),
          "todoStatusId": .string("STATUS-TODO")
        ])
      ]
    )

    let call = try XCTUnwrap(gateway.lastCall())
    XCTAssertEqual(call.tier, "wrike-gateway-reader")
    XCTAssertTrue(call.document.contains("tasks(scope: { folderId: $fid }, status: Active)"))
    XCTAssertTrue(try XCTUnwrap(call.variablesJSON).contains("\"fid\":\"FOLDER-1\""))
    let selected = try XCTUnwrap(wrikeTestObject(output.payload["selected"]))
    XCTAssertEqual(selected["id"], .string("TASK-2"))
    XCTAssertEqual(selected["customStatusId"], .string("STATUS-TODO"))
    XCTAssertEqual(output.when["has_todo_task"], true)
    XCTAssertEqual(output.when["has_tasks"], true)
    XCTAssertEqual(output.when["ok"], true)
    let data = try XCTUnwrap(wrikeTestObject(output.payload["data"]))
    XCTAssertNotNil(data["tasks"])
    XCTAssertEqual(output.payload["requestId"], .string("req-read"))
  }

  func testSelectFirstWithoutMatchYieldsFalseFlagAndNullSelection() async throws {
    let output = try await runWrike(
      gateway: RecordingGatewayGraphQLRunner(
        response: Self.response(Self.tasksResponse, requestId: "req-empty")
      ),
      name: "riela/wrike-gateway-read",
      config: [
        "queryTemplate": .string("{ tasks { nodes { id customStatusId } } }"),
        "selectFirst": .object([
          "path": .string("data.tasks.nodes"),
          "where": .object(["customStatusId": .string("STATUS-MISSING")])
        ]),
        "whenFlags": .object(["has_todo_task": .string("selected.id")])
      ]
    )

    XCTAssertEqual(output.payload["selected"], .null)
    XCTAssertEqual(output.when["has_todo_task"], false)
  }

  func testEnvironmentBindingsInjectOnlyAllowedWrikeVariables() async throws {
    let gateway = RecordingGatewayGraphQLRunner(
      response: Self.response(Self.tasksResponse, requestId: "req-env")
    )

    _ = try await runWrike(
      gateway: gateway,
      name: "riela/wrike-gateway-read",
      config: ["queryTemplate": .string("{ account { id } }")],
      env: [
        "WRIKE_GATEWAY_ACCESS_TOKEN": .object(["fromEnv": .string("RIELA_WRIKE_ACCESS_TOKEN")]),
        "WRIKE_GATEWAY_API_BASE_URL": .object(["fromEnv": .string("RIELA_WRIKE_API_BASE_URL")])
      ],
      environment: [
        "RIELA_WRIKE_ACCESS_TOKEN": "sentinel-token",
        "RIELA_WRIKE_API_BASE_URL": "https://www.wrike.com/api/v4",
        "OPENAI_API_KEY": "sentinel-openai"
      ]
    )

    let call = try XCTUnwrap(gateway.lastCall())
    XCTAssertEqual(call.environment["WRIKE_GATEWAY_ACCESS_TOKEN"], "sentinel-token")
    XCTAssertEqual(call.environment["WRIKE_GATEWAY_API_BASE_URL"], "https://www.wrike.com/api/v4")
    // Hosting the gateway in this process must not widen what it can read:
    // ambient secrets are still withheld.
    XCTAssertNil(call.environment["OPENAI_API_KEY"])
  }

  func testEnvironmentBindingRejectsNonWrikeTargetNames() async throws {
    try await assertWrikeFailure(
      gateway: RecordingGatewayGraphQLRunner(),
      name: "riela/wrike-gateway-read",
      config: ["queryTemplate": .string("{ account { id } }")],
      env: ["LD_PRELOAD": .object(["fromEnv": .string("RIELA_WRIKE_ACCESS_TOKEN")])],
      environment: ["RIELA_WRIKE_ACCESS_TOKEN": "sentinel-token"],
      code: .policyBlocked,
      messageContains: "addon.env target 'LD_PRELOAD'"
    )
  }

  func testEnvironmentBindingRequiresConfiguredSourceValue() async throws {
    try await assertWrikeFailure(
      gateway: RecordingGatewayGraphQLRunner(),
      name: "riela/wrike-gateway-read",
      config: ["queryTemplate": .string("{ account { id } }")],
      env: ["WRIKE_GATEWAY_ACCESS_TOKEN": .object(["fromEnv": .string("RIELA_WRIKE_ACCESS_TOKEN")])],
      code: .policyBlocked,
      messageContains: "RIELA_WRIKE_ACCESS_TOKEN"
    )
  }

  func testWriteAndAdminPinTheirOwnTier() async throws {
    let writer = RecordingGatewayGraphQLRunner(
      response: #"{"data":{"updateTask":{"task":{"id":"TASK-1"}}},"extensions":{"requestId":"req-write"}}"#
    )
    let admin = RecordingGatewayGraphQLRunner(
      response: #"{"data":{"deleteTask":{"deletedId":"TASK-1"}},"extensions":{"requestId":"req-admin"}}"#
    )

    let writeOutput = try await runWrike(
      gateway: writer,
      name: "riela/wrike-gateway-write",
      config: ["queryTemplate": .string("mutation { updateTask(input: { taskId: \"TASK-1\" }) { task { id } } }")]
    )
    XCTAssertEqual(wrikeTier(writeOutput), "wrike-gateway-writer")
    XCTAssertEqual(writer.lastCall()?.tier, "wrike-gateway-writer")
    XCTAssertEqual(writeOutput.payload["requestId"], .string("req-write"))

    let adminOutput = try await runWrike(
      gateway: admin,
      name: "riela/wrike-gateway-admin",
      config: ["queryTemplate": .string("mutation { deleteTask(input: { taskId: \"TASK-1\" }) { deletedId } }")]
    )
    XCTAssertEqual(wrikeTier(adminOutput), "wrike-gateway-admin")
    XCTAssertEqual(admin.lastCall()?.tier, "wrike-gateway-admin")
    XCTAssertEqual(adminOutput.payload["requestId"], .string("req-admin"))
  }

  func testGraphQLErrorEnvelopeFailsWithStableCode() async throws {
    try await assertWrikeFailure(
      gateway: RecordingGatewayGraphQLRunner(
        response: #"{"errors":[{"message":"delete is not available in this tier","extensions":{"code":"CAPABILITY_DENIED"}}]}"#
      ),
      name: "riela/wrike-gateway-read",
      config: ["queryTemplate": .string("{ account { id } }")],
      code: .providerError,
      messageContains: "CAPABILITY_DENIED"
    )
  }

  func testGatewayFailureIsSurfacedAsAProviderError() async throws {
    try await assertWrikeFailure(
      gateway: RecordingGatewayGraphQLRunner(
        failure: AdapterExecutionError(.providerError, "wrike-gateway wrike-gateway-reader failed: credential store unavailable")
      ),
      name: "riela/wrike-gateway-read",
      config: ["queryTemplate": .string("{ account { id } }")],
      code: .providerError,
      messageContains: "credential store unavailable"
    )
  }

  func testMissingQueryTemplateIsRejected() async throws {
    try await assertWrikeFailure(
      gateway: RecordingGatewayGraphQLRunner(),
      name: "riela/wrike-gateway-read",
      config: [:],
      code: .policyBlocked,
      messageContains: "config.queryTemplate is required"
    )
  }

  func testSelectFirstOperatorsAndLastPosition() async throws {
    let output = try await runWrike(
      gateway: RecordingGatewayGraphQLRunner(
        response: Self.response(Self.commentsResponse, requestId: "req-ops")
      ),
      name: "riela/wrike-gateway-read",
      config: [
        "queryTemplate": .string("{ comments { id authorId text } }"),
        "selectFirst": .object([
          "path": .string("data.comments"),
          "position": .string("last"),
          "where": .object([
            "text": .object([
              "contains": .string("rel=\"KUAYWWKI\""),
              "notContains": .string("[re:")
            ]),
            "authorId": .object(["ne": .string("BOT-1")])
          ])
        ]),
        "whenFlags": .object(["has_mention": .string("selected.id")])
      ]
    )

    let selected = try XCTUnwrap(wrikeTestObject(output.payload["selected"]))
    XCTAssertEqual(selected["id"], .string("COMMENT-3"))
    XCTAssertEqual(output.when["has_mention"], true)
  }

  func testNowVariablesRenderIntoQueryVariables() async throws {
    let gateway = RecordingGatewayGraphQLRunner(
      response: Self.response(Self.tasksResponse, requestId: "req-now")
    )

    _ = try await runWrike(
      gateway: gateway,
      name: "riela/wrike-gateway-read",
      config: [
        "queryTemplate": .string("query T($r: InstantRangeInput) { tasks(updatedDate: $r) { nodes { id } } }"),
        "nowVariables": .object(["since": .integer(-900)]),
        "variablesTemplate": .object(["r": .object(["start": .string("{{since}}")])])
      ]
    )

    let variablesJSON = try XCTUnwrap(gateway.lastCall()?.variablesJSON)
    XCTAssertTrue(
      variablesJSON.range(of: #""start":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z""#, options: .regularExpression) != nil,
      variablesJSON
    )
  }

  func testPayloadExtrasCarryRenderedValues() async throws {
    let output = try await runWrike(
      gateway: RecordingGatewayGraphQLRunner(
        response: Self.response(Self.tasksResponse, requestId: "req-extras")
      ),
      name: "riela/wrike-gateway-read",
      config: [
        "queryTemplate": .string("{ tasks { nodes { id } } }"),
        "payloadExtras": .object(["task": .string("{{input.task}}")])
      ],
      resolvedInputPayload: ["task": .object(["id": .string("TASK-9"), "title": .string("Carried")])]
    )

    let task = try XCTUnwrap(wrikeTestObject(output.payload["task"]))
    XCTAssertEqual(task["id"], .string("TASK-9"))
    XCTAssertEqual(task["title"], .string("Carried"))
  }

  private func runWrike(
    gateway: RecordingGatewayGraphQLRunner,
    name: String,
    config: JSONObject = [:],
    addonInputs: JSONObject = [:],
    env: JSONObject? = nil,
    environment: [String: String] = [:],
    variables: JSONObject = [:],
    resolvedInputPayload: JSONObject = [:],
    context: AdapterExecutionContext = AdapterExecutionContext()
  ) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(
      environment: environment,
      localGatewayGraphQLRunner: gateway.runner
    ).execute(
      WorkflowAddonExecutionInput(
        workflowId: "wrike-gateway-test",
        stepId: "wrike-step",
        nodeId: "wrike-node",
        addon: WorkflowNodeAddonRef(
          name: name,
          version: "1",
          config: config,
          env: env,
          inputs: addonInputs
        ),
        variables: variables,
        resolvedInputPayload: resolvedInputPayload
      ),
      context: context
    )
  }

  private func assertWrikeFailure(
    gateway: RecordingGatewayGraphQLRunner,
    name: String,
    config: JSONObject = [:],
    addonInputs: JSONObject = [:],
    env: JSONObject? = nil,
    environment: [String: String] = [:],
    variables: JSONObject = [:],
    code: AdapterExecutionErrorCode,
    messageContains: String
  ) async throws {
    do {
      _ = try await runWrike(
        gateway: gateway,
        name: name,
        config: config,
        addonInputs: addonInputs,
        env: env,
        environment: environment,
        variables: variables
      )
      XCTFail("expected wrike-gateway add-on to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, code)
      XCTAssertTrue(error.message.contains(messageContains), error.message)
    }
  }

  private func wrikeTier(_ output: AdapterExecutionOutput) -> String? {
    guard case let .object(gateway)? = output.payload["wrikeGateway"],
          case let .object(runtime)? = gateway["runtime"],
          case let .string(tier)? = runtime["tier"] else {
      return nil
    }
    return tier
  }
}

private func wrikeTestObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object)? = value else {
    return nil
  }
  return object
}
