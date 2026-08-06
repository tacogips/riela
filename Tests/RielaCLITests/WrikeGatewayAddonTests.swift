import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class WrikeGatewayAddonTests: XCTestCase {
  func testReadRendersDocumentVariablesAndSelectionFlags() async throws {
    let fake = try FakeWrikeGateway(mode: "tasks-success", requestId: "req-read")
    defer { fake.cleanup() }

    let output = try await runWrike(
      name: "riela/wrike-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
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

    let document = try String(contentsOf: fake.queryLogURL)
    XCTAssertTrue(document.contains("tasks(scope: { folderId: $fid }, status: Active)"))
    let variablesJSON = try String(contentsOf: fake.variablesLogURL)
    XCTAssertTrue(variablesJSON.contains("\"fid\":\"FOLDER-1\""))
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
    let fake = try FakeWrikeGateway(mode: "tasks-success", requestId: "req-empty")
    defer { fake.cleanup() }

    let output = try await runWrike(
      name: "riela/wrike-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
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
    let fake = try FakeWrikeGateway(mode: "tasks-success", requestId: "req-env")
    defer { fake.cleanup() }

    _ = try await runWrike(
      name: "riela/wrike-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "queryTemplate": .string("{ account { id } }")
      ],
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

    let childEnvironment = try String(contentsOf: fake.environmentLogURL)
    XCTAssertTrue(childEnvironment.contains("WRIKE_GATEWAY_ACCESS_TOKEN=sentinel-token"))
    XCTAssertTrue(childEnvironment.contains("WRIKE_GATEWAY_API_BASE_URL=https://www.wrike.com/api/v4"))
    XCTAssertFalse(childEnvironment.contains("sentinel-openai"))
  }

  func testEnvironmentBindingRejectsNonWrikeTargetNames() async throws {
    let fake = try FakeWrikeGateway(mode: "tasks-success", requestId: "req-bad-env")
    defer { fake.cleanup() }

    try await assertWrikeFailure(
      name: "riela/wrike-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "queryTemplate": .string("{ account { id } }")
      ],
      env: ["LD_PRELOAD": .object(["fromEnv": .string("RIELA_WRIKE_ACCESS_TOKEN")])],
      environment: ["RIELA_WRIKE_ACCESS_TOKEN": "sentinel-token"],
      code: .policyBlocked,
      messageContains: "addon.env target 'LD_PRELOAD'"
    )
  }

  func testEnvironmentBindingRequiresConfiguredSourceValue() async throws {
    let fake = try FakeWrikeGateway(mode: "tasks-success", requestId: "req-missing-env")
    defer { fake.cleanup() }

    try await assertWrikeFailure(
      name: "riela/wrike-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "queryTemplate": .string("{ account { id } }")
      ],
      env: ["WRIKE_GATEWAY_ACCESS_TOKEN": .object(["fromEnv": .string("RIELA_WRIKE_ACCESS_TOKEN")])],
      code: .policyBlocked,
      messageContains: "RIELA_WRIKE_ACCESS_TOKEN"
    )
  }

  func testWriteAndAdminResolveTierSpecificExecutablesFromPath() async throws {
    let writerFake = try FakeWrikeGateway(mode: "update-success", requestId: "req-write", executableName: "wrike-gateway-writer")
    let adminFake = try FakeWrikeGateway(mode: "delete-success", requestId: "req-admin", executableName: "wrike-gateway-admin")
    defer {
      writerFake.cleanup()
      adminFake.cleanup()
    }

    let writeOutput = try await runWrike(
      name: "riela/wrike-gateway-write",
      config: ["queryTemplate": .string("mutation { updateTask(input: { taskId: \"TASK-1\" }) { task { id } } }")],
      environment: ["PATH": writerFake.binURL.path]
    )
    XCTAssertEqual(wrikeBinaryPath(writeOutput), writerFake.executableURL.path)
    XCTAssertEqual(writeOutput.payload["requestId"], .string("req-write"))

    let adminOutput = try await runWrike(
      name: "riela/wrike-gateway-admin",
      config: ["queryTemplate": .string("mutation { deleteTask(input: { taskId: \"TASK-1\" }) { deletedId } }")],
      environment: ["PATH": adminFake.binURL.path]
    )
    XCTAssertEqual(wrikeBinaryPath(adminOutput), adminFake.executableURL.path)
    XCTAssertEqual(adminOutput.payload["requestId"], .string("req-admin"))
  }

  func testGraphQLErrorEnvelopeFailsWithStableCode() async throws {
    let fake = try FakeWrikeGateway(mode: "graphql-error", requestId: "req-error")
    defer { fake.cleanup() }

    try await assertWrikeFailure(
      name: "riela/wrike-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "queryTemplate": .string("{ account { id } }")
      ],
      code: .providerError,
      messageContains: "CAPABILITY_DENIED"
    )
  }

  func testNonzeroExitWithoutJSONReportsExitCode() async throws {
    let fake = try FakeWrikeGateway(mode: "nonzero-plain", requestId: "req-exit")
    defer { fake.cleanup() }

    try await assertWrikeFailure(
      name: "riela/wrike-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "queryTemplate": .string("{ account { id } }")
      ],
      code: .providerError,
      messageContains: "exit code 3"
    )
  }

  func testMissingQueryTemplateIsRejected() async throws {
    try await assertWrikeFailure(
      name: "riela/wrike-gateway-read",
      config: [:],
      code: .policyBlocked,
      messageContains: "config.queryTemplate is required"
    )
  }

  func testSelectFirstOperatorsAndLastPosition() async throws {
    let fake = try FakeWrikeGateway(mode: "comments-success", requestId: "req-ops")
    defer { fake.cleanup() }

    let output = try await runWrike(
      name: "riela/wrike-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
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
    let fake = try FakeWrikeGateway(mode: "tasks-success", requestId: "req-now")
    defer { fake.cleanup() }

    _ = try await runWrike(
      name: "riela/wrike-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "queryTemplate": .string("query T($r: InstantRangeInput) { tasks(updatedDate: $r) { nodes { id } } }"),
        "nowVariables": .object(["since": .integer(-900)]),
        "variablesTemplate": .object(["r": .object(["start": .string("{{since}}")])])
      ]
    )

    let variablesJSON = try String(contentsOf: fake.variablesLogURL)
    XCTAssertTrue(
      variablesJSON.range(of: #""start":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z""#, options: .regularExpression) != nil,
      variablesJSON
    )
  }

  func testPayloadExtrasCarryRenderedValues() async throws {
    let fake = try FakeWrikeGateway(mode: "tasks-success", requestId: "req-extras")
    defer { fake.cleanup() }

    let output = try await runWrike(
      name: "riela/wrike-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
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
    name: String,
    config: JSONObject = [:],
    addonInputs: JSONObject = [:],
    env: JSONObject? = nil,
    environment: [String: String] = [:],
    variables: JSONObject = [:],
    resolvedInputPayload: JSONObject = [:],
    context: AdapterExecutionContext = AdapterExecutionContext()
  ) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(environment: environment).execute(
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

  private func wrikeBinaryPath(_ output: AdapterExecutionOutput) -> String? {
    guard case let .object(gateway)? = output.payload["wrikeGateway"],
          case let .object(binary)? = gateway["binary"],
          case let .string(path)? = binary["path"] else {
      return nil
    }
    return path
  }
}

private struct FakeWrikeGateway {
  var rootURL: URL
  var binURL: URL
  var executableURL: URL
  var queryLogURL: URL
  var variablesLogURL: URL
  var environmentLogURL: URL

  init(mode: String, requestId: String, executableName: String = "fake-wrike-gateway") throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-wrike-gateway-addon-\(UUID().uuidString)", isDirectory: true)
    binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
    executableURL = binURL.appendingPathComponent(executableName)
    queryLogURL = rootURL.appendingPathComponent("query.graphql")
    variablesLogURL = rootURL.appendingPathComponent("variables.json")
    environmentLogURL = rootURL.appendingPathComponent("environment.log")
    try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
    try script(mode: mode, requestId: requestId).write(to: executableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: rootURL)
  }

  private func script(mode: String, requestId: String) -> String {
    """
    #!/bin/sh
    printf "%s" "$3" > "\(queryLogURL.path)"
    if [ "$4" = "--variables" ]; then
      printf "%s" "$5" > "\(variablesLogURL.path)"
    fi
    {
      printf "WRIKE_GATEWAY_ACCESS_TOKEN=%s\\n" "${WRIKE_GATEWAY_ACCESS_TOKEN:-}"
      printf "WRIKE_GATEWAY_API_BASE_URL=%s\\n" "${WRIKE_GATEWAY_API_BASE_URL:-}"
      printf "OPENAI_API_KEY=%s\\n" "${OPENAI_API_KEY:-}"
    } > "\(environmentLogURL.path)"
    case "\(mode)" in
      tasks-success)
        /bin/cat <<'JSON'
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
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
        ;;
      comments-success)
        /bin/cat <<'JSON'
    {
      "data": {
        "comments": [
          {"id": "COMMENT-1", "authorId": "USER-1", "text": "<a rel=\\"KUAYWWKI\\">@Bot</a> first question"},
          {"id": "COMMENT-2", "authorId": "BOT-1", "text": "answer text [re:COMMENT-1] <a rel=\\"KUAYWWKI\\">@Bot</a>"},
          {"id": "COMMENT-3", "authorId": "USER-2", "text": "<a rel=\\"KUAYWWKI\\">@Bot</a> newest question"},
          {"id": "COMMENT-4", "authorId": "BOT-1", "text": "<a rel=\\"KUAYWWKI\\">@Bot</a> self note"}
        ]
      },
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
        ;;
      update-success)
        printf '{"data":{"updateTask":{"task":{"id":"TASK-1"}}},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      delete-success)
        printf '{"data":{"deleteTask":{"deletedId":"TASK-1"}},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      graphql-error)
        printf '{"errors":[{"message":"delete is not available in this tier","extensions":{"code":"CAPABILITY_DENIED"}}]}\\n'
        exit 4
        ;;
      nonzero-plain)
        echo "credential store unavailable" >&2
        exit 3
        ;;
    esac
    """
  }
}

private func wrikeTestObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object)? = value else {
    return nil
  }
  return object
}
