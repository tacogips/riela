import Foundation
import RielaWorkflowRegistry
import RielaGraphQL
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class WorkflowRollbackCommandTests: XCTestCase {
  func testRollbackSurfaceCheckListAndApprove() async throws {
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
        let app = RielaCLIApplication()
        func command(_ values: [String]) -> [String] {
          ["workflow", "definition", "rollback"] + values + ["--scope", "user", "--session-store", storeRoot.path,
            "--working-dir", root.path, "--output", "json"]
        }
        let checked = await app.run(command(["check", "flow", "--session", "target"]))
        XCTAssertEqual(checked.exitCode, .success, checked.stderr)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(checked.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(object["outcome"] as? String, "proposed")
        let proposal = try XCTUnwrap(object["proposal"] as? [String: Any])
        let proposalId = try XCTUnwrap(proposal["proposalId"] as? String)
        let listed = await app.run(command(["list", "flow", "--status", "pending"]))
        XCTAssertEqual(listed.exitCode, .success, listed.stderr)
        XCTAssertTrue(listed.stdout.contains(proposalId))
        let rejected = await app.run(command(["reject", "flow", "--proposal", proposalId]))
        XCTAssertEqual(rejected.exitCode, .usage)
        let provider = WorkflowDefinitionGraphQLProvider(workingDirectory: root.path, sessionStoreRoot: storeRoot.path,
          environment: ["HOME": home.path])
        let graphList = try await provider.workflowRollbackProposals(workflowName: "flow", storeScope: "user", status: "pending", limit: 10)
        XCTAssertEqual(graphList.first?.proposalId, proposalId)
        do {
          _ = try await provider.approveWorkflowRollbackProposal(input: .init(workflowName: "flow", storeScope: "user",
            proposalId: proposalId, actorKind: "system"))
          XCTFail("system actor should be rejected")
        } catch let error as WorkflowDefinitionGraphQLError { XCTAssertEqual(error.code, "INVALID_DEFINITION_INPUT") }
        let approved = await app.run(command(["approve", "flow", "--proposal", proposalId, "--reason", "r"]))
        XCTAssertEqual(approved.exitCode, .success, approved.stderr)
        XCTAssertTrue(approved.stdout.contains("applied"))
        let audit = try XCTUnwrap(store.history(workflowName: "flow", limit: nil).first { $0.operation == .rollback })
        XCTAssertTrue(audit.reason.contains("approved: r"))
        let history = await app.run(["workflow", "definition", "history", "flow", "--scope", "user", "--session-store", storeRoot.path,
          "--working-dir", root.path, "--output", "json"])
        XCTAssertEqual(history.exitCode, .success)
        XCTAssertTrue(history.stdout.contains("approved: r"))
        XCTAssertTrue(history.stdout.contains("rollback"))
        let manual = WorkflowRollbackProposalDraft(workflowName: "flow", regressedVersionId: "manual-version",
          rollbackToVersionId: initial.version.versionId, mode: .store, baselineSessionId: "baseline", targetSessionId: "target",
          regressions: [], policy: .manual, status: .recorded, createdActor: .init(kind: .cli))
        let recorded = try WorkflowRollbackProposalStore(rootDirectory: storeRoot.path).insertIfAbsent(manual).proposal
        let manualApproval = await app.run(["workflow", "definition", "rollback", "approve", "flow", "--proposal", recorded.proposalId,
          "--scope", "user", "--session-store", storeRoot.path, "--working-dir", root.path])
        XCTAssertEqual(manualApproval.exitCode, .failure)
        XCTAssertTrue(manualApproval.stderr.hasPrefix("rollback_proposal_not_pending"))
      }
  }
}
