import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class XGatewayJSONDocumentGoldenTests: XCTestCase {
  func testSDKQueryOperationCatalogGolden() throws {
    let names = try XCTUnwrap(XGatewayOperationCatalog.queryOperationNames)
    XCTAssertEqual(names.count, 82)
    XCTAssertTrue(names.isSuperset(of: ["homeTimeline", "searchPosts", "accountMe"]))
  }

  func testQueryOperationScannerFailsClosedAtItsBounds() {
    XCTAssertNil(XGatewayOperationCatalog.parseQueryOperationNames(String(repeating: "x", count: 2_097_153)))
    let tooManyFields = "type Query {\n" + (0...1_024).map { "  field\($0): String\n" }.joined() + "}\n"
    XCTAssertNil(XGatewayOperationCatalog.parseQueryOperationNames(tooManyFields))
  }

  func testHomeTimelineFieldPathDocumentGolden() throws {
    XCTAssertEqual(try document([
      "operation": .string("homeTimeline"),
      "arguments": .object(["maxResults": .integer(25), "paginationToken": .null]),
      "selection": .array([.string("posts.id"), .string("posts.author.username"), .string("pageInfo.nextToken")])
    ]), "query { homeTimeline(maxResults: 25, paginationToken: null) { pageInfo { nextToken } posts { author { username } id } } }")
  }

  func testNestedSelectGoldenMatchesFieldPathDocument() throws {
    let selection = ["operation": JSONValue.string("homeTimeline"),
                     "arguments": .object(["maxResults": .integer(25), "paginationToken": .null]),
                     "selection": .array([.string("posts.id"), .string("posts.author.username"), .string("pageInfo.nextToken")])]
    let select = ["operation": JSONValue.string("homeTimeline"),
                  "arguments": .object(["maxResults": .integer(25), "paginationToken": .null]),
                  "select": .object(["posts": .object(["id": .bool(true), "author": .object(["username": .bool(true)])]),
                                     "pageInfo": .object(["nextToken": .bool(true)])])]
    let expected = "query { homeTimeline(maxResults: 25, paginationToken: null) { pageInfo { nextToken } posts { author { username } id } } }"
    XCTAssertEqual(try document(select), expected)
    XCTAssertEqual(try document(selection), expected)
  }

  func testQuotedNewlineAndTemplateLikeArgumentGolden() throws {
    let value = "quoted \" text\n{{c}}"
    let input = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/x-gateway-reader", config: [
        "operation": .string("homeTimeline"),
        "arguments": .object(["userId": .string("{{input.value}}")]),
        "selection": .array([.string("posts.id")])
      ]), resolvedInputPayload: ["value": .string(value)])
    XCTAssertEqual(try builtinGatewayXJSONDocument(input),
                   "query { homeTimeline(userId: \"quoted \\\" text\\n{{c}}\") { posts { id } } }")
  }

  func testNestedObjectAndArrayArgumentGolden() throws {
    XCTAssertEqual(try document([
      "operation": .string("homeTimeline"),
      "arguments": .object(["custom": .object(["enabled": .bool(true), "values": .array([.integer(1), .string("x")])])]),
      "selection": .array([.string("posts.id")])
    ]), "query { homeTimeline(custom: {enabled: true, values: [1, \"x\"]}) { posts { id } } }")
  }

  func testIntegralDecimalArgumentGolden() throws {
    XCTAssertEqual(try document([
      "operation": .string("homeTimeline"),
      "arguments": .object(["maxResults": .number(25.0)]),
      "selection": .array([.string("posts.id")])
    ]), "query { homeTimeline(maxResults: 25) { posts { id } } }")
  }

  private func document(_ config: JSONObject) throws -> String? {
    try builtinGatewayXJSONDocument(.init(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/x-gateway-reader", config: config)))
  }
}
