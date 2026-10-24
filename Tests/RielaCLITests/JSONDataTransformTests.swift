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
