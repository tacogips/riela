import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

final class CommandResultTests: XCTestCase {
  func testActualCommandCarriesLiteralArgsReturnsNonzeroAsDataAndDropsPrivateFields() async throws {
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_COMMAND_LOCKS": "PRIVATE STALE CAPABILITY"])
    let schema: JSONObject = ["type": .string("object"), "properties": .object([
      "status": .object(["type": .string("string"), "enum": .array([.string("partial")])]),
      "accepted": .object(["type": .string("integer"), "minimum": .integer(0), "maximum": .integer(100)])]),
      "additionalProperties": .bool(false), "required": .array([.string("status")])]
    let config: JSONObject = ["executable": .string("/bin/sh"),
      "arguments": .string("{{args}}"), "stdoutSchema": .object(schema), "context": .object(["job": .string("fixture")])]
    let script = #"test "$1" = '{{literal}}' || exit 9; test -z "$RIELA_COMMAND_LOCKS" || exit 8; printf '{"status":"partial","accepted":2,"private":"PRIVATE BODY","unknown":1}'; printf PRIVATE_ERROR >&2; exit 3"#
    let input = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "run", nodeId: "run", addon: .init(name: "riela/command-result", version: "1", config: config),
      variables: ["args": .array(["-c", script, "fixture", "{{literal}}"].map(JSONValue.string))])
    let result = try await resolver.execute(input, context: .init())
    XCTAssertEqual(result.payload["exit_code"], .integer(3))
    guard case let .string(stdout)? = result.payload["stdout"] else { return XCTFail("stdout") }
    let value = try JSONDecoder().decode(JSONObject.self, from: Data(stdout.utf8))
    XCTAssertEqual(value, ["status": .string("partial"), "accepted": .integer(2)])
    XCTAssertFalse(String(data: try JSONEncoder().encode(result.payload), encoding: .utf8)!.contains("PRIVATE"))
  }

  func testBoundedOverflowMissingExecutableAndMalformedJSONAreFinite() async throws {
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    func execute(_ config: JSONObject) async throws -> JSONObject {
      try await resolver.execute(.init(workflowId: "fixture", stepId: "run", nodeId: "run",
        addon: .init(name: "riela/command-result", version: "1", config: config)), context: .init()).payload
    }
    let missing = try await execute(["executable": .string("/nonexistent-private-fixture")])
    XCTAssertEqual(missing["status"], .string("unavailable")); XCTAssertNil(missing["stdout"])
    let overflow = try await execute(["executable": .string("/bin/sh"), "arguments": .array(["-c", "printf PRIVATE_LONG_BODY"].map(JSONValue.string)), "maximumStdoutBytes": .integer(3)])
    XCTAssertEqual(overflow["status"], .string("invalid_summary")); XCTAssertNil(overflow["stdout"])
    let invalid = try await execute(["executable": .string("/bin/sh"), "arguments": .array(["-c", "printf PRIVATE_NON_JSON"].map(JSONValue.string)),
      "stdoutSchema": .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])])
    XCTAssertEqual(invalid["status"], .string("invalid_summary")); XCTAssertNil(invalid["stdout"])
  }

  func testProjectionOmitsInvalidOptionalMetadataAndRefusesRequiredOrNestedPrivateData() throws {
    let schema: JSONObject = ["type": .string("object"), "properties": .object([
      "count": .object(["type": .string("integer"), "minimum": .integer(0), "maximum": .integer(4)]),
      "proof": .object(["type": .string("object"), "properties": .object(["verified": .object(["type": .string("boolean")])]),
        "required": .array([.string("verified")]), "additionalProperties": .bool(false)])]), "additionalProperties": .bool(false)]
    XCTAssertEqual(try CommandResultProjection.project(.object(["count": .bool(true), "private": .string("PRIVATE"),
      "proof": .object(["verified": .bool(true), "private": .string("PRIVATE")])]), schema: schema), .object(["proof": .object(["verified": .bool(true)])]))
  }
  func testProjectionRefusesUntypedOrCompositePropertiesRatherThanLeakingNestedData() throws {
    let privateData: JSONValue = .object(["secret": .string("PRIVATE")])
    for child: JSONObject in [[:], ["enum": .array([privateData])],
      ["type": .array([.string("object"), .string("null")])],
      ["anyOf": .array([.object(["type": .string("object")])])]] {
      let schema: JSONObject = ["type": .string("object"), "properties": .object(["metadata": .object(child)])]
      XCTAssertEqual(try CommandResultProjection.project(.object(["metadata": privateData]), schema: schema), .object([:]))
      var required = schema; required["required"] = .array([.string("metadata")])
      XCTAssertNil(try CommandResultProjection.project(.object(["metadata": privateData]), schema: required))
    }
  }

}
