import Foundation
import XCTest
import RielaCore
@testable import RielaGraphQL

final class WorkflowHistoryGraphQLContractTests: XCTestCase {
  func testSevenOperationsDispatchArgumentsAndReturnPinnedKeys() async {
    let provider = HistoryProvider()
    let cases: [(String, (String, String))] = [
      ("{ workflowVersions(workflowName: \"w\", scope: \"s\", limit: 3, beforeSnapshotId: \"b\") { workflowId nextBeforeSnapshotId } }", ("versions:w:s:3:b", "workflowVersions")),
      ("{ workflowVersionDiff(workflowName: \"w\", scope: \"s\", from: \"a\", to: \"b\", includeContent: true) { workflowId from to } }", ("diff:w:s:a:b:true", "workflowVersionDiff")),
      ("{ workflowRollbackProposals(workflowName: \"w\", storeScope: \"s\", status: \"pending\", limit: 3) { proposalId } }", ("proposals:w:s:pending:3", "workflowRollbackProposals")),
      ("mutation { restoreWorkflowVersion(input: {workflowName: \"w\", snapshotId: \"v\"}) { dryRun definitionWarnings } }", ("restore:w:v:false", "restoreWorkflowVersion")),
      ("mutation { checkWorkflowRegressionRollback(input: {workflowName: \"w\", storeScope: \"s\", targetSessionId: \"t\"}) { outcome diagnostics } }", ("check:w:s:t", "checkWorkflowRegressionRollback")),
      ("mutation { approveWorkflowRollbackProposal(input: {workflowName: \"w\", proposalId: \"p\", reason: \"r\"}) { proposalId } }", ("approve:w:p:r", "approveWorkflowRollbackProposal")),
      ("mutation { rejectWorkflowRollbackProposal(input: {workflowName: \"w\", proposalId: \"p\", reason: \"r\"}) { proposalId } }", ("reject:w:p:r", "rejectWorkflowRollbackProposal"))
    ]
    for (document, (expected, field)) in cases {
      let response = await execute(document, provider: provider)
      XCTAssertNil(response.body["errors"], document)
      guard case let .object(data)? = response.body["data"] else { XCTFail(document); continue }
      XCTAssertNotNil(data[field], document)
      let observed = await provider.lastCall
      XCTAssertEqual(observed, expected, document)
      if field == "restoreWorkflowVersion", case let .object(payload)? = data[field] {
        XCTAssertEqual(payload["dryRun"], .bool(true))
        XCTAssertEqual(payload["definitionWarnings"], .array([.string("warning")]))
      }
    }
  }

  func testUnimplementedOperationsReturnUnsupported() async {
    let documents = [
      "{ workflowVersions(workflowName: \"w\") { workflowId } }",
      "{ workflowVersionDiff(workflowName: \"w\", from: \"a\", to: \"b\") { workflowId } }",
      "{ workflowRollbackProposals(workflowName: \"w\") { proposalId } }",
      "mutation { restoreWorkflowVersion(input: {workflowName: \"w\", snapshotId: \"v\"}) { dryRun } }",
      "mutation { checkWorkflowRegressionRollback(input: {workflowName: \"w\"}) { outcome } }",
      "mutation { approveWorkflowRollbackProposal(input: {workflowName: \"w\", proposalId: \"p\"}) { proposalId } }",
      "mutation { rejectWorkflowRollbackProposal(input: {workflowName: \"w\", proposalId: \"p\", reason: \"r\"}) { proposalId } }"
    ]
    for document in documents {
      let response = await execute(document, provider: DefaultHistoryProvider())
      guard case let .array(errors)? = response.body["errors"], case let .object(error)? = errors.first,
            case let .object(extensions)? = error["extensions"] else { XCTFail(document); continue }
      XCTAssertEqual(extensions["code"], .string("DEFINITION_OPERATION_UNSUPPORTED"), document)
    }
  }

