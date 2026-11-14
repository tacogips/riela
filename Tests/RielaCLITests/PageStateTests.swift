import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class PageStateTests: XCTestCase {
  func testQueriesResumeAndDeduplicateWithoutMixingTheirCursors() async throws {
    var result = try await run("riela/page-state", config: start)
    XCTAssertEqual(result.payload["request"], .object(["query": .string("one"), "cursor": .null]))
    result = try await accept(result, ids: ["a", "b"], cursor: "token", more: true)
    XCTAssertEqual(result.payload["request"], .object(["query": .string("one"), "cursor": .string("token")]))
    result = try await accept(result, ids: ["b", "c"], more: false)
    XCTAssertEqual(result.payload["request"], .object(["query": .string("two"), "cursor": .null]))
    result = try await accept(result, ids: ["a", "d"], more: false)
    XCTAssertEqual(result.payload["items"], .array(["a", "b", "c", "d"].map(JSONValue.string)))
    XCTAssertEqual(result.payload["request"], .null)
    XCTAssertEqual(result.when["done"], true)
  }

  func testRepeatedCursorAndCollectionLimitAreRejected() async throws {
    let initial = try await run("riela/page-state", config: start)
    let advanced = try await accept(initial, ids: ["a"], cursor: "token", more: true)
    do {
      _ = try await accept(advanced, ids: ["b"], cursor: "token", more: true)
      XCTFail("repeated cursor accepted")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidOutput) }
    var bounded = start; bounded["maxItems"] = .integer(1)
    let small = try await run("riela/page-state", config: bounded)
    do {
      _ = try await accept(small, ids: ["a", "b"], more: false)
      XCTFail("collection limit ignored")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput) }
  }

  func testScalarIdentityAndMissingTerminalCursorStayLiteral() async throws {
    let initial = try await run("riela/page-state", config: ["action": .string("start"),
      "queries": .array([.string("one")]), "identityPath": .string("")])
    let result = try await run("riela/page-state", config: ["action": .string("accept"),
      "state": .string("{{input.state}}"), "response": .string("{{input.page}}"),
      "context": .string("{{input.context}}")], values: ["state": try XCTUnwrap(initial.payload["state"]),
        "page": .object(["items": .array([.string("{{secret}}")])]),
        "context": .object(["text": .string("{{secret}}")])])
    XCTAssertEqual(result.payload["items"], .array([.string("{{secret}}")]))
    XCTAssertEqual(result.payload["context"], .object(["text": .string("{{secret}}")]))
    XCTAssertEqual(result.payload["complete"], .bool(true))
  }

  func testRouteEmitsExactlyTheDeclaredCaseAndRejectsUnknownData() async throws {
    let config: JSONObject = ["value": .string("{{input.stage}}"),
      "cases": .array([.string("profile"), .string("list")]), "payload": .object([:])]
    let result = try await run("riela/json-route", config: config, values: ["stage": .string("list")])
    XCTAssertEqual(result.when, ["list": true])
    do {
      _ = try await run("riela/json-route", config: config, values: ["stage": .string("other")])
      XCTFail("unknown route accepted")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput) }
    var envelope = config
    envelope["payload"] = .object(["when": .object(["other": .bool(true)]), "payload": .object([:])])
    do {
      _ = try await run("riela/json-route", config: envelope, values: ["stage": .string("list")])
      XCTFail("source envelope must not override the selected route")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput) }
  }

  private var start: JSONObject { ["action": .string("start"), "queries": .array([.string("one"), .string("two")]),
    "itemsPath": .string("/edges"), "identityPath": .string("/node/id"), "cursorPath": .string("/pageInfo/endCursor"),
    "hasMorePath": .string("/pageInfo/hasNextPage"), "identitySyntax": .string("identifier")] }

  private func accept(_ prior: AdapterExecutionOutput, ids: [String], cursor: String? = nil, more: Bool) async throws -> AdapterExecutionOutput {
    try await run("riela/page-state", config: ["action": .string("accept"), "state": .string("{{input.state}}"),
      "response": .string("{{input.page}}")], values: ["state": try XCTUnwrap(prior.payload["state"]), "page": .object([
        "edges": .array(ids.map { .object(["node": .object(["id": .string($0)])]) }),
        "pageInfo": .object(["hasNextPage": .bool(more), "endCursor": cursor.map(JSONValue.string) ?? .null])])])
  }

  private func run(_ name: String, config: JSONObject, values: JSONObject = [:]) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(environment: [:]).execute(.init(workflowId: "pages", stepId: "step", nodeId: "node",
      addon: .init(name: name, version: "1", config: config), resolvedInputPayload: values), context: .init())
  }
}
