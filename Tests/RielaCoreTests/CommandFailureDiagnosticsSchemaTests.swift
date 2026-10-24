import XCTest
@testable import RielaCore

final class CommandFailureDiagnosticsSchemaTests: XCTestCase {
  private let schema: JSONObject = ["type": .string("object"), "additionalProperties": .bool(false),
    "required": .array([.string("status")]), "properties": .object([
      "status": .object(["type": .string("string"), "enum": .array([.string("failed")])]),
      "count": .object(["type": .string("integer"), "minimum": .integer(0), "maximum": .integer(100)]),
      "flags": .object(["type": .string("array"), "maxItems": .integer(4),
        "items": .object(["type": .string("boolean")])]),
      "none": .object(["type": .string("null")])
    ])]

  func testValidSchemaAndPolicyHaveNoDiagnostics() {
    XCTAssertEqual(WorkflowFailureDiagnostics.schemaDiagnostics(schema), [])
    let policy = WorkflowFailureDiagnostics(schema: schema, path: ["report"])
    XCTAssertEqual(policy.validationDiagnostics(), [])
    XCTAssertNotNil(policy.metadata(from: #"{"report":{"status":"failed","count":3,"flags":[true],"none":null}}"#))
  }

  func testInvalidSchemasAreReportedWithTheirLocation() {
    let cases: [(JSONObject, String)] = [
      (["type": .string("object")], "schema: object schema must have exactly the keys"),
      (["type": .string("string")], "schema: string schema must have exactly the keys enum, type"),
      (["type": .string("number")], "schema: unsupported type number"),
      (["type": .string("integer"), "minimum": .integer(0), "maximum": .integer(1_000_000_001)],
       "schema: minimum and maximum must satisfy"),
      (["type": .string("array"), "items": .object(["type": .string("boolean")]), "maxItems": .integer(257)],
       "schema: maxItems must be an integer between 0 and 256"),
      (["type": .string("object"), "additionalProperties": .bool(true), "required": .array([]),
        "properties": .object([:])], "schema: additionalProperties must be false"),
      (["type": .string("object"), "additionalProperties": .bool(false), "required": .array([.string("missing")]),
        "properties": .object([:])], "schema: required must list unique declared property names"),
      (["type": .string("object"), "additionalProperties": .bool(false), "required": .array([]),
        "properties": .object(["note": .object(["type": .string("string"), "enum": .array([.string("")])])])],
       "schema/properties/note: enum must list 1 to 64 non-empty strings")
    ]
    for (invalid, expected) in cases {
      let diagnostics = WorkflowFailureDiagnostics.schemaDiagnostics(invalid)
      XCTAssertTrue(diagnostics.contains { $0.hasPrefix(expected) }, "\(expected) not in \(diagnostics)")
    }
  }

  func testPolicyDiagnosticsCoverBoundsPathAndObjectRoot() {
    XCTAssertTrue(WorkflowFailureDiagnostics(schema: schema, maxBytes: 0).validationDiagnostics()
      .contains("maxBytes must be between 1 and 65536"))
    XCTAssertTrue(WorkflowFailureDiagnostics(schema: schema, path: Array(repeating: "k", count: 9)).validationDiagnostics()
      .contains("path must have at most 8 keys"))
    XCTAssertTrue(WorkflowFailureDiagnostics(schema: schema, path: ["ok", ""]).validationDiagnostics()
      .contains { $0.hasPrefix("path[1] must be") })
    XCTAssertTrue(WorkflowFailureDiagnostics(schema: ["type": .string("boolean")]).validationDiagnostics()
      .contains("schema: root type must be object"))
  }

  func testDeepNestingIsReported() {
    var nested: JSONObject = ["type": .string("boolean")]
    for _ in 0..<10 {
      nested = ["type": .string("array"), "maxItems": .integer(1), "items": .object(nested)]
    }
    XCTAssertTrue(WorkflowFailureDiagnostics.schemaDiagnostics(nested).contains { $0.hasSuffix("schema nesting exceeds 8 levels") })
  }
}
