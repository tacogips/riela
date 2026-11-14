import RielaCore
import RielaAddons
import XCTest
@testable import RielaCLI

final class DataAddonTests: XCTestCase {
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

  func testBatchFlushesShortFinalBatchAndPreservesInputOrder() async throws {
    let rows = (0..<5).map { JSONValue.object(["id": .string(String($0))]) }
    let output = try await run("riela/array-batch", config: [
      "items": .array(rows), "size": .integer(2), "maxItems": .integer(8), "uniqueBy": .string("id")])
    XCTAssertEqual(output.payload["items"], .array([.array(Array(rows[0..<2])), .array(Array(rows[2..<4])), .array([rows[4]])]))
    XCTAssertEqual(output.payload["itemCount"], .integer(5))
    let empty = try await run("riela/array-batch", config: ["items": .array([]), "size": .integer(2)])
    XCTAssertEqual(empty.payload["items"], .array([]))
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
