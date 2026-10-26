import RielaCore
import RielaAddons
import XCTest
@testable import RielaCLI

final class DataAddonTests: XCTestCase {
  func testWholeInputRelayOmitsRuntimeHistoryBeforeApplyingOutputLimit() async throws {
    let nested: JSONValue = .object(["upstream": .string("authored"), "runtime": .integer(7),
      "_rielaInput": .string("{{opaque}}")])
    let business: JSONObject = ["article": nested, "ready": .bool(true)]
    var input = business
    input["upstream"] = .array([.string(String(repeating: "x", count: 8_100_000))])
    input["runtime"] = .object(["sessionId": .string("current")])
    input["_rielaInput"] = .object(["latest": .object(["payload": .object(business)])])
    for template in ["{{input}}", " \n{{ input }}\n"] {
      let output = try await run("riela/json-compose", config: ["payload": .string(template)], input: input)
      XCTAssertEqual(output.payload, business)
    }
  }

  func testExplicitHistoryProjectionRemainsAvailable() async throws {
    let value: JSONObject = ["upstream": .array([.integer(1)]), "runtime": .object(["id": .string("current")])]
    let output = try await run("riela/json-compose", config: ["payload": .object([
      "upstream": .string("{{input.upstream}}"), "runtime": .string("{{input.runtime}}")])], input: value)
    XCTAssertEqual(output.payload, value)
  }

  func testRepeatedWholeInputRelaysKeepBusinessPayloadConstant() async throws {
    let business: JSONObject = ["body": .string(String(repeating: "article", count: 1000)),
      "nested": .object(["upstream": .string("user data")])]
    var value = business
    for _ in 0..<16 {
      value["upstream"] = .array([.object(["payload": .object(value), "output": .object(value)])])
      value["_rielaInput"] = .object(["latest": .object(["payload": .object(business)])])
      let output = try await run("riela/json-compose", config: ["payload": .string("{{input}}")], input: value)
      XCTAssertEqual(output.payload, business)
      guard output.payload == business else { return }
      value = output.payload
    }
  }

