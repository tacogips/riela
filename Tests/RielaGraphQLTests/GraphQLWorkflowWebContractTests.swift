import Foundation
import RielaCore
import XCTest
@testable import RielaGraphQL

final class GraphQLWorkflowWebContractTests: XCTestCase {
  func testWebListAndDetailSelectionsReachProvider() async {
    let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: StubWorkflowRegistryProvider())
    for query in [
      "query { workflows { workflows { workflowId definitionRevision } errors { code } } }",
      "query { workflow(target: { workflowId: \"alpha\" }) { workflow { definition definitionRevision } errors { code } } }"
    ] {
      let response = await executor.execute(GraphQLDocumentRequest(query: query, isLocallyTrusted: true))
      XCTAssertNil(response.body["errors"], "\(response.body)")
      XCTAssertNotNil(response.body["data"])
    }
  }

  func testWebMutationInputsReachProvider() async {
    let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: StubWorkflowRegistryProvider())
    let target: JSONValue = .object(["workflowId": .string("alpha")])
    let definition: JSONValue = .object(["workflowId": .string("alpha")])
    let cases: [(field: String, details: (type: String, input: JSONObject))] = [
      ("registerMutableWorkflow", ("RegisterMutableWorkflowInput", ["definition": definition])),
      ("updateMutableWorkflow", ("UpdateMutableWorkflowInput", [
        "target": target, "definition": definition, "expectedDefinitionRevision": .string("revision")
      ])),
      ("deleteMutableWorkflow", ("DeleteMutableWorkflowInput", [
        "target": target, "expectedDefinitionRevision": .string("revision")
      ])),
      ("deactivateWorkflow", ("SetWorkflowActivationInput", [
        "target": target, "expectedDefinitionRevision": .string("revision"), "expectedActivationState": .string("ACTIVE")
      ]))
    ]
    for (field, details) in cases {
      let (type, input) = details
      let response = await executor.execute(GraphQLDocumentRequest(
        query: "mutation($input: \(type)!) { \(field)(input: $input) { accepted workflow { definitionRevision } errors { code } } }",
        variables: ["input": .object(input)], isLocallyTrusted: true
      ))
      XCTAssertNil(response.body["errors"], "\(field): \(response.body)")
      guard case let .object(data)? = response.body["data"],
            case let .object(payload)? = data[field] else {
        XCTFail("\(field): missing mutation payload"); continue
      }
      XCTAssertEqual(payload["accepted"], .bool(true), "\(field): \(response.body)")
    }
  }

  func testAmbiguousInputAndUnknownFieldsStillFailBeforeDispatch() async {
    let executor = WorkflowRegistryGraphQLDocumentExecutor(localProvider: StubWorkflowRegistryProvider())
    for input: JSONObject in [
      ["definition": .object([:]), "bundle": .object(["kind": .string("LOCAL_PATH"), "value": .string("/unused")])],
      ["definition": .object([:]), "unexpected": .bool(true)],
      ["definition": .array([])]
    ] {
      let response = await executor.execute(GraphQLDocumentRequest(
        query: "mutation($input: RegisterMutableWorkflowInput!) { registerMutableWorkflow(input: $input) { accepted } }",
        variables: ["input": .object(input)], isLocallyTrusted: true
      ))
      XCTAssertNotNil(response.body["errors"])
      XCTAssertEqual(response.body["data"], .null)
    }
  }
}
