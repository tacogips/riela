import Foundation
import RielaWorkflowRegistry
import RielaGraphQL
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class WorkflowRollbackGraphQLTests: XCTestCase {
  func testGraphQLRejectAndSupersededApproval() async throws {
    try await scenario(decision: "reject")
    try await scenario(decision: "supersede")
    try await scenario(decision: "approve")
  }

  private func scenario(decision: String) async throws {
    let policy = WorkflowRegressionRollbackPolicy.approvalRequired
      let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("tmp/workflow-history-unification/whu-10-rollback-surfaces/store-policy-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let home = root.appendingPathComponent("home")
      let input = root.appendingPathComponent("input")
      let storeRoot = root.appendingPathComponent("store")
      try FileManager.default.createDirectory(at: input.appendingPathComponent("nodes"), withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: input.appendingPathComponent("prompts"), withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      let workflow = #"""
        {"workflowId":"flow","defaults":{"maxLoopIterations":3,"nodeTimeoutMs":120000},"entryStepId":"first",
        "nodeRegistry":[{"id":"worker","nodeFile":"nodes/worker.json"}],"steps":[{"id":"first","nodeId":"worker","role":"worker"}],
        "nodes":[{"id":"worker","nodeFile":"nodes/worker.json"}],"loop":{"regressionRollback":{"policy":"\#(policy.rawValue)"}}}
        """#
      try workflow.write(to: input.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
      try #"{"id":"worker","executionBackend":"codex-agent","agentSandbox":"workspace-write","model":"model","promptTemplateFile":"prompts/p.md","variables":{}}"#
        .write(to: input.appendingPathComponent("nodes/worker.json"), atomically: true, encoding: .utf8)
      try "original".write(to: input.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
      try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": home.path]) {
        let resolver = FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false)
        let registration = WorkflowRegistryService(definitionStoreRoot: storeRoot.path, workingDirectory: root.path,
          definitionActor: .init(kind: .cli), surfaceLabel: "test", fileResolver: resolver)
        _ = try registration.register(input: input, overwrite: false, workingDirectory: root.path)
        let store = WorkflowDefinitionStore(rootDirectory: storeRoot.path)
        let initial = try XCTUnwrap(store.current(workflowName: "flow"))
        let definitions = WorkflowDefinitionService(storeRoot: storeRoot.path, fileResolver: resolver)
        let improved = try definitions.updatePrompt(workflowName: "flow", nodeId: "worker", field: .init(parsing: "promptTemplate"),
          text: "regressed", reason: "improvement", expectedVersionId: initial.version.versionId,
          evidence: [], actor: .init(kind: .improvementNode)).0
        let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot.path))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func saveSession(_ id: String, version: WorkflowDefinitionVersion, outcome: String, file: Bool = false) throws {
          let pin = WorkflowDefinitionSource(kind: file ? .file : .store, workflowName: "flow",
            versionId: file ? nil : version.versionId, storeRoot: file ? nil : storeRoot.path, digest: version.documentDigest, sourcePath: version.sourceDirectory, sourceScope: "user")
          let session = WorkflowSession(workflowId: "flow", sessionId: id, status: .completed, entryStepId: "first",
            createdAt: date, updatedAt: date, definitionSource: pin)
          try CLIWorkflowSessionStore(rootDirectory: storeRoot.path).save(.init(workflowName: "flow", session: session,
            resolution: .init(workflowName: "flow", scope: .user, workingDirectory: root.path)))
          var snapshot = try runtime.load(sessionId: id)
          snapshot.loopEvidence = .init(schemaVersion: 1, manifestId: "loop-evidence-\(id)", workflowId: "flow", sessionId: id,
            workflowSource: .init(scope: "user", kind: "workflow-directory", mutable: true), policy: .init(),
            commands: [.init(id: "verify", argvSummary: "verify", argvRedactionStatus: "clean")],
            verification: [.init(id: "v", commandRef: "verify", outcome: outcome)],
            redaction: .init(policyName: "summary-only", status: "clean"), createdAt: date, updatedAt: date)
          try runtime.save(snapshot)
        }
        try saveSession("baseline", version: initial.version, outcome: "passed")
        try saveSession("target", version: improved, outcome: "failed")
        try runtime.setLoopBaseline(.init(workflowId: "flow", sessionId: "baseline", setAt: date))
        let provider = WorkflowDefinitionGraphQLProvider(workingDirectory: root.path, sessionStoreRoot: storeRoot.path,
          environment: ["HOME": home.path])
        let executor = WorkflowDefinitionGraphQLDocumentExecutor(provider: provider)
        func execute(_ query: String) async -> GraphQLDocumentExecutionResponse {
          await executor.execute(GraphQLDocumentRequest(query: query, variables: [:], operationName: nil,
            environment: [:], isLocallyTrusted: true, localWorkingDirectory: root.path))
        }
        let checked = await execute("mutation { checkWorkflowRegressionRollback(input: {workflowName: \"flow\", storeScope: \"user\", targetSessionId: \"target\"}) { outcome proposal { proposalId status } } }")
        guard case let .object(data)? = checked.body["data"],
              case let .object(result)? = data["checkWorkflowRegressionRollback"],
              case let .string(outcome)? = result["outcome"],
              case let .object(proposal)? = result["proposal"],
              case let .string(proposalId)? = proposal["proposalId"] else { return XCTFail("invalid check: \(checked.body)") }
        XCTAssertEqual(outcome, "proposed")
        let listed = await execute("{ workflowRollbackProposals(workflowName: \"flow\", storeScope: \"user\", status: \"pending\") { proposalId } }")
        XCTAssertTrue(String(describing: listed.body).contains(proposalId))
        let invalidActor = await execute("mutation { approveWorkflowRollbackProposal(input: {workflowName: \"flow\", storeScope: \"user\", proposalId: \"\(proposalId)\", actorKind: \"system\"}) { status } }")
        XCTAssertTrue(String(describing: invalidActor.body).contains("INVALID_DEFINITION_INPUT"))
        if decision == "reject" {
          let response = await execute("mutation { rejectWorkflowRollbackProposal(input: {workflowName: \"flow\", storeScope: \"user\", proposalId: \"\(proposalId)\", reason: \"no\"}) { status } }")
          XCTAssertTrue(String(describing: response.body).contains("rejected"))
        } else if decision == "supersede" {
          _ = try definitions.updatePrompt(workflowName: "flow", nodeId: "worker", field: .init(parsing: "promptTemplate"),
            text: "new head", reason: "move", expectedVersionId: improved.versionId, evidence: [], actor: .init(kind: .cli))
          let response = await execute("mutation { approveWorkflowRollbackProposal(input: {workflowName: \"flow\", storeScope: \"user\", proposalId: \"\(proposalId)\"}) { status } }")
          XCTAssertTrue(String(describing: response.body).contains("ROLLBACK_SUPERSEDED"))
        } else {
          let response = await execute("mutation { approveWorkflowRollbackProposal(input: {workflowName: \"flow\", storeScope: \"user\", proposalId: \"\(proposalId)\"}) { status } }")
          XCTAssertTrue(String(describing: response.body).contains("applied"))
        }
      }
  }
}
