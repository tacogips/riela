import RielaCore
import XCTest
@testable import RielaCLI

final class KeyValueStoreAddonTests: XCTestCase {
  func testSetThenGetRoundTripsTypedJSONValueAcrossExecutions() async throws {
    let kvRoot = temporaryDirectory()

    let setOutput = try await runKeyValueAddon(
      name: "riela/kv-set",
      kvRoot: kvRoot,
      config: [
        "key": .string("lastFetched"),
        "value": .object([
          "sinceId": .string("190001"),
          "fetchedAt": .string("2026-08-19T09:00:00Z")
        ])
      ]
    )
    XCTAssertEqual(setOutput.payload["status"], .string("ok"))
    XCTAssertEqual(setOutput.payload["saved"], .bool(true))
    XCTAssertEqual(setOutput.payload["operation"], .string("set"))
    XCTAssertEqual(setOutput.payload["scope"], .string("x-digest-workflow"))

    let getOutput = try await runKeyValueAddon(
      name: "riela/kv-get",
      kvRoot: kvRoot,
      config: ["key": .string("lastFetched")]
    )
    XCTAssertEqual(getOutput.payload["found"], .bool(true))
    XCTAssertEqual(
      getOutput.payload["value"],
      .object([
        "sinceId": .string("190001"),
        "fetchedAt": .string("2026-08-19T09:00:00Z")
      ])
    )
  }

  func testGetMissingKeyReturnsDefaultAndFoundFalse() async throws {
    let kvRoot = temporaryDirectory()

    let output = try await runKeyValueAddon(
      name: "riela/kv-get",
      kvRoot: kvRoot,
      config: [
        "key": .string("lastFetched"),
        "default": .object(["sinceId": .null])
      ]
    )

    XCTAssertEqual(output.payload["found"], .bool(false))
    XCTAssertEqual(output.payload["value"], .object(["sinceId": .null]))
    XCTAssertNil(output.payload["entry"])
  }

  func testScopeDefaultsToWorkflowIdSoWorkflowsDoNotCollide() async throws {
    let kvRoot = temporaryDirectory()

    _ = try await runKeyValueAddon(
      name: "riela/kv-set",
      kvRoot: kvRoot,
      config: ["key": .string("token"), "value": .string("wf-a-token")],
      workflowId: "workflow-a"
    )

    let otherWorkflow = try await runKeyValueAddon(
      name: "riela/kv-get",
      kvRoot: kvRoot,
      config: ["key": .string("token")],
      workflowId: "workflow-b"
    )
    XCTAssertEqual(otherWorkflow.payload["found"], .bool(false))

    let sharedScope = try await runKeyValueAddon(
      name: "riela/kv-get",
      kvRoot: kvRoot,
      config: ["key": .string("token"), "scope": .string("workflow-a")],
      workflowId: "workflow-b"
    )
    XCTAssertEqual(sharedScope.payload["found"], .bool(true))
    XCTAssertEqual(sharedScope.payload["value"], .string("wf-a-token"))
  }

  func testSetValueFromRenderedInputsTemplate() async throws {
    let kvRoot = temporaryDirectory()

    let setOutput = try await runKeyValueAddon(
      name: "riela/kv-set",
      kvRoot: kvRoot,
      config: ["key": .string("cursor")],
      inputs: ["value": .string("{{inbox.latest.output.payload.nextToken}}")],
      resolvedInputPayload: [
        "_rielaInput": .object([
          "latest": .object([
            "payload": .object(["nextToken": .object(["page": .integer(3)])])
          ])
        ])
      ]
    )

    XCTAssertEqual(setOutput.payload["value"], .object(["page": .integer(3)]))
  }

  func testDeleteRemovesKeyAndReportsMissing() async throws {
    let kvRoot = temporaryDirectory()

    _ = try await runKeyValueAddon(
      name: "riela/kv-set",
      kvRoot: kvRoot,
      config: ["key": .string("token"), "value": .string("t")]
    )

    let deleted = try await runKeyValueAddon(
      name: "riela/kv-delete",
      kvRoot: kvRoot,
      config: ["key": .string("token")]
    )
    XCTAssertEqual(deleted.payload["deleted"], .bool(true))

    let deletedAgain = try await runKeyValueAddon(
      name: "riela/kv-delete",
      kvRoot: kvRoot,
      config: ["key": .string("token")]
    )
    XCTAssertEqual(deletedAgain.payload["deleted"], .bool(false))

    let get = try await runKeyValueAddon(
      name: "riela/kv-get",
      kvRoot: kvRoot,
      config: ["key": .string("token")]
    )
    XCTAssertEqual(get.payload["found"], .bool(false))
    XCTAssertEqual(get.payload["value"], .null)
  }

  func testListReturnsScopedKeysWithPrefixFilter() async throws {
    let kvRoot = temporaryDirectory()

    for (key, value) in [("cursor/x", "1"), ("cursor/mail", "2"), ("config", "3")] {
      _ = try await runKeyValueAddon(
        name: "riela/kv-set",
        kvRoot: kvRoot,
        config: ["key": .string(key), "value": .string(value)]
      )
    }

    let output = try await runKeyValueAddon(
      name: "riela/kv-list",
      kvRoot: kvRoot,
      config: ["keyPrefix": .string("cursor/")]
    )

    XCTAssertEqual(output.payload["keys"], .array([.string("cursor/mail"), .string("cursor/x")]))
    XCTAssertEqual(output.payload["count"], .number(2))
  }

  func testMissingKeyAndMissingValueAreRejected() async throws {
    let kvRoot = temporaryDirectory()

    await assertPolicyBlocked(
      name: "riela/kv-get",
      kvRoot: kvRoot,
      config: [:],
      messagePart: "kv key is required"
    )
    await assertPolicyBlocked(
      name: "riela/kv-set",
      kvRoot: kvRoot,
      config: ["key": .string("k")],
      messagePart: "kv value is required"
    )
  }

  func testUnsupportedVersionIsRejected() async throws {
    do {
      _ = try await runKeyValueAddon(
        name: "riela/kv-get",
        kvRoot: temporaryDirectory(),
        config: ["key": .string("k")],
        version: "2"
      )
      XCTFail("expected unsupported version to be rejected")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("unsupported riela/kv-get version '2'"))
    }
  }

  private func assertPolicyBlocked(
    name: String,
    kvRoot: URL,
    config: JSONObject,
    messagePart: String
  ) async {
    do {
      _ = try await runKeyValueAddon(name: name, kvRoot: kvRoot, config: config)
      XCTFail("expected \(name) to be rejected")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains(messagePart), "unexpected message: \(error.message)")
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  private func runKeyValueAddon(
    name: String,
    kvRoot: URL,
    config: JSONObject,
    inputs: JSONObject = [:],
    resolvedInputPayload: JSONObject = [:],
    workflowId: String = "x-digest-workflow",
    version: String? = "1"
  ) async throws -> AdapterExecutionOutput {
    var mergedConfig = config
    mergedConfig["kvRoot"] = .string(kvRoot.path)
    return try await BuiltinWorkflowAddonResolver(environment: [:]).execute(
      WorkflowAddonExecutionInput(
        workflowId: workflowId,
        stepId: "kv-step",
        nodeId: "kv-node",
        addon: WorkflowNodeAddonRef(
          name: name,
          version: version,
          config: mergedConfig,
          inputs: inputs
        ),
        resolvedInputPayload: resolvedInputPayload
      ),
      context: AdapterExecutionContext()
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-kv-addon-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }
}