  func testEmbeddedWholeInputRelaysDoNotRecursivelyRetainHistory() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("whole-input-relay")
    defer { try? FileManager.default.removeItem(at: root) }
    let definitions = root.appendingPathComponent("definitions/relay")
    try FileManager.default.createDirectory(at: definitions, withIntermediateDirectories: true)
    let business: JSONObject = ["body": .string(String(repeating: "a", count: 16384) + "\u{2028}\u{2029}"),
      "nested": .object(["upstream": .string("authored")])]
    let ids = ["seed"] + (0..<18).map { "relay-\($0)" }
    let steps: [JSONValue] = ids.enumerated().map { index, id in
      var value: JSONObject = ["id": .string(id), "nodeId": .string(index == 0 ? "seed" : "relay")]
      if index + 1 < ids.count { value["transitions"] = .array([.object(["toStepId": .string(ids[index + 1])])]) }
      return .object(value)
    }
    let nodes: [JSONValue] = [("seed", JSONValue.object(business)), ("relay", .string("{{input}}"))].map { id, payload in
      .object(["id": .string(id), "addon": .object(["name": .string("riela/json-compose"),
        "version": .string("1"), "config": .object(["payload": payload])])])
    }
    try JSONEncoder().encode(["workflowId": JSONValue.string("relay"), "description": .string("Whole-input relay regression"),
      "defaults": .object(["nodeTimeoutMs": .integer(30000), "maxLoopIterations": .integer(1)]),
      "entryStepId": .string("seed"), "nodes": .array(nodes), "steps": .array(steps)]).write(to: definitions.appendingPathComponent("workflow.json"))
    let schema: JSONObject = ["type": .string("object"), "required": .array([.string("body"), .string("nested")]),
      "properties": .object(["body": .object(["type": .string("string")]), "nested": .object(["type": .string("object")])]),
      "additionalProperties": .bool(false)]
    let plan = try PrivateWorkflowPlan(config: ["workflowId": .string("relay"),
      "definitionRoot": .string(definitions.deletingLastPathComponent().path), "outputSchema": .object(schema)])
    let guest = root.appendingPathComponent("guest")
    let result = try await PrivateWorkflowWorker.executeWorkflow(.init(plan: plan,
      deadline: Date().addingTimeInterval(30), environment: [:], credentials: []), root: guest)
    XCTAssertEqual(result.payload, business)
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory:
      canonicalRuntimeStoreRoot(sessionStoreRoot: guest.appendingPathComponent("sessions").path))
    let snapshot = try XCTUnwrap(store.loadAll().first)
    XCTAssertEqual(snapshot.session.executions.count, ids.count)
    for execution in snapshot.session.executions {
      XCTAssertEqual(execution.acceptedOutput?.payload, business, execution.stepId)
    }
  }

  func testComposePreservesTypesAndDoesNotEvaluateDataAsTemplates() async throws {
    let value: JSONObject = ["nested": .array([.integer(2), .null, .bool(false)]),
                             "text": .string("{{secret}}")]
    let output = try await run("riela/json-compose", config: [
      "payload": .object(["copied": .string("{{input.value}}"), "kind": .string("plan")])
    ], input: ["value": .object(value), "secret": .string("must-not-expand")])
    XCTAssertEqual(output.payload, ["copied": .object(value), "kind": .string("plan")])
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/json-compose", version: "1"))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/array-batch", version: "1"))
  }

  func testComposeUsesUpstreamInputsAndEnforcesSchema() async throws {
    let config: JSONObject = ["payload": .object(["topics": .string("{{topics}}")]),
      "jsonSchema": .object(["type": .string("object"), "required": .array([.string("topics")]),
        "properties": .object(["topics": .object(["type": .string("array"), "minItems": .integer(1)])])])]
    let output = try await run("riela/json-compose", config: config,
      input: ["topics": .array([.object(["id": .string("one")])])])
    XCTAssertNotNil(output.payload["topics"])
    do {
      _ = try await run("riela/json-compose", config: config, input: ["topics": .array([])])
      XCTFail("empty input must be rejected")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidOutput) }
  }

  func testContractSchemaStaysLiteralAndUnsupportedSchemaIsAnInputError() async throws {
    // The schema mentions a template; rendering it would turn the enum into
    // ["rendered"] and reject the literal value carried in the data.
    let schema: JSONObject = ["type": .string("object"), "required": .array([.string("tag")]),
      "properties": .object(["tag": .object(["type": .string("string"), "enum": .array([.string("{{marker}}")])])])]
    let output = try await run("riela/json-compose", config: [
      "payload": .object(["tag": .string("{{tag}}")]), "jsonSchema": .object(schema)
    ], input: ["tag": .string("{{marker}}"), "marker": .string("rendered")])
    XCTAssertEqual(output.payload, ["tag": .string("{{marker}}")])
    for unsupported: JSONValue in [.object(["type": .string("string")]), .object(["if": .object([:])]), .string("{{schema}}")] {
      do {
        _ = try await run("riela/array-batch", config: ["items": .array([]), "jsonSchema": unsupported],
          input: ["schema": .object(schema)])
        XCTFail("unsupported contract schema accepted")
      } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput) }
    }
  }

  func testBatchFlushesShortFinalBatchAndPreservesInputOrder() async throws {
    let rows = (0..<5).map { JSONValue.object(["id": .string(String($0))]) }
    let output = try await run("riela/array-batch", config: [
      "items": .array(rows), "size": .integer(2), "maxItems": .integer(8), "uniqueBy": .string("id")])
    XCTAssertEqual(output.payload["items"], .array([.array(Array(rows[0..<2])), .array(Array(rows[2..<4])), .array([rows[4]])]))
    XCTAssertEqual(output.payload["itemCount"], .integer(5))
    let empty = try await run("riela/array-batch", config: ["items": .array([]), "size": .integer(2)])
    XCTAssertEqual(empty.payload["items"], .array([]))
  }

  func testBatchCarriesOneTypedContextEvenWhenNoItemsExist() async throws {
    let context: JSONValue = .object(["version": .integer(2), "text": .string("{{opaque}}")])
    for count in [0, 3] {
      let output = try await run("riela/array-batch", config: [
        "items": .array((0..<count).map { .integer(Int64($0)) }), "size": .integer(2),
        "context": .string("{{input.context}}")], input: ["context": context])
      XCTAssertEqual(output.payload["context"], context)
      XCTAssertEqual(output.payload["batchCount"], .integer(count == 0 ? 0 : 2))
    }
  }

  func testBatchByteLimitSplitsUnicodeRecordsWithoutWaitingOrDroppingItems() async throws {
    let records = (0..<3).map { JSONValue.object(["id": .string(String($0)), "body": .string(String(repeating: "😀", count: 30))]) }
    let output = try await run("riela/array-batch", config: ["items": .array(records), "size": .integer(15), "maxBatchBytes": .integer(300)])
    guard case let .array(batches)? = output.payload["items"] else { return XCTFail("missing batches") }
    var restored: [JSONValue] = []
    for batch in batches {
      XCTAssertLessThanOrEqual(try JSONEncoder().encode(batch).count, 300)
      guard case let .array(rows) = batch else { return XCTFail("invalid batch") }
      restored += rows
    }
    XCTAssertEqual(restored, records)
    XCTAssertEqual(batches.count, 2)
    do {
      _ = try await run("riela/array-batch", config: ["items": .array(records), "maxBatchBytes": .integer(10)])
      XCTFail("oversized individual item accepted")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput) }
  }

  func testBatchRejectsInvalidBoundsIdentitiesAndUnknownFields() async throws {
    let bad: [JSONObject] = [
      ["items": .array([]), "size": .integer(0)],
      ["items": .array([]), "size": .number(1.5)],
      ["items": .array([]), "minItems": .integer(1)],
      ["items": .array([.string("a"), .string("b")]), "maxItems": .integer(1)],
      ["items": .array([.object(["id": .string("a")]), .object(["id": .string("a")])]), "uniqueBy": .string("id")],
      ["items": .array([.object([:])]), "uniqueBy": .string("id")],
      ["items": .array([]), "script": .string("unexpected")]
    ]
    for config in bad {
      do {
        _ = try await run("riela/array-batch", config: config)
        XCTFail("invalid batch accepted")
      } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput) }
    }
  }

  private func run(_ name: String, config: JSONObject, input: JSONObject = [:]) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(environment: [:]).execute(
      WorkflowAddonExecutionInput(workflowId: "data-test", stepId: "compose", nodeId: "compose",
        addon: .init(name: name, version: "1", config: config), resolvedInputPayload: input),
      context: .init(deadline: Date().addingTimeInterval(30)))
  }
}
