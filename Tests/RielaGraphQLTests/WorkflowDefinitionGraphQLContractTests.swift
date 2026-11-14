import Foundation
import XCTest
import RielaCore
@testable import RielaGraphQL

final class WorkflowDefinitionGraphQLContractTests: XCTestCase {
  func testExecutorRoutesAllDefinitionFields() async {
    let documents = [
      "{ workflowDefinitionHistory(workflowName: \"w\") { auditId } }",
      "{ workflowDefinition(workflowName: \"w\") { versionId } }",
      "{ workflowDefinitionDiff(workflowName: \"w\") { path } }",
      "mutation { updateWorkflowDefinition(input: {workflowName: \"w\", reason: \"r\", patchJSON: \"[]\"}) { outcome } }",
      "mutation { updateWorkflowDefinitionPrompt(input: {workflowName: \"w\", nodeId: \"n\", field: \"promptTemplate\", text: \"x\", reason: \"r\"}) { version { versionId } } }",
      "mutation { restoreWorkflowDefinition(input: {workflowName: \"w\", versionId: \"v\", reason: \"r\"}) { version { versionId } } }",
      "mutation { importWorkflowDefinition(input: {workflowName: \"w\"}) { outcome } }",
      "mutation { exportWorkflowDefinition(input: {workflowName: \"w\"}) { wroteToSource } }"
    ]
    for document in documents {
      let response = await WorkflowDefinitionGraphQLDocumentExecutor().execute(GraphQLDocumentRequest(
        query: document, variables: [:], operationName: nil, environment: [:], isLocallyTrusted: true
      ))
      XCTAssertTrue(response.handled, document)
      XCTAssertEqual(
        response.body["errors"].flatMap(errorCode),
        "DEFINITION_OPERATION_FAILED",
        document
      )
    }
  }

  func testMalformedInputIsRejectedAndSchemaPublishesDefinitionContracts() async {
    let response = await WorkflowDefinitionGraphQLDocumentExecutor(provider: nil).execute(GraphQLDocumentRequest(
      query: "{",
      variables: [:], operationName: nil, environment: [:], isLocallyTrusted: true
    ))
    XCTAssertTrue(response.handled)
    XCTAssertEqual(response.body["errors"].flatMap(errorCode), "INVALID_DEFINITION_INPUT")

    let schema = GraphQLContractProjector.schemaContract
    for field in ["workflowDefinitionHistory", "workflowDefinition(", "workflowDefinitionDiff", "updateWorkflowDefinition(",
                 "updateWorkflowDefinitionPrompt", "restoreWorkflowDefinition", "importWorkflowDefinition", "exportWorkflowDefinition"] {
      XCTAssertTrue(schema.contains(field), "missing schema field \(field)")
    }
    XCTAssertTrue(schema.contains("documentJSON: String!"))
  }

  private func errorCode(_ value: JSONValue) -> String? {
    guard case let .array(errors) = value,
          case let .object(error)? = errors.first,
          case let .object(extensions)? = error["extensions"],
          case let .string(code)? = extensions["code"] else { return nil }
    return code
  }
}
