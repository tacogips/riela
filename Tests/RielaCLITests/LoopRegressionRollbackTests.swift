import Foundation
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class LoopRegressionRollbackTests: XCTestCase {
  func testStoreModeRegressionPoliciesAndEligibility() throws {
    for (policy, fileTarget) in [(WorkflowRegressionRollbackPolicy.manual, false), (.approvalRequired, false),
                                 (.automatic, false), (.manual, true)] {
      let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("tmp/workflow-history-unification/whu-08-rollback-service/store-policy-\(UUID().uuidString)")
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
      try CLIRuntimeEnvironment.$overrides.withValue(["HOME": home.path]) {
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
        try saveSession("target", version: improved, outcome: "failed", file: fileTarget)
        try runtime.setLoopBaseline(.init(workflowId: "flow", sessionId: "baseline", setAt: date))
        let service = WorkflowRegressionRollbackService(workingDirectory: root.path, sessionStore: storeRoot.path, scope: .user)
        let checked = try service.check(workflowName: "flow", targetSessionId: "target", actor: .init(kind: .user))
        let proposal = try XCTUnwrap(checked.proposal)
        XCTAssertEqual(checked.outcome, .proposed)
        XCTAssertEqual(proposal.mode, .store)
        XCTAssertEqual(proposal.regressedVersionId, improved.versionId)
        XCTAssertEqual(proposal.policy, policy)
        XCTAssertEqual(proposal.status, policy == .manual ? .recorded : policy == .automatic ? .applied : .pending)
        XCTAssertEqual(try service.check(workflowName: "flow", targetSessionId: "target", actor: .init(kind: .user)).outcome, .existing)
        if policy == .manual {
          XCTAssertThrowsError(try service.approve(workflowName: "flow", proposalId: proposal.proposalId,
            reason: nil, actor: .init(kind: .user))) {
            XCTAssertEqual(($0 as? WorkflowRegressionRollbackError)?.code, "rollback_proposal_not_pending")
          }
        } else {
          let applied = policy == .automatic ? proposal : try service.approve(workflowName: "flow", proposalId: proposal.proposalId,
            reason: "approved", actor: .init(kind: .user))
          let rollback = try XCTUnwrap(store.version(versionId: try XCTUnwrap(applied.appliedVersionId)))
          XCTAssertEqual(rollback.documentDigest, initial.version.documentDigest)
          XCTAssertEqual(rollback.operation, .rollback)
          if policy == .automatic { XCTAssertEqual(rollback.actor.kind, .system) }
          XCTAssertEqual(try store.head(workflowName: "flow")?.lastFileVersionId, initial.head.lastFileVersionId)
          let audit = try XCTUnwrap(store.audit(forVersionId: rollback.versionId))
          XCTAssertTrue(audit.evidence.contains(.init(kind: .session, id: "target")))
          try saveSession("after-rollback", version: rollback, outcome: "failed")
          let after = try service.check(workflowName: "flow", targetSessionId: "after-rollback", actor: .init(kind: .user))
          XCTAssertEqual(after.outcome, .notEligible)
          XCTAssertEqual(after.eligibilityCode, "notImprovementVersion")
        }
      }
    }
  }

  func testPolicyUsesRollbackTargetAndHookCreatesProposal() throws {
    for policy in [WorkflowRegressionRollbackPolicy.manual, .approvalRequired] {
      let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("tmp/workflow-history-unification/whu-08-rollback-service/policy-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let home = root.appendingPathComponent("home")
      let input = root.appendingPathComponent("flow")
      let storeRoot = root.appendingPathComponent("store")
      try FileManager.default.createDirectory(at: input.appendingPathComponent("nodes"), withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: input.appendingPathComponent("prompts"), withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      let authored = #"""
        {"workflowId":"flow","defaults":{"maxLoopIterations":3,"nodeTimeoutMs":120000},"entryStepId":"first",
        "nodeRegistry":[{"id":"worker","nodeFile":"nodes/worker.json"}],"steps":[{"id":"first","nodeId":"worker","role":"worker"}],
        "nodes":[{"id":"worker","nodeFile":"nodes/worker.json"}],"loop":{"regressionRollback":{"policy":"\#(policy.rawValue)"}}}
        """#
      try authored.write(to: input.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
      try #"{"id":"worker","executionBackend":"codex-agent","agentSandbox":"workspace-write","model":"model","promptTemplateFile":"prompts/p.md","variables":{}}"#
        .write(to: input.appendingPathComponent("nodes/worker.json"), atomically: true, encoding: .utf8)
      try "original".write(to: input.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
      try CLIRuntimeEnvironment.$overrides.withValue(["HOME": home.path]) {
        let resolver = FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false)
        let registration = WorkflowRegistryService(definitionStoreRoot: storeRoot.path, workingDirectory: root.path,
          definitionActor: .init(kind: .cli), surfaceLabel: "test", fileResolver: resolver)
        _ = try registration.register(input: input, overwrite: false, workingDirectory: root.path)
        let store = WorkflowDefinitionStore(rootDirectory: storeRoot.path)
        let initial = try XCTUnwrap(store.current(workflowName: "flow"))
        let recorder = WorkflowDefinitionChangeRecorder(sessionStoreRoot: storeRoot.path,
          workingDirectory: root.path, fileResolver: resolver)
        let registry = WorkflowMutableRegistry(definitionRecorder: recorder)
        let digest = try registry.withWorkflowPinnedAccess(workflowId: "flow") { pinned in
          try registry.bundleDigest(at: registry.root.appendingPathComponent("flow"), pinned: XCTUnwrap(pinned))
        }
        let attribution = WorkflowDefinitionChangeAttribution(operation: .selfImprove, actor: .init(kind: .cli), reason: "improve")
        _ = try registry.withWorkflowMutationAccess(workflowId: "flow", expectedDigest: digest, attribution: attribution) { workspace, publish in
          let changed = authored.replacingOccurrences(of: policy.rawValue, with: "automatic")
          try changed.write(to: workspace.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
          try "improved".write(to: workspace.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
          try publish(workspace)
        }
        let improved = try XCTUnwrap(store.current(workflowName: "flow"))
        let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot.path))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func saveSession(_ id: String, version: WorkflowDefinitionVersion, outcome: String) throws -> (WorkflowSession, LoopEvidenceManifest) {
          let pin = WorkflowDefinitionSource(kind: .store, workflowName: "flow", versionId: version.versionId,
            storeRoot: storeRoot.path, digest: version.documentDigest, sourcePath: version.sourceDirectory, sourceScope: "user")
          let session = WorkflowSession(workflowId: "flow", sessionId: id, status: .completed, entryStepId: "first",
            createdAt: date, updatedAt: date, definitionSource: pin)
          try CLIWorkflowSessionStore(rootDirectory: storeRoot.path).save(.init(workflowName: "flow", session: session,
            resolution: .init(workflowName: "flow", scope: .user, workingDirectory: root.path)))
          let evidence = LoopEvidenceManifest(schemaVersion: 1, manifestId: "loop-evidence-\(id)", workflowId: "flow",
            sessionId: id, workflowSource: .init(scope: "user", kind: "workflow-directory", mutable: true), policy: .init(),
            commands: [.init(id: "verify", argvSummary: "verify", argvRedactionStatus: "clean")],
            verification: [.init(id: "v", commandRef: "verify", outcome: outcome)],
            redaction: .init(policyName: "summary-only", status: "clean"), createdAt: date, updatedAt: date)
          var snapshot = try runtime.load(sessionId: id)
          snapshot.loopEvidence = evidence
          try runtime.save(snapshot)
          return (session, evidence)
        }
        _ = try saveSession("baseline", version: initial.version, outcome: "passed")
        let (target, evidence) = try saveSession("target", version: improved.version, outcome: "failed")
        try runtime.setLoopBaseline(.init(workflowId: "flow", sessionId: "baseline", setAt: date))
        let bundle = try resolver.resolve(.init(workflowName: "flow", scope: .user, workingDirectory: root.path))
        let result = WorkflowRunResult(workflowId: "flow", session: target, rootOutput: nil, exitCode: 0, transitions: 0)
        var options = WorkflowRunOptions(target: "flow", sessionStore: storeRoot.path, workingDirectory: root.path)
        options.executionMode = .service(.init(kind: .system))
        WorkflowRunCommand().evaluateRegressionRollbackAfterTerminalPersistence(finalResult: result, loopEvidence: evidence,
          bundle: bundle, options: options, storeRoot: storeRoot.path)
        let proposals = try WorkflowRollbackProposalStore(rootDirectory: storeRoot.path).list(workflowName: "flow", status: nil, limit: 10)
        let proposal = try XCTUnwrap(proposals.first)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposal.policy, policy)
        XCTAssertEqual(proposal.status, policy == .manual ? .recorded : .pending)
        XCTAssertEqual(try store.head(workflowName: "flow")?.currentVersionId, improved.version.versionId)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.exitCode, 0)
      }
    }
  }

  func testPostRunHookIsServiceOnlyAndRecordsEvaluationFailure() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/workflow-history-unification/whu-08-rollback-service/hook-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    var session = WorkflowSession(workflowId: "flow", sessionId: "target", status: .completed,
      entryStepId: "first", createdAt: date, updatedAt: date)
    try CLIWorkflowSessionStore(rootDirectory: root.path).save(.init(workflowName: "flow", session: session,
      resolution: .init(workflowName: "flow", workingDirectory: root.path)))
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
    try runtime.setLoopBaseline(.init(workflowId: "flow", sessionId: "missing-baseline", setAt: date))
    session.definitionSource = .init(kind: .store, workflowName: "flow", versionId: "version",
      storeRoot: root.path, digest: "digest", sourceScope: "project")
    let result = WorkflowRunResult(workflowId: "flow", session: session, rootOutput: nil, exitCode: 0, transitions: 0)
    let workflow = WorkflowDefinition(workflowId: "flow", defaults: .init(nodeTimeoutMs: 1000, maxLoopIterations: 1),
      entryStepId: "first", nodeRegistry: [], steps: [], nodes: [],
      loop: .init(regressionRollback: .init(policy: .approvalRequired)))
    let bundle = ResolvedWorkflowBundle(workflow: workflow, nodePayloads: [:], sourceScope: .project, workflowDirectory: root.path)
    let evidence = LoopEvidenceManifest(schemaVersion: 1, manifestId: "evidence-target", workflowId: "flow",
      sessionId: "target", workflowSource: .init(scope: "project", kind: "workflow-directory", mutable: false),
      policy: .init(), redaction: .init(policyName: "summary-only", status: "clean"), createdAt: date, updatedAt: date)
    var options = WorkflowRunOptions(target: "flow", sessionStore: root.path, workingDirectory: root.path)
    let command = WorkflowRunCommand()
    command.evaluateRegressionRollbackAfterTerminalPersistence(finalResult: result, loopEvidence: evidence,
      bundle: bundle, options: options, storeRoot: root.path)
    XCTAssertTrue(try runtime.load(sessionId: "target").diagnostics.isEmpty)
    options.executionMode = .service(.init(kind: .system))
    command.evaluateRegressionRollbackAfterTerminalPersistence(finalResult: result, loopEvidence: evidence,
      bundle: bundle, options: options, storeRoot: root.path)
    let snapshot = try runtime.load(sessionId: "target")
    XCTAssertTrue(snapshot.diagnostics.contains { $0.hasPrefix("regression rollback evaluation failed:") })
    XCTAssertEqual(snapshot.session.status, .completed)
    XCTAssertEqual(result.exitCode, 0)
  }

  func testCheckWithoutBaselineReturnsNoBaseline() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/workflow-history-unification/whu-08-rollback-service/no-baseline-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = WorkflowRegressionRollbackService(workingDirectory: root.path, sessionStore: root.path)
    let result = try service.check(workflowName: "flow", targetSessionId: nil, actor: .init(kind: .system))
    XCTAssertEqual(result.outcome, .noBaseline)
    XCTAssertNil(result.proposal)
  }
}