  func testSchemaSignaturesAndVariableValidation() throws {
    let schema = GraphQLSchemaGenerator.render()
    let signatures = [
      "workflowVersions(workflowName: String!, scope: String, limit: Int, beforeSnapshotId: String): WorkflowVersionsPayload!",
      "workflowVersionDiff(workflowName: String!, scope: String, from: String!, to: String!, includeContent: Boolean): WorkflowVersionDiffPayload!",
      "workflowRollbackProposals(workflowName: String!, storeScope: String, status: String, limit: Int): [WorkflowRollbackProposal!]!",
      "restoreWorkflowVersion(input: RestoreWorkflowVersionInput!): RestoreWorkflowVersionPayload!",
      "checkWorkflowRegressionRollback(input: CheckWorkflowRegressionRollbackInput!): CheckWorkflowRegressionRollbackPayload!",
      "approveWorkflowRollbackProposal(input: ApproveWorkflowRollbackProposalInput!): WorkflowRollbackProposal!",
      "rejectWorkflowRollbackProposal(input: RejectWorkflowRollbackProposalInput!): WorkflowRollbackProposal!"
    ]
    for signature in signatures { XCTAssertTrue(schema.contains(signature), signature) }
    let query = "query($name: String!, $limit: Int) { workflowVersions(workflowName: $name, limit: $limit) { workflowId } }"
    let operations = try parseGraphQLOperations(in: query, operationName: nil,
      variables: ["name": .string("w"), "limit": .number(3)], parseArguments: true)
    let root = try XCTUnwrap(operations.first?.rootFields.first)
    XCTAssertNoThrow(try validateGraphQLVariableUsages(in: root))
    let invalid = "query($name: String!, $limit: String) { workflowVersions(workflowName: $name, limit: $limit) { workflowId } }"
    XCTAssertThrowsError(try parseGraphQLOperations(in: invalid, operationName: nil,
      variables: ["name": .string("w"), "limit": .string("3")], parseArguments: true))
  }

  private func execute(_ document: String, provider: any WorkflowDefinitionGraphQLProviding) async -> GraphQLDocumentExecutionResponse {
    await WorkflowDefinitionGraphQLDocumentExecutor(provider: provider).execute(GraphQLDocumentRequest(
      query: document, variables: [:], operationName: nil, environment: [:], isLocallyTrusted: true
    ))
  }
}

