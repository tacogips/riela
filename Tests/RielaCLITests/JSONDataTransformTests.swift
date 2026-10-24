import RielaAddonSupport
import RielaCore
import RielaAddons
import XCTest
@testable import RielaCLI

final class JSONDataTransformTests: XCTestCase {
  func testPipelineFiltersMapsDefaultsAndDeduplicatesWithoutReevaluatingData() async throws {
    let rows: JSONValue = .array([
      .object(["id": .string("1"), "keep": .bool(true), "a/b": .string("{{secret}}")]),
      .object(["id": .string("1"), "keep": .bool(true)]),
      .object(["id": .string("2"), "keep": .bool(false)]),
      .object(["id": .string("3"), "keep": .bool(true)])])
    let steps: JSONValue = .array([
      .object(["filter": .object(["path": .string("/keep"), "equals": .bool(true)])]),
      .object(["unique": .string("/id")]),
      .object(["map": .object(["id": .string("/id"), "text": .object([
        "path": .string("/a~1b"), "default": .string("missing")]),
        "opinion": .object(["literal": .bool(true)])])]),
      .object(["take": .integer(10)])])
    let output = try await BuiltinWorkflowAddonResolver(environment: [:]).execute(
      .init(workflowId: "fixture", stepId: "transform", nodeId: "transform",
        addon: .init(name: "riela/json-transform", version: "1",
          config: ["input": .string("{{input.rows}}"), "steps": steps]),
        variables: ["secret": .string("must-not-expand")], resolvedInputPayload: ["rows": rows]), context: .init())
    XCTAssertEqual(output.payload["value"], .array([
      .object(["id": .string("1"), "text": .string("{{secret}}"), "opinion": .bool(true)]),
      .object(["id": .string("3"), "text": .string("missing"), "opinion": .bool(true)])]))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/json-transform", version: "1"))
  }

  func testSizeLimitIsTheSharedEightMiBBoundAndStandaloneInputIsChecked() throws {
    XCTAssertEqual(GatewayJSONLimits.maximumEncodedBytes, 8 * 1_024 * 1_024)
    // 8,100,000 bytes exceeds the former 8,000,000-byte limit but fits 8 MiB.
    let fits: JSONValue = .string(String(repeating: "a", count: 8_100_000))
    XCTAssertEqual(try JSONDataTransform.run(fits, steps: .array([.object(["pick": .string("")])])), fits)
    let large: JSONValue = .object([
      "big": .string(String(repeating: "b", count: GatewayJSONLimits.maximumEncodedBytes)), "small": .integer(1)
    ])
    let program = try JSONDataTransform.compile(.array([.object(["pick": .string("/small")])]))
    // `riela/json-transform` input is a workflow boundary and stays checked.
    XCTAssertThrowsError(try program.run(large))
    // Runtime-owned inputs bound the picked value instead of the whole input.
    XCTAssertEqual(try program.run(large, checkInputSize: false), .integer(1))
    XCTAssertThrowsError(try JSONDataTransform.compile(.array([])).run(large, checkInputSize: false))
  }

  func testRejectsExpressionsMalformedPointersAndInvalidEmptyArrayOperations() throws {
    let bad: [JSONValue] = [
      .object(["pick": .string(".posts[] | exec")]),
      .object(["pick": .string("/missing/~2")]),
      .object(["filter": .object(["path": .string("/id"), "script": .string("true")])]),
      .object(["map": .object(["id": .object(["script": .string("true")])])]),
      .object(["sort": .string("/id")]), .object(["take": .integer(-1)])]
    for step in bad {
      XCTAssertThrowsError(try JSONDataTransform.run(.array([]), steps: .array([step])))
    }
    XCTAssertThrowsError(try JSONDataTransform.run(.null,
      steps: .array(Array(repeating: .object(["pick": .string("")]), count: 33))))
    XCTAssertEqual(try JSONDataTransform.run(.array([]), steps: .array([
      .object(["map": .object(["id": .string("/id")])])])), .array([]))
  }
}

extension JSONDataTransformTests {
  func testProjectionBudgetCountsEmptyObjectsRatherThanOnlySelectedFields() throws {
    let values = Dictionary(uniqueKeysWithValues: (0..<1000).map { ("item-\($0)", JSONValue.object([:])) })
    let field: JSONValue = .object(["from": .string("/groups"), "mapValues": .object([:])])
    let fields = Dictionary(uniqueKeysWithValues: (0..<128).map { ("copy-\($0)", field) })
    XCTAssertThrowsError(try JSONDataProjection(.object(fields)).run(.object(["groups": .object(values)])))
  }

  func testNestedMetadataProjectionMapsNamedObjectsAndPreservesLiteralStrings() throws {
    let plan: JSONValue = .object(["project": .object([
      "groups": .object(["from": .string("/groups"), "mapValues": .object([
        "label": .string("/name"), "hasProofs": .object(["nonEmpty": .string("/proofs")]),
        "detail": .object(["from": .string("/detail"), "fields": .object(["status": .string("/status")])])])]),
      "missing": .string("/missing")])])
    let value: JSONValue = .object(["groups": .object([
      "one": .object(["name": .string("{{literal}}"), "proofs": .array([.string("PRIVATE")]), "private": .string("PRIVATE")]),
      "two": .object(["name": .string("日本語"), "proofs": .array([]), "detail": .null])]), "history": .string("PRIVATE")])
    XCTAssertEqual(try JSONDataTransform.run(value, steps: .array([plan])), .object(["groups": .object([
      "one": .object(["label": .string("{{literal}}"), "hasProofs": .bool(true)]),
      "two": .object(["label": .string("日本語"), "hasProofs": .bool(false), "detail": .null])])]))
    for invalid: JSONValue in [.object(["field": .object(["script": .string("true")])]),
      .object(["field": .object(["from": .string("/x"), "fields": .object([:]), "mapValues": .object([:])])]),
      .object(["field": .string("/bad/~3")])] {
      XCTAssertThrowsError(try JSONDataTransform.compile(.array([.object(["project": invalid])])))
    }
    XCTAssertThrowsError(try JSONDataProjection(.object(["proof": .object(["nonEmpty": .string("/proof")])])).run(.object(["proof": .integer(1)])))
  }
}