private class DefaultHistoryProvider: WorkflowDefinitionGraphQLProviding, @unchecked Sendable {
  func workflowDefinitionHistory(workflowName: String, nodeId: String?, limit: Int?, storeScope: String?) async throws -> [GraphQLWorkflowDefinitionAuditRecord] { [] }
  func workflowDefinition(workflowName: String, versionId: String?, storeScope: String?) async throws -> GraphQLWorkflowDefinitionVersion? { nil }
  func workflowDefinitionDiff(workflowName: String, fromVersionId: String?, toVersionId: String?, againstFile: Bool?, storeScope: String?) async throws -> [GraphQLWorkflowDefinitionDiffEntry] { [] }
  func updateWorkflowDefinition(input: UpdateWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionUpdatePayload { throw stubError() }
  func updateWorkflowDefinitionPrompt(input: UpdateWorkflowDefinitionPromptInput) async throws -> GraphQLWorkflowDefinitionMutationPayload { throw stubError() }
  func restoreWorkflowDefinition(input: RestoreWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionMutationPayload { throw stubError() }
  func importWorkflowDefinition(input: ImportWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionImportPayload { throw stubError() }
  func exportWorkflowDefinition(input: ExportWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionExportPayload { throw stubError() }
  private func stubError() -> WorkflowDefinitionGraphQLError { .init(code: "STUB", message: "unused") }
}

private actor HistoryProvider: WorkflowDefinitionGraphQLProviding {
  var lastCall = ""
  func workflowDefinitionHistory(workflowName: String, nodeId: String?, limit: Int?, storeScope: String?) async throws -> [GraphQLWorkflowDefinitionAuditRecord] { [] }
  func workflowDefinition(workflowName: String, versionId: String?, storeScope: String?) async throws -> GraphQLWorkflowDefinitionVersion? { nil }
  func workflowDefinitionDiff(workflowName: String, fromVersionId: String?, toVersionId: String?, againstFile: Bool?, storeScope: String?) async throws -> [GraphQLWorkflowDefinitionDiffEntry] { [] }
  func updateWorkflowDefinition(input: UpdateWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionUpdatePayload { throw stubError() }
  func updateWorkflowDefinitionPrompt(input: UpdateWorkflowDefinitionPromptInput) async throws -> GraphQLWorkflowDefinitionMutationPayload { throw stubError() }
  func restoreWorkflowDefinition(input: RestoreWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionMutationPayload { throw stubError() }
  func importWorkflowDefinition(input: ImportWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionImportPayload { throw stubError() }
  func exportWorkflowDefinition(input: ExportWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionExportPayload { throw stubError() }
  func workflowVersions(workflowName: String, scope: String?, limit: Int?, beforeSnapshotId: String?) async throws -> GraphQLWorkflowVersionsPayload {
    lastCall = "versions:\(workflowName):\(scope ?? "nil"):\(limit ?? 0):\(beforeSnapshotId ?? "nil")"
    return try decode(#"{"workflowId":"w","snapshots":[],"nextBeforeSnapshotId":"b"}"#)
  }
  func workflowVersionDiff(workflowName: String, scope: String?, from: String, to: String, includeContent: Bool?) async throws -> GraphQLWorkflowVersionDiffPayload {
    lastCall = "diff:\(workflowName):\(scope ?? "nil"):\(from):\(to):\(includeContent ?? false)"
    return try decode(#"{"workflowId":"w","from":"a","to":"b","differences":[]}"#)
  }
  func workflowRollbackProposals(workflowName: String, storeScope: String?, status: String?, limit: Int?) async throws -> [GraphQLWorkflowRollbackProposal] {
    lastCall = "proposals:\(workflowName):\(storeScope ?? "nil"):\(status ?? "nil"):\(limit ?? 0)"
    return []
  }
  func restoreWorkflowVersion(input: RestoreWorkflowVersionInput) async throws -> GraphQLRestoreWorkflowVersionPayload {
    lastCall = "restore:\(input.workflowName):\(input.snapshotId):\(input.apply ?? true)"
    return try decode(#"{"workflowId":"w","sourceSnapshotId":"v","dryRun":true,"restored":false,"# +
      #""beforeBundleDigest":"a","requestedBundleDigest":"b","restoredFiles":[],"dirtyConflicts":[],"definitionWarnings":["warning"]}"#)
  }
  func checkWorkflowRegressionRollback(input: CheckWorkflowRegressionRollbackInput) async throws -> GraphQLCheckWorkflowRegressionRollbackPayload {
    lastCall = "check:\(input.workflowName):\(input.storeScope ?? "nil"):\(input.targetSessionId ?? "nil")"
    return try decode(#"{"outcome":"recorded","regressions":[],"diagnostics":[]}"#)
  }
  func approveWorkflowRollbackProposal(input: ApproveWorkflowRollbackProposalInput) async throws -> GraphQLWorkflowRollbackProposal {
    lastCall = "approve:\(input.workflowName):\(input.proposalId):\(input.reason ?? "nil")"
    return try proposal()
  }
  func rejectWorkflowRollbackProposal(input: RejectWorkflowRollbackProposalInput) async throws -> GraphQLWorkflowRollbackProposal {
    lastCall = "reject:\(input.workflowName):\(input.proposalId):\(input.reason)"
    return try proposal()
  }
  private func proposal() throws -> GraphQLWorkflowRollbackProposal {
    try decode(#"{"proposalId":"p","workflowName":"w","regressedVersionId":"v2","rollbackToVersionId":"v1","# +
      #""mode":"service","baselineSessionId":"a","targetSessionId":"b","regressions":[],"policy":"manual","# +
      #""status":"recorded","diagnostics":[],"createdAt":"now","updatedAt":"now"}"#)
  }
  private func decode<T: Decodable>(_ json: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(json.utf8)) }
  private func stubError() -> WorkflowDefinitionGraphQLError { .init(code: "STUB", message: "unused") }
}
