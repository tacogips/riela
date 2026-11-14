import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore
@testable import RielaGraphQL
@testable import RielaWorkflowRegistry

final class WorkflowRegistryDefinitionSyncTests: XCTestCase {
  func testCreateUpdateOverwriteAndDelete() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let service = fixture.service
      let created = try service.register(input: fixture.input, overwrite: false, workingDirectory: fixture.root.path)
      XCTAssertTrue(created.warnings.isEmpty)
      let encoded = try JSONEncoder().encode(created)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      XCTAssertNil(object["warnings"])
      let initial = try XCTUnwrap(fixture.store.current(workflowName: "flow"))
      XCTAssertEqual(initial.version.provenance, WorkflowProvenance.mutable.rawValue)
      XCTAssertNil(initial.version.parentVersionId)
      let initialAudit = try XCTUnwrap(fixture.store.history(workflowName: "flow").first)
      XCTAssertEqual(initialAudit.operation, .registryWrite)
      XCTAssertTrue(initialAudit.evidence.contains { $0.kind == .bundleSnapshotAfter })
      let definition = WorkflowDefinitionService(storeRoot: fixture.storeRoot.path,
        fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
      let update = try definition.updatePrompt(workflowName: "flow", nodeId: "worker", field: .init(parsing: "promptTemplate"),
        text: "store only", reason: "edit", expectedVersionId: initial.version.versionId, evidence: [], actor: .init(kind: .user))
      try "file change".write(to: fixture.input.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
      let changed = try service.update(target: .init(workflowId: "flow", scope: .user), input: fixture.input,
        workingDirectory: fixture.root.path)
      XCTAssertTrue(changed.warnings.contains { $0.contains(update.1.auditId) })
      let head = try XCTUnwrap(fixture.store.current(workflowName: "flow"))
      XCTAssertEqual(head.version.parentVersionId, update.0.versionId)
      _ = try service.delete(target: .init(workflowId: "flow", scope: .user), workingDirectory: fixture.root.path)
      XCTAssertEqual(try fixture.store.head(workflowName: "flow")?.currentVersionId, head.version.versionId)
      let delete = try XCTUnwrap(fixture.store.history(workflowName: "flow").first)
      XCTAssertEqual(delete.operation, .registryDelete)
      XCTAssertTrue(delete.evidence.contains { $0.kind == .bundleSnapshotBefore })
    }
  }

  func testGeneratedTaskRegistrarRecordsDefinition() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path, "RIELA_SESSION_STORE": fixture.storeRoot.path]) {
      _ = try MutableGeneratedWorkflowTaskRegistrar().register(bundle: fixture.input, workingDirectory: fixture.root)
      let head = try XCTUnwrap(fixture.store.current(workflowName: "flow"))
      XCTAssertEqual(head.version.operation, .registryWrite)
      XCTAssertEqual(head.version.actor.kind, .improvementNode)
      XCTAssertEqual(try fixture.store.history(workflowName: "flow").count, 1)
    }
  }

  func testStoreRollbackAtomicallyAppliesProposal() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      _ = try fixture.service.register(input: fixture.input, overwrite: false, workingDirectory: fixture.root.path)
      let initial = try XCTUnwrap(fixture.store.current(workflowName: "flow"))
      let service = WorkflowDefinitionService(storeRoot: fixture.storeRoot.path,
        fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
      let update = try service.updatePrompt(workflowName: "flow", nodeId: "worker", field: .init(parsing: "promptTemplate"),
        text: "regression", reason: "improve", expectedVersionId: initial.version.versionId,
        evidence: [], actor: .init(kind: .improvementNode))
      let proposals = WorkflowRollbackProposalStore(rootDirectory: fixture.storeRoot.path)
      let proposal = try proposals.insertIfAbsent(.init(workflowName: "flow", regressedVersionId: update.0.versionId,
        rollbackToVersionId: initial.version.versionId, mode: .store, baselineSessionId: "base", targetSessionId: "target",
        regressions: [], policy: .approvalRequired, status: .pending, createdActor: .init(kind: .system))).proposal
      XCTAssertThrowsError(try service.rollback(workflowName: "flow", toVersionId: initial.version.versionId,
        expectedHeadVersionId: initial.version.versionId, proposalId: proposal.proposalId, reason: "rollback",
        evidence: [], actor: .init(kind: .user)))
      XCTAssertEqual(try proposals.proposal(id: proposal.proposalId)?.status, .pending)
      let evidence: [WorkflowDefinitionEvidenceRef] = [.init(kind: .rollbackProposal, id: proposal.proposalId)]
      let result = try service.rollback(workflowName: "flow", toVersionId: initial.version.versionId,
        expectedHeadVersionId: update.0.versionId, proposalId: proposal.proposalId, reason: "rollback",
        evidence: evidence, actor: .init(kind: .user))
      XCTAssertEqual(result.0.operation, .rollback)
      XCTAssertEqual(result.0.documentDigest, initial.version.documentDigest)
      XCTAssertEqual(result.1.evidence, evidence)
      XCTAssertFalse(result.1.diff.isEmpty)
      XCTAssertEqual(try proposals.proposal(id: proposal.proposalId)?.appliedVersionId, result.0.versionId)
      XCTAssertEqual(try fixture.store.head(workflowName: "flow")?.lastFileVersionId, initial.head.lastFileVersionId)
    }
  }

  func testRegressionServiceApprovesAndRejectsStoreProposals() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      _ = try fixture.service.register(input: fixture.input, overwrite: false, workingDirectory: fixture.root.path)
      let initial = try XCTUnwrap(fixture.store.current(workflowName: "flow"))
      let definition = WorkflowDefinitionService(storeRoot: fixture.storeRoot.path,
        fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
      let update = try definition.updatePrompt(workflowName: "flow", nodeId: "worker", field: .init(parsing: "promptTemplate"),
        text: "regressed", reason: "improve", expectedVersionId: initial.version.versionId,
        evidence: [], actor: .init(kind: .improvementNode))
      let proposals = WorkflowRollbackProposalStore(rootDirectory: fixture.storeRoot.path)
      let proposal = try proposals.insertIfAbsent(.init(workflowName: "flow", regressedVersionId: update.0.versionId,
        rollbackToVersionId: initial.version.versionId, mode: .store, baselineSessionId: "base", targetSessionId: "target",
        regressions: [.init(kind: "required-gate-downgrade", detail: "regressed")], policy: .approvalRequired,
        status: .pending, createdActor: .init(kind: .system))).proposal
      let service = WorkflowRegressionRollbackService(workingDirectory: fixture.root.path, sessionStore: fixture.storeRoot.path)
      XCTAssertThrowsError(try service.reject(workflowName: "flow", proposalId: proposal.proposalId, reason: " ", actor: .init(kind: .user)))
      let applied = try service.approve(workflowName: "flow", proposalId: proposal.proposalId, reason: "approved", actor: .init(kind: .user))
      XCTAssertEqual(applied.status, .applied)
      let audit = try XCTUnwrap(fixture.store.audit(forVersionId: try XCTUnwrap(applied.appliedVersionId)))
      XCTAssertTrue(audit.evidence.contains(.init(kind: .session, id: "base")))
      XCTAssertTrue(audit.reason.contains("approved: approved"))
      XCTAssertEqual(try fixture.store.current(workflowName: "flow")?.version.documentDigest, initial.version.documentDigest)
    }
  }

  func testRegressionServiceRejectsAndSupersedesWithoutChangingHead() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      _ = try fixture.service.register(input: fixture.input, overwrite: false, workingDirectory: fixture.root.path)
      let initial = try XCTUnwrap(fixture.store.current(workflowName: "flow"))
      let definition = WorkflowDefinitionService(storeRoot: fixture.storeRoot.path,
        fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
      func update(_ text: String, from version: String) throws -> WorkflowDefinitionVersion {
        try definition.updatePrompt(workflowName: "flow", nodeId: "worker", field: .init(parsing: "promptTemplate"),
          text: text, reason: "improve", expectedVersionId: version, evidence: [], actor: .init(kind: .improvementNode)).0
      }
      let proposals = WorkflowRollbackProposalStore(rootDirectory: fixture.storeRoot.path)
      func proposal(_ version: String, status: WorkflowRollbackProposalStatus) throws -> WorkflowRollbackProposal {
        try proposals.insertIfAbsent(.init(workflowName: "flow", regressedVersionId: version,
          rollbackToVersionId: initial.version.versionId, mode: .store, baselineSessionId: "base", targetSessionId: "target",
          regressions: [], policy: status == .recorded ? .manual : .approvalRequired,
          status: status, createdActor: .init(kind: .system))).proposal
      }
      let service = WorkflowRegressionRollbackService(workingDirectory: fixture.root.path, sessionStore: fixture.storeRoot.path)
      let first = try update("first", from: initial.version.versionId)
      let manual = try proposal(first.versionId, status: .recorded)
      XCTAssertThrowsError(try service.approve(workflowName: "flow", proposalId: manual.proposalId,
        reason: nil, actor: .init(kind: .user))) {
        XCTAssertEqual(($0 as? WorkflowRegressionRollbackError)?.code, "rollback_proposal_not_pending")
      }
      let second = try update("second", from: first.versionId)
      let rejected = try proposal(second.versionId, status: .pending)
      XCTAssertEqual(try service.reject(workflowName: "flow", proposalId: rejected.proposalId,
        reason: "declined", actor: .init(kind: .user)).status, .rejected)
      XCTAssertEqual(try fixture.store.head(workflowName: "flow")?.currentVersionId, second.versionId)
      let third = try update("third", from: second.versionId)
      let stale = try proposal(third.versionId, status: .pending)
      let fourth = try update("fourth", from: third.versionId)
      XCTAssertThrowsError(try service.approve(workflowName: "flow", proposalId: stale.proposalId,
        reason: nil, actor: .init(kind: .user))) {
        XCTAssertEqual(($0 as? WorkflowRegressionRollbackError)?.code, "rollback_superseded")
      }
      XCTAssertEqual(try proposals.proposal(id: stale.proposalId)?.status, .superseded)
      XCTAssertEqual(try fixture.store.head(workflowName: "flow")?.currentVersionId, fourth.versionId)
    }
  }

  func testGraphQLRegistrationUsesHostStoreAndAPIActor() async throws {
    let fixture = try makeFixture()
    try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let provider = FileWorkflowRegistryGraphQLProvider(workingDirectory: fixture.root.path,
        definitionStoreRoot: fixture.storeRoot.path, definitionActorId: "principal",
        fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
      let result = try await provider.registerMutableWorkflow(input: .init(overwrite: false), resolvedBundleURL: fixture.input)
      XCTAssertTrue(result.accepted)
      let audit = try XCTUnwrap(fixture.store.history(workflowName: "flow").first)
      XCTAssertEqual(audit.actor.kind, .api)
      XCTAssertEqual(audit.actor.id, "principal")
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".riela/sessions").path))
      let head = try XCTUnwrap(fixture.store.head(workflowName: "flow"))
      let definition = WorkflowDefinitionService(storeRoot: fixture.storeRoot.path,
        fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
      let update = try definition.updatePrompt(workflowName: "flow", nodeId: "worker", field: .init(parsing: "promptTemplate"),
        text: "store only", reason: "edit", expectedVersionId: head.currentVersionId, evidence: [], actor: .init(kind: .user))
      try "file change".write(to: fixture.input.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
      let changed = try await provider.updateMutableWorkflow(input: .init(target: .init(workflowId: "flow", scope: .user)),
        resolvedBundleURL: fixture.input)
      XCTAssertTrue(changed.warnings.contains { $0.message.contains(update.1.auditId) })
    }
  }

  func testUntrackedBaselineAndNoopCollapse() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      _ = try WorkflowMutableRegistry().register(input: fixture.input, overwrite: false)
      try "changed".write(to: fixture.input.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
      let target = WorkflowRegistryTarget(workflowId: "flow", scope: .user)
      _ = try fixture.service.update(target: target, input: fixture.input, workingDirectory: fixture.root.path)
      let firstHistory = try fixture.store.history(workflowName: "flow")
      XCTAssertEqual(firstHistory.count, 2)
      XCTAssertEqual(Set(firstHistory.map(\.operation)), Set([.import, .registryWrite]))
      let baseline = try XCTUnwrap(firstHistory.first { $0.operation == .import })
      let change = try XCTUnwrap(firstHistory.first { $0.operation == .registryWrite })
      XCTAssertEqual(change.previousVersionId, baseline.versionId)
      XCTAssertTrue(change.evidence.contains { $0.kind == .bundleSnapshotBefore })
      XCTAssertTrue(change.evidence.contains { $0.kind == .bundleSnapshotAfter })
      for _ in 0..<3 {
        _ = try fixture.service.update(target: target, input: fixture.input, workingDirectory: fixture.root.path)
      }
      let history = try fixture.store.history(workflowName: "flow")
      XCTAssertEqual(history.count, 3)
      XCTAssertEqual(history.filter { $0.operation == .registryWrite }.count, 2)
    }
  }

  func testSyncFailureRecoversCommittedRegistrationExactlyOnce() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let base = WorkflowDefinitionChangeRecorder(sessionStoreRoot: fixture.storeRoot.path, workingDirectory: fixture.root.path,
        fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
      let registry = WorkflowMutableRegistry(definitionRecorder: FailOnceRecorder(base: base))
      XCTAssertThrowsError(try registry.register(input: fixture.input, overwrite: false)) { error in
        XCTAssertEqual((error as? WorkflowRegistryError)?.code, .definitionSyncFailed)
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: registry.root.appendingPathComponent("flow/workflow.json").path))
      let record = registry.root.appendingPathComponent(".registry-state/transactions/flow.json")
      XCTAssertTrue(FileManager.default.fileExists(atPath: record.path))
      var committed = try JSONDecoder().decode(WorkflowMutableRegistryTransaction.self, from: Data(contentsOf: record))
      committed.requestedActivationState = .deactivated
      try JSONEncoder().encode(committed).write(to: record)
      try WorkflowMutableRegistry().withWorkflowPinnedAccess(workflowId: "flow") { _ in
        XCTAssertTrue(FileManager.default.fileExists(atPath: registry.root.appendingPathComponent("flow/workflow.json").path))
      }
      let origins = try WorkflowActivationStore().snapshot().values.map(\.origin)
      XCTAssertTrue(origins.contains { $0.workflowId == "flow" && $0.provenance == .mutable })
      XCTAssertTrue(FileManager.default.fileExists(atPath: record.path))
      let pendingBytes = try Data(contentsOf: record)
      let transaction = try JSONDecoder().decode(WorkflowMutableRegistryTransaction.self, from: pendingBytes)
      let fileOnly = WorkflowMutableRegistry()
      XCTAssertThrowsError(try fileOnly.register(input: fixture.input, overwrite: true)) { error in
        XCTAssertEqual((error as? WorkflowRegistryError)?.code, .definitionSyncFailed)
      }
      XCTAssertThrowsError(try fileOnly.update(workflowId: "flow", input: fixture.input)) { error in
        XCTAssertEqual((error as? WorkflowRegistryError)?.code, .definitionSyncFailed)
      }
      XCTAssertThrowsError(try fileOnly.delete(workflowId: "flow")) { error in
        XCTAssertEqual((error as? WorkflowRegistryError)?.code, .definitionSyncFailed)
      }
      XCTAssertEqual(try Data(contentsOf: record), pendingBytes)
      try WorkflowActivationStore().withCoordinatorLock { try registry.recoverWorkflow(workflowId: "flow") }
      XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
      XCTAssertEqual(try fixture.store.history(workflowName: "flow").filter { $0.operation == .registryWrite }.count, 1)
      XCTAssertTrue(try fixture.store.history(workflowName: "flow").contains {
        $0.evidence.contains(.init(kind: .fileTransaction, id: transaction.transactionId))
      })
      try registry.recoverWorkflow(workflowId: "flow")
      XCTAssertEqual(try fixture.store.history(workflowName: "flow").filter { $0.operation == .registryWrite }.count, 1)
    }
  }

  func testRecorderlessReadPreservesCommittedUpdateForReplay() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      _ = try fixture.service.register(input: fixture.input, overwrite: false, workingDirectory: fixture.root.path)
      try "updated".write(to: fixture.input.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
      let base = WorkflowDefinitionChangeRecorder(sessionStoreRoot: fixture.storeRoot.path, workingDirectory: fixture.root.path,
        fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
      let registry = WorkflowMutableRegistry(definitionRecorder: FailOnceRecorder(base: base))
      XCTAssertThrowsError(try registry.update(workflowId: "flow", input: fixture.input)) { error in
        XCTAssertEqual((error as? WorkflowRegistryError)?.code, .definitionSyncFailed)
      }
      let record = registry.root.appendingPathComponent(".registry-state/transactions/flow.json")
      let pending = try Data(contentsOf: record)
      let transaction = try JSONDecoder().decode(WorkflowMutableRegistryTransaction.self, from: pending)
      try WorkflowMutableRegistry().withWorkflowPinnedAccess(workflowId: "flow") { _ in
        XCTAssertEqual(try String(contentsOf: registry.root.appendingPathComponent("flow/prompts/p.md"), encoding: .utf8), "updated")
      }
      XCTAssertEqual(try Data(contentsOf: record), pending)
      try registry.recoverWorkflow(workflowId: "flow")
      try registry.recoverWorkflow(workflowId: "flow")
      let audits = try fixture.store.history(workflowName: "flow").filter {
        $0.operation == .registryWrite && $0.evidence.contains(.init(kind: .fileTransaction, id: transaction.transactionId))
      }
      XCTAssertEqual(audits.count, 1)
      XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }
  }

  func testRecorderlessReadPreservesCommittedDeleteForReplay() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      _ = try fixture.service.register(input: fixture.input, overwrite: false, workingDirectory: fixture.root.path)
      let base = WorkflowDefinitionChangeRecorder(sessionStoreRoot: fixture.storeRoot.path, workingDirectory: fixture.root.path,
        fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
      let registry = WorkflowMutableRegistry(definitionRecorder: FailOnceRecorder(base: base, failDelete: true))
      XCTAssertThrowsError(try registry.delete(workflowId: "flow")) { error in
        XCTAssertEqual((error as? WorkflowRegistryError)?.code, .definitionSyncFailed)
      }
      let record = registry.root.appendingPathComponent(".registry-state/transactions/flow.json")
      let pendingBytes = try Data(contentsOf: record)
      let transaction = try JSONDecoder().decode(WorkflowMutableRegistryTransaction.self, from: pendingBytes)
      try WorkflowMutableRegistry().withWorkflowPinnedAccess(workflowId: "flow") { _ in
        XCTAssertFalse(FileManager.default.fileExists(atPath: registry.root.appendingPathComponent("flow").path))
      }
      XCTAssertEqual(try Data(contentsOf: record), pendingBytes)
      try registry.recoverWorkflow(workflowId: "flow")
      try registry.recoverWorkflow(workflowId: "flow")
      XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
      XCTAssertEqual(try fixture.store.history(workflowName: "flow").filter { $0.operation == .registryDelete }.count, 1)
      XCTAssertTrue(try fixture.store.history(workflowName: "flow").contains {
        $0.operation == .registryDelete && $0.evidence.contains(.init(kind: .fileTransaction, id: transaction.transactionId))
      })
    }
  }

  func testDeleteWithoutDefinitionHeadDoesNotCreateHistory() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      _ = try WorkflowMutableRegistry().register(input: fixture.input, overwrite: false)
      _ = try fixture.service.delete(target: .init(workflowId: "flow", scope: .user), workingDirectory: fixture.root.path)
      XCTAssertNil(try fixture.store.head(workflowName: "flow"))
      XCTAssertTrue(try fixture.store.history(workflowName: "flow").isEmpty)
    }
  }

  func testAttributedPublicationWritesSelfImproveHistory() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      _ = try fixture.service.register(input: fixture.input, overwrite: false, workingDirectory: fixture.root.path)
      let recorder = WorkflowDefinitionChangeRecorder(sessionStoreRoot: fixture.storeRoot.path,
        workingDirectory: fixture.root.path,
        fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
      let registry = WorkflowMutableRegistry(definitionRecorder: recorder)
      let digest = try registry.withWorkflowPinnedAccess(workflowId: "flow") { pinned in
        try registry.bundleDigest(at: registry.root.appendingPathComponent("flow"), pinned: XCTUnwrap(pinned))
      }
      let attribution = WorkflowDefinitionChangeAttribution(operation: .selfImprove,
        actor: .init(kind: .cli, id: "test"), reason: "improve")
      _ = try registry.withWorkflowMutationAccess(workflowId: "flow", expectedDigest: digest, attribution: attribution) { workspace, publish in
        try "improved".write(to: workspace.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
        try publish(workspace)
      }
      let history = try fixture.store.history(workflowName: "flow")
      XCTAssertEqual(history.filter { $0.operation == .selfImprove }.count, 1)
      XCTAssertEqual(history.filter { $0.operation == .registryWrite }.count, 1)
    }
  }

}

extension WorkflowRegistryDefinitionSyncTests {
  func testRegressionServiceApprovesBundleProposal() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      _ = try fixture.service.register(input: fixture.input, overwrite: false, workingDirectory: fixture.root.path)
      let initial = try XCTUnwrap(fixture.store.current(workflowName: "flow"))
      let recorder = WorkflowDefinitionChangeRecorder(sessionStoreRoot: fixture.storeRoot.path,
        workingDirectory: fixture.root.path,
        fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
      let registry = WorkflowMutableRegistry(definitionRecorder: recorder)
      let digest = try registry.withWorkflowPinnedAccess(workflowId: "flow") { pinned in
        try registry.bundleDigest(at: registry.root.appendingPathComponent("flow"), pinned: XCTUnwrap(pinned))
      }
      let attribution = WorkflowDefinitionChangeAttribution(operation: .selfImprove,
        actor: .init(kind: .cli), reason: "improve")
      _ = try registry.withWorkflowMutationAccess(workflowId: "flow", expectedDigest: digest, attribution: attribution) { workspace, publish in
        try "improved".write(to: workspace.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
        try publish(workspace)
      }
      let improved = try XCTUnwrap(fixture.store.current(workflowName: "flow"))
      let audit = try XCTUnwrap(fixture.store.audit(forVersionId: improved.version.versionId))
      let snapshot = try XCTUnwrap(audit.evidence.first { $0.kind == .bundleSnapshotBefore }?.id)
      let proposals = WorkflowRollbackProposalStore(rootDirectory: fixture.storeRoot.path)
      let proposal = try proposals.insertIfAbsent(.init(workflowName: "flow", regressedVersionId: improved.version.versionId,
        rollbackToVersionId: initial.version.versionId, mode: .bundle, bundleSnapshotId: snapshot,
        baselineSessionId: "base", targetSessionId: "target", regressions: [], policy: .approvalRequired,
        status: .pending, createdActor: .init(kind: .system))).proposal
      let service = WorkflowRegressionRollbackService(workingDirectory: fixture.root.path,
        sessionStore: fixture.storeRoot.path, scope: .user)
      let applied = try service.approve(workflowName: "flow", proposalId: proposal.proposalId,
        reason: "approved", actor: .init(kind: .user))
      XCTAssertEqual(applied.status, .applied)
      XCTAssertEqual(try fixture.store.current(workflowName: "flow")?.version.documentDigest, initial.version.documentDigest)
      let history = try fixture.store.history(workflowName: "flow")
      XCTAssertEqual(history.filter { $0.operation == .rollback }.count, 1)
      XCTAssertEqual(history.filter { $0.operation == .registryWrite }.count, 1)
      XCTAssertTrue(try XCTUnwrap(history.first { $0.operation == .rollback }).evidence.contains { $0.kind == .fileTransaction })
    }
  }

  func testBundleApprovalRejectsSourceDirectoryMismatch() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let (proposal, improved) = try makeBundleProposal(fixture: fixture, targetImproved: false)
      let database = try fixture.store.openDatabase()
      try database.execute("UPDATE definition_heads SET source_directory=? WHERE workflow_name=?",
        bindings: [.text(fixture.root.appendingPathComponent("other-source").path), .text("flow")])
      let service = WorkflowRegressionRollbackService(workingDirectory: fixture.root.path,
        sessionStore: fixture.storeRoot.path, scope: .user)
      XCTAssertThrowsError(try service.approve(workflowName: "flow", proposalId: proposal.proposalId,
        reason: nil, actor: .init(kind: .user))) {
        XCTAssertEqual(($0 as? WorkflowRegressionRollbackError)?.code, "rollback_snapshot_unavailable")
      }
      let result = try XCTUnwrap(WorkflowRollbackProposalStore(rootDirectory: fixture.storeRoot.path).proposal(id: proposal.proposalId))
      XCTAssertEqual(result.status, .failed)
      XCTAssertTrue(result.diagnostics.contains("sourceMismatch"))
      XCTAssertEqual(try fixture.store.head(workflowName: "flow")?.currentVersionId, improved.versionId)
      let path = WorkflowMutableRegistry().root.appendingPathComponent("flow/prompts/p.md")
      XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "improved")
    }
  }

  func testRejectBeforeBundleClaimLeavesFilesUnchanged() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let (proposal, improved) = try makeBundleProposal(fixture: fixture, targetImproved: false)
      let service = WorkflowRegressionRollbackService(workingDirectory: fixture.root.path,
        sessionStore: fixture.storeRoot.path, scope: .user)
      XCTAssertEqual(try service.reject(workflowName: "flow", proposalId: proposal.proposalId,
        reason: "declined", actor: .init(kind: .user)).status, .rejected)
      let proposals = WorkflowRollbackProposalStore(rootDirectory: fixture.storeRoot.path)
      XCTAssertThrowsError(try proposals.claim(proposalId: proposal.proposalId,
        expectedHeadVersionId: improved.versionId, claimTransactionId: "late"))
      XCTAssertThrowsError(try service.approve(workflowName: "flow", proposalId: proposal.proposalId,
        reason: nil, actor: .init(kind: .user)))
      XCTAssertEqual(try fixture.store.head(workflowName: "flow")?.currentVersionId, improved.versionId)
      let path = WorkflowMutableRegistry().root.appendingPathComponent("flow/prompts/p.md")
      XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "improved")
    }
  }

  func testBundleApprovalRejectsDirtyConflict() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let inputNode = fixture.input.appendingPathComponent("nodes/worker.json")
      let originalNode = try String(contentsOf: inputNode, encoding: .utf8)
      try originalNode.replacingOccurrences(of: "prompts/p.md", with: "verify.sh")
        .write(to: inputNode, atomically: true, encoding: .utf8)
      try "original script".write(to: fixture.input.appendingPathComponent("verify.sh"), atomically: true, encoding: .utf8)
      _ = try fixture.service.register(input: fixture.input, overwrite: false, workingDirectory: fixture.root.path)
      let initial = try XCTUnwrap(fixture.store.current(workflowName: "flow"))
      let recorder = WorkflowDefinitionChangeRecorder(sessionStoreRoot: fixture.storeRoot.path, workingDirectory: fixture.root.path,
        fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
      let registry = WorkflowMutableRegistry(definitionRecorder: recorder)
      let digest = try registry.withWorkflowPinnedAccess(workflowId: "flow") { pinned in
        try registry.bundleDigest(at: registry.root.appendingPathComponent("flow"), pinned: XCTUnwrap(pinned))
      }
      let attribution = WorkflowDefinitionChangeAttribution(operation: .selfImprove, actor: .init(kind: .cli), reason: "improve")
      _ = try registry.withWorkflowMutationAccess(workflowId: "flow", expectedDigest: digest, attribution: attribution) { workspace, publish in
        try originalNode.write(to: workspace.appendingPathComponent("nodes/worker.json"), atomically: true, encoding: .utf8)
        try publish(workspace)
      }
      let improved = try XCTUnwrap(fixture.store.current(workflowName: "flow"))
      let audit = try XCTUnwrap(fixture.store.audit(forVersionId: improved.version.versionId))
      let snapshot = try XCTUnwrap(audit.evidence.first { $0.kind == .bundleSnapshotBefore }?.id)
      let path = registry.root.appendingPathComponent("flow/verify.sh")
      try "local change".write(to: path, atomically: true, encoding: .utf8)
      let proposals = WorkflowRollbackProposalStore(rootDirectory: fixture.storeRoot.path)
      let proposal = try proposals.insertIfAbsent(.init(workflowName: "flow", regressedVersionId: improved.version.versionId,
        rollbackToVersionId: initial.version.versionId, mode: .bundle, bundleSnapshotId: snapshot,
        baselineSessionId: "base", targetSessionId: "target", regressions: [], policy: .approvalRequired,
        status: .pending, createdActor: .init(kind: .system))).proposal
      let service = WorkflowRegressionRollbackService(workingDirectory: fixture.root.path, sessionStore: fixture.storeRoot.path, scope: .user)
      XCTAssertThrowsError(try service.approve(workflowName: "flow", proposalId: proposal.proposalId,
        reason: nil, actor: .init(kind: .user))) {
        XCTAssertEqual(($0 as? WorkflowRegressionRollbackError)?.code, "restore_dirty_conflicts", "\($0)")
      }
      XCTAssertEqual(try proposals.proposal(id: proposal.proposalId)?.status, .failed)
      XCTAssertEqual(try fixture.store.head(workflowName: "flow")?.currentVersionId, improved.version.versionId)
      XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "local change")
    }
  }

  func testBundleApprovalRecoversGenericPostClaimError() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let (proposal, improved) = try makeBundleProposal(fixture: fixture, targetImproved: false)
      let recorder = WorkflowDefinitionChangeRecorder(sessionStoreRoot: fixture.storeRoot.path,
        workingDirectory: fixture.root.path,
        fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
      let registry = WorkflowMutableRegistry(hooks: .init(afterPhase: { phase in
        if phase == .prepared { throw CLIUsageError("injected generic failure") }
      }), definitionRecorder: recorder)
      let service = WorkflowRegressionRollbackService(workingDirectory: fixture.root.path, sessionStore: fixture.storeRoot.path,
        scope: .user, snapshotService: WorkflowSnapshotService(mutableRegistry: registry))
      XCTAssertThrowsError(try service.approve(workflowName: "flow", proposalId: proposal.proposalId,
        reason: nil, actor: .init(kind: .user)))
      let current = try WorkflowRollbackProposalStore(rootDirectory: fixture.storeRoot.path).proposal(id: proposal.proposalId)
      XCTAssertEqual(current?.status, .pending)
      XCTAssertEqual(try fixture.store.head(workflowName: "flow")?.currentVersionId, improved.versionId)
      XCTAssertEqual(try String(contentsOf: registry.root.appendingPathComponent("flow/prompts/p.md"), encoding: .utf8), "improved")
    }
  }

  func testBundleApprovalFailsInvalidDefinitionAfterClaim() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let (proposal, improved) = try makeBundleProposal(fixture: fixture, targetImproved: false)
      let recorder = WorkflowDefinitionChangeRecorder(sessionStoreRoot: fixture.storeRoot.path,
        workingDirectory: fixture.root.path,
        fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
      let registry = WorkflowMutableRegistry(hooks: .init(afterPhase: { phase in
        if phase == .prepared { throw WorkflowResolutionError.invalidWorkflow([]) }
      }), definitionRecorder: recorder)
      let service = WorkflowRegressionRollbackService(workingDirectory: fixture.root.path, sessionStore: fixture.storeRoot.path,
        scope: .user, snapshotService: WorkflowSnapshotService(mutableRegistry: registry))
      XCTAssertThrowsError(try service.approve(workflowName: "flow", proposalId: proposal.proposalId,
        reason: nil, actor: .init(kind: .user))) {
        XCTAssertEqual(($0 as? WorkflowRegressionRollbackError)?.code, "invalid_definition", "\($0)")
      }
      let result = try XCTUnwrap(WorkflowRollbackProposalStore(rootDirectory: fixture.storeRoot.path).proposal(id: proposal.proposalId))
      XCTAssertEqual(result.status, .failed)
      XCTAssertEqual(result.failureCode, "invalid_definition")
      XCTAssertEqual(try fixture.store.head(workflowName: "flow")?.currentVersionId, improved.versionId)
      XCTAssertEqual(try String(contentsOf: registry.root.appendingPathComponent("flow/prompts/p.md"), encoding: .utf8), "improved")
    }
  }

  func testBundleApprovalRecordsDigestMismatch() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let (proposal, improved) = try makeBundleProposal(fixture: fixture, targetImproved: true)
      let service = WorkflowRegressionRollbackService(workingDirectory: fixture.root.path,
        sessionStore: fixture.storeRoot.path, scope: .user)
      let result = try service.approve(workflowName: "flow", proposalId: proposal.proposalId,
        reason: nil, actor: .init(kind: .user))
      XCTAssertEqual(result.status, .applied)
      XCTAssertTrue(result.diagnostics.contains("rollbackDigestMismatch"))
      XCTAssertNotEqual(try fixture.store.current(workflowName: "flow")?.version.documentDigest, improved.documentDigest)
      XCTAssertEqual(try WorkflowRollbackProposalStore(rootDirectory: fixture.storeRoot.path)
        .proposal(id: proposal.proposalId)?.diagnostics, result.diagnostics)
    }
  }

  func testConcurrentBundleApprovalsRestoreOnce() async throws {
    let fixture = try makeFixture()
    let environment = ["HOME": fixture.home.path]
    let proposal = try CLIRuntimeEnvironment.$overrides.withValue(environment) {
      try makeBundleProposal(fixture: fixture, targetImproved: false).0
    }
    func approve() async -> WorkflowRollbackProposal? {
      await Task {
        CLIRuntimeEnvironment.$overrides.withValue(environment) {
          let service = WorkflowRegressionRollbackService(workingDirectory: fixture.root.path,
            sessionStore: fixture.storeRoot.path, scope: .user)
          return try? service.approve(workflowName: "flow", proposalId: proposal.proposalId,
            reason: nil, actor: .init(kind: .user))
        }
      }.value
    }
    async let first = approve()
    async let second = approve()
    let results = await [first, second].compactMap { $0 }
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?.status, .applied)
    XCTAssertEqual(try fixture.store.history(workflowName: "flow").filter { $0.operation == .rollback }.count, 1)
    try CLIRuntimeEnvironment.$overrides.withValue(environment) {
      let registry = WorkflowMutableRegistry()
      XCTAssertEqual(try String(contentsOf: registry.root.appendingPathComponent("flow/prompts/p.md"), encoding: .utf8), "original")
    }
  }

  func testConcurrentRegistryUpdateAndApprovalComplete() async throws {
    let fixture = try makeFixture()
    let environment = ["HOME": fixture.home.path]
    let proposal = try CLIRuntimeEnvironment.$overrides.withValue(environment) {
      try makeBundleProposal(fixture: fixture, targetImproved: false).0
    }
    let paused = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let updateFinished = DispatchSemaphore(value: 0)
    let approvalStarted = DispatchSemaphore(value: 0)
    let approvalFinished = DispatchSemaphore(value: 0)
    defer { resume.signal() }
    let update = Task {
      defer { updateFinished.signal() }
      return try CLIRuntimeEnvironment.$overrides.withValue(environment) {
        let recorder = WorkflowDefinitionChangeRecorder(sessionStoreRoot: fixture.storeRoot.path, workingDirectory: fixture.root.path,
          fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
        let registry = WorkflowMutableRegistry(hooks: .init(afterPhase: { phase in
          if phase == .prepared { paused.signal(); resume.wait() }
        }), definitionRecorder: recorder)
        let digest = try registry.withWorkflowPinnedAccess(workflowId: "flow") { pinned in
          try registry.bundleDigest(at: registry.root.appendingPathComponent("flow"), pinned: XCTUnwrap(pinned))
        }
        return try registry.withWorkflowMutationAccess(workflowId: "flow", expectedDigest: digest) { workspace, publish in
          try "concurrent update".write(to: workspace.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
          try publish(workspace)
        }
      }
    }
    XCTAssertEqual(paused.wait(timeout: .now() + 5), .success)
    let approval = Task {
      defer { approvalFinished.signal() }
      approvalStarted.signal()
      return CLIRuntimeEnvironment.$overrides.withValue(environment) {
        let service = WorkflowRegressionRollbackService(workingDirectory: fixture.root.path,
          sessionStore: fixture.storeRoot.path, scope: .user)
        return try? service.approve(workflowName: "flow", proposalId: proposal.proposalId, reason: nil, actor: .init(kind: .user))
      }
    }
    XCTAssertEqual(approvalStarted.wait(timeout: .now() + 5), .success)
    resume.signal()
    XCTAssertEqual(updateFinished.wait(timeout: .now() + 10), .success)
    XCTAssertEqual(approvalFinished.wait(timeout: .now() + 10), .success)
    _ = try await update.value
    let approvalResult = await approval.value
    XCTAssertNil(approvalResult)
    XCTAssertEqual(try fixture.store.history(workflowName: "flow").filter { $0.operation == .rollback }.count, 0)
    try CLIRuntimeEnvironment.$overrides.withValue(environment) {
      let path = WorkflowMutableRegistry().root.appendingPathComponent("flow/prompts/p.md")
      XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "concurrent update")
    }
  }

  func testAutomaticBundleRegressionUsesParentPolicyAndIsIdempotent() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let workflowURL = fixture.input.appendingPathComponent("workflow.json")
      var workflow = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workflowURL)) as? [String: Any])
      workflow["loop"] = ["regressionRollback": ["policy": "automatic"]]
      try JSONSerialization.data(withJSONObject: workflow).write(to: workflowURL)
      _ = try fixture.service.register(input: fixture.input, overwrite: false, workingDirectory: fixture.root.path)
      let initial = try XCTUnwrap(fixture.store.current(workflowName: "flow"))
      let recorder = WorkflowDefinitionChangeRecorder(sessionStoreRoot: fixture.storeRoot.path,
        workingDirectory: fixture.root.path,
        fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
      let registry = WorkflowMutableRegistry(definitionRecorder: recorder)
      let digest = try registry.withWorkflowPinnedAccess(workflowId: "flow") { pinned in
        try registry.bundleDigest(at: registry.root.appendingPathComponent("flow"), pinned: XCTUnwrap(pinned))
      }
      let attribution = WorkflowDefinitionChangeAttribution(operation: .selfImprove, actor: .init(kind: .cli), reason: "improve")
      _ = try registry.withWorkflowMutationAccess(workflowId: "flow", expectedDigest: digest, attribution: attribution) { workspace, publish in
        try "improved".write(to: workspace.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
        try publish(workspace)
      }
      let improved = try XCTUnwrap(fixture.store.current(workflowName: "flow"))
      XCTAssertEqual(try WorkflowDefinitionDocument.decode(initial.document).runtime.workflow.loop?.regressionRollback?.policy, .automatic)
      XCTAssertNil(try fixture.store.audit(forVersionId: improved.version.versionId)?.overwrittenChanges)
      let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: fixture.storeRoot.path))
      let date = Date(timeIntervalSince1970: 1_700_000_000)
      func saveSession(_ id: String, version: WorkflowDefinitionVersion, outcome: String) throws {
        let pin = WorkflowDefinitionSource(kind: .store, workflowName: "flow", versionId: version.versionId,
          storeRoot: fixture.storeRoot.path, digest: version.documentDigest, sourcePath: version.sourceDirectory, sourceScope: "user")
        let session = WorkflowSession(workflowId: "flow", sessionId: id, status: .completed, entryStepId: "first",
          createdAt: date, updatedAt: date, definitionSource: pin)
        try CLIWorkflowSessionStore(rootDirectory: fixture.storeRoot.path).save(.init(workflowName: "flow", session: session,
          resolution: .init(workflowName: "flow", scope: .user, workingDirectory: fixture.root.path)))
        var snapshot = try runtime.load(sessionId: id)
        snapshot.loopEvidence = LoopEvidenceManifest(schemaVersion: 1, manifestId: "loop-evidence-\(id)", workflowId: "flow",
          sessionId: id, workflowSource: .init(scope: "user", kind: "workflow-directory", mutable: true), policy: .init(),
          commands: [.init(id: "verify", argvSummary: "verify", argvRedactionStatus: "clean")],
          verification: [.init(id: "v", commandRef: "verify", outcome: outcome)],
          redaction: .init(policyName: "summary-only", status: "clean"), createdAt: date, updatedAt: date)
        try runtime.save(snapshot)
      }
      try saveSession("baseline", version: initial.version, outcome: "passed")
      try saveSession("target", version: improved.version, outcome: "failed")
      try runtime.setLoopBaseline(.init(workflowId: "flow", sessionId: "baseline", setAt: date))
      let service = WorkflowRegressionRollbackService(workingDirectory: fixture.root.path, sessionStore: fixture.storeRoot.path, scope: .user)
      let target = try runtime.load(sessionId: "target")
      let bundle = try FileSystemWorkflowBundleResolver().resolve(.init(workflowName: "flow", scope: .user,
        workingDirectory: fixture.root.path))
      let run = WorkflowRunResult(workflowId: "flow", session: target.session, rootOutput: nil, exitCode: 0, transitions: 0)
      var options = WorkflowRunOptions(target: "flow", sessionStore: fixture.storeRoot.path, workingDirectory: fixture.root.path)
      options.executionMode = .service(.init(kind: .system))
      WorkflowRunCommand().evaluateRegressionRollbackAfterTerminalPersistence(finalResult: run, loopEvidence: target.loopEvidence,
        bundle: bundle, options: options, storeRoot: fixture.storeRoot.path)
      let proposal = try XCTUnwrap(WorkflowRollbackProposalStore(rootDirectory: fixture.storeRoot.path)
        .proposal(workflowName: "flow", regressedVersionId: improved.version.versionId))
      XCTAssertEqual(proposal.status, .applied)
      let current = try XCTUnwrap(fixture.store.current(workflowName: "flow"))
      XCTAssertEqual(current.version.documentDigest, initial.version.documentDigest)
      XCTAssertEqual(current.version.actor, .init(kind: .system, id: "regression-rollback@target"))
      XCTAssertEqual(try service.check(workflowName: "flow", targetSessionId: "target", actor: .init(kind: .user)).outcome, .existing)
      XCTAssertEqual(try fixture.store.head(workflowName: "flow")?.currentVersionId, current.version.versionId)
    }
  }

  func testFirstUseBundleRegressionRestoresCapturedBaseline() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      let workflowURL = fixture.input.appendingPathComponent("workflow.json")
      var workflow = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workflowURL)) as? [String: Any])
      workflow["loop"] = ["regressionRollback": ["policy": "approval-required"]]
      try JSONSerialization.data(withJSONObject: workflow).write(to: workflowURL)
      _ = try WorkflowMutableRegistry().register(input: fixture.input, overwrite: false)
      XCTAssertNil(try fixture.store.head(workflowName: "flow"))
      let recorder = WorkflowDefinitionChangeRecorder(sessionStoreRoot: fixture.storeRoot.path,
        workingDirectory: fixture.root.path,
        fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
      let registry = WorkflowMutableRegistry(definitionRecorder: recorder)
      let digest = try registry.withWorkflowPinnedAccess(workflowId: "flow") { pinned in
        try registry.bundleDigest(at: registry.root.appendingPathComponent("flow"), pinned: XCTUnwrap(pinned))
      }
      let attribution = WorkflowDefinitionChangeAttribution(operation: .selfImprove, actor: .init(kind: .cli), reason: "improve")
      _ = try registry.withWorkflowMutationAccess(workflowId: "flow", expectedDigest: digest, attribution: attribution) { workspace, publish in
        try "improved".write(to: workspace.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
        try publish(workspace)
      }
      let improved = try XCTUnwrap(fixture.store.current(workflowName: "flow"))
      let baselineId = try XCTUnwrap(improved.version.parentVersionId)
      let initial = try XCTUnwrap(fixture.store.version(versionId: baselineId))
      let initialDocument = try XCTUnwrap(fixture.store.document(versionId: baselineId))
      XCTAssertEqual(try WorkflowDefinitionDocument.decode(initialDocument).runtime.workflow.loop?.regressionRollback?.policy, .approvalRequired)
      XCTAssertNil(try fixture.store.audit(forVersionId: improved.version.versionId)?.overwrittenChanges)
      let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: fixture.storeRoot.path))
      let date = Date(timeIntervalSince1970: 1_700_000_000)
      func saveSession(_ id: String, version: WorkflowDefinitionVersion, outcome: String) throws {
        let pin = WorkflowDefinitionSource(kind: .store, workflowName: "flow", versionId: version.versionId,
          storeRoot: fixture.storeRoot.path, digest: version.documentDigest, sourcePath: version.sourceDirectory, sourceScope: "user")
        let session = WorkflowSession(workflowId: "flow", sessionId: id, status: .completed, entryStepId: "first",
          createdAt: date, updatedAt: date, definitionSource: pin)
        try CLIWorkflowSessionStore(rootDirectory: fixture.storeRoot.path).save(.init(workflowName: "flow", session: session,
          resolution: .init(workflowName: "flow", scope: .user, workingDirectory: fixture.root.path)))
        var snapshot = try runtime.load(sessionId: id)
        snapshot.loopEvidence = LoopEvidenceManifest(schemaVersion: 1, manifestId: "loop-evidence-\(id)", workflowId: "flow",
          sessionId: id, workflowSource: .init(scope: "user", kind: "workflow-directory", mutable: true), policy: .init(),
          commands: [.init(id: "verify", argvSummary: "verify", argvRedactionStatus: "clean")],
          verification: [.init(id: "v", commandRef: "verify", outcome: outcome)],
          redaction: .init(policyName: "summary-only", status: "clean"), createdAt: date, updatedAt: date)
        try runtime.save(snapshot)
      }
      try saveSession("baseline", version: initial, outcome: "passed")
      try saveSession("target", version: improved.version, outcome: "failed")
      try runtime.setLoopBaseline(.init(workflowId: "flow", sessionId: "baseline", setAt: date))
      let service = WorkflowRegressionRollbackService(workingDirectory: fixture.root.path, sessionStore: fixture.storeRoot.path, scope: .user)
      let target = try runtime.load(sessionId: "target")
      let bundle = try FileSystemWorkflowBundleResolver().resolve(.init(workflowName: "flow", scope: .user,
        workingDirectory: fixture.root.path))
      let run = WorkflowRunResult(workflowId: "flow", session: target.session, rootOutput: nil, exitCode: 0, transitions: 0)
      var options = WorkflowRunOptions(target: "flow", sessionStore: fixture.storeRoot.path, workingDirectory: fixture.root.path)
      options.executionMode = .service(.init(kind: .system))
      WorkflowRunCommand().evaluateRegressionRollbackAfterTerminalPersistence(finalResult: run, loopEvidence: target.loopEvidence,
        bundle: bundle, options: options, storeRoot: fixture.storeRoot.path)
      let proposal = try XCTUnwrap(WorkflowRollbackProposalStore(rootDirectory: fixture.storeRoot.path)
        .proposal(workflowName: "flow", regressedVersionId: improved.version.versionId))
      XCTAssertEqual(proposal.status, .pending)
      XCTAssertEqual(proposal.mode, .bundle)
      XCTAssertEqual(proposal.rollbackToVersionId, baselineId)
      let applied = try service.approve(workflowName: "flow", proposalId: proposal.proposalId, reason: "approved", actor: .init(kind: .user))
      XCTAssertEqual(applied.status, .applied)
      let current = try XCTUnwrap(fixture.store.current(workflowName: "flow"))
      XCTAssertEqual(current.version.documentDigest, initial.documentDigest)
      XCTAssertEqual(current.version.actor.kind, .user)
      XCTAssertEqual(try String(contentsOf: registry.root.appendingPathComponent("flow/prompts/p.md"), encoding: .utf8), "original")
      XCTAssertEqual(try service.check(workflowName: "flow", targetSessionId: "target", actor: .init(kind: .user)).outcome, .existing)
      XCTAssertEqual(try fixture.store.head(workflowName: "flow")?.currentVersionId, current.version.versionId)
    }
  }

  func testBundleApprovalFailsInvalidSnapshotWithoutHeadChange() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      _ = try fixture.service.register(input: fixture.input, overwrite: false, workingDirectory: fixture.root.path)
      let head = try XCTUnwrap(fixture.store.head(workflowName: "flow"))
      let proposals = WorkflowRollbackProposalStore(rootDirectory: fixture.storeRoot.path)
      let proposal = try proposals.insertIfAbsent(.init(workflowName: "flow", regressedVersionId: head.currentVersionId,
        rollbackToVersionId: head.currentVersionId, mode: .bundle, bundleSnapshotId: "invalid/id",
        baselineSessionId: "base", targetSessionId: "target", regressions: [], policy: .approvalRequired,
        status: .pending, createdActor: .init(kind: .system))).proposal
      let service = WorkflowRegressionRollbackService(workingDirectory: fixture.root.path,
        sessionStore: fixture.storeRoot.path, scope: .user)
      XCTAssertThrowsError(try service.approve(workflowName: "flow", proposalId: proposal.proposalId,
        reason: nil, actor: .init(kind: .user))) {
        XCTAssertEqual(($0 as? WorkflowRegressionRollbackError)?.code, "rollback_snapshot_unavailable")
      }
      let failed = try XCTUnwrap(proposals.proposal(id: proposal.proposalId))
      XCTAssertEqual(failed.status, .failed)
      XCTAssertEqual(failed.failureCode, "rollback_snapshot_unavailable")
      XCTAssertEqual(try fixture.store.head(workflowName: "flow")?.currentVersionId, head.currentVersionId)
    }
  }

  func testRegressionCheckRecoversUnpublishedClaim() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      _ = try fixture.service.register(input: fixture.input, overwrite: false, workingDirectory: fixture.root.path)
      let head = try XCTUnwrap(fixture.store.head(workflowName: "flow"))
      let proposals = WorkflowRollbackProposalStore(rootDirectory: fixture.storeRoot.path)
      let proposal = try proposals.insertIfAbsent(.init(workflowName: "flow", regressedVersionId: head.currentVersionId,
        rollbackToVersionId: head.currentVersionId, mode: .bundle, baselineSessionId: "base", targetSessionId: "target",
        regressions: [], policy: .approvalRequired, status: .pending, createdActor: .init(kind: .system))).proposal
      _ = try proposals.claim(proposalId: proposal.proposalId, expectedHeadVersionId: head.currentVersionId,
        claimTransactionId: "interrupted")
      let service = WorkflowRegressionRollbackService(workingDirectory: fixture.root.path,
        sessionStore: fixture.storeRoot.path, scope: .user)
      XCTAssertEqual(try service.check(workflowName: "flow", targetSessionId: nil, actor: .init(kind: .system)).outcome, .noBaseline)
      XCTAssertEqual(try proposals.proposal(id: proposal.proposalId)?.status, .pending)
      XCTAssertEqual(try fixture.store.head(workflowName: "flow")?.currentVersionId, head.currentVersionId)
    }
  }

  func testRecoveryWaitsForLiveRegistryClaim() async throws {
    let fixture = try makeFixture()
    let environment = ["HOME": fixture.home.path]
    let paused = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let recoveryStarted = DispatchSemaphore(value: 0)
    let recoveryFinished = DispatchSemaphore(value: 0)
    defer { resume.signal() }
    let proposals = WorkflowRollbackProposalStore(rootDirectory: fixture.storeRoot.path)
    let (head, proposal, digest) = try CLIRuntimeEnvironment.$overrides.withValue(environment) {
      _ = try fixture.service.register(input: fixture.input, overwrite: false, workingDirectory: fixture.root.path)
      let head = try XCTUnwrap(fixture.store.head(workflowName: "flow"))
      let proposal = try proposals.insertIfAbsent(.init(workflowName: "flow", regressedVersionId: head.currentVersionId,
        rollbackToVersionId: head.currentVersionId, mode: .bundle, baselineSessionId: "base", targetSessionId: "target",
        regressions: [], policy: .approvalRequired, status: .pending, createdActor: .init(kind: .user))).proposal
      let registry = WorkflowMutableRegistry()
      let digest = try registry.withWorkflowPinnedAccess(workflowId: "flow") { pinned in
        try registry.bundleDigest(at: registry.root.appendingPathComponent("flow"), pinned: XCTUnwrap(pinned))
      }
      return (head, proposal, digest)
    }
    let writer = Task {
      try CLIRuntimeEnvironment.$overrides.withValue(environment) {
        let recorder = WorkflowDefinitionChangeRecorder(sessionStoreRoot: fixture.storeRoot.path, workingDirectory: fixture.root.path,
          fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
        let registry = WorkflowMutableRegistry(hooks: .init(afterPhase: { phase in
          if phase == .prepared { paused.signal(); resume.wait() }
        }), definitionRecorder: recorder)
        let attribution = WorkflowDefinitionChangeAttribution(operation: .rollback, actor: .init(kind: .user),
          reason: "rollback", rollbackProposalId: proposal.proposalId)
        _ = try registry.withWorkflowMutationAccess(workflowId: "flow", expectedDigest: digest, attribution: attribution,
          beforePublication: { transactionId in
            _ = try proposals.claim(proposalId: proposal.proposalId, expectedHeadVersionId: head.currentVersionId,
              claimTransactionId: transactionId)
          }, { workspace, publish in
            try "replacement".write(to: workspace.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
            try publish(workspace)
          })
      }
    }
    XCTAssertEqual(paused.wait(timeout: .now() + 5), .success)
    let recovery = Task {
      defer { recoveryFinished.signal() }
      return try CLIRuntimeEnvironment.$overrides.withValue(environment) {
        let service = WorkflowRegressionRollbackService(workingDirectory: fixture.root.path,
          sessionStore: fixture.storeRoot.path, scope: .user)
        recoveryStarted.signal()
        try service.recoverClaims(workflowName: "flow", root: fixture.storeRoot.path)
      }
    }
    XCTAssertEqual(recoveryStarted.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(recoveryFinished.wait(timeout: .now() + 0.2), .timedOut)
    XCTAssertEqual(try proposals.proposal(id: proposal.proposalId)?.status, .applying)
    try CLIRuntimeEnvironment.$overrides.withValue(environment) {
      let service = WorkflowRegressionRollbackService(workingDirectory: fixture.root.path,
        sessionStore: fixture.storeRoot.path, scope: .user)
      XCTAssertThrowsError(try service.reject(workflowName: "flow", proposalId: proposal.proposalId,
        reason: "declined", actor: .init(kind: .user))) {
        XCTAssertEqual(($0 as? WorkflowRegressionRollbackError)?.code, "rollback_in_progress")
      }
      XCTAssertThrowsError(try fixture.store.moveHead(workflowName: "flow", direction: .undo, reason: "undo",
        expectedRevision: nil, expectedVersionId: head.currentVersionId, evidence: [], actorKind: "user", actorId: nil)) {
        XCTAssertEqual(($0 as? WorkflowDefinitionStoreError)?.code, .rollbackInProgress)
      }
      XCTAssertEqual(try fixture.store.head(workflowName: "flow")?.currentVersionId, head.currentVersionId)
    }
    resume.signal()
    try await writer.value
    try await recovery.value
    XCTAssertEqual(try proposals.proposal(id: proposal.proposalId)?.status, .applied)
  }

  func testInterruptedAttributedPublicationReleasesRollbackClaim() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      _ = try fixture.service.register(input: fixture.input, overwrite: false, workingDirectory: fixture.root.path)
      let head = try XCTUnwrap(fixture.store.head(workflowName: "flow"))
      let proposals = WorkflowRollbackProposalStore(rootDirectory: fixture.storeRoot.path)
      let proposal = try proposals.insertIfAbsent(.init(workflowName: "flow", regressedVersionId: head.currentVersionId,
        rollbackToVersionId: head.currentVersionId, mode: .bundle, baselineSessionId: "baseline", targetSessionId: "target",
        regressions: [], policy: .approvalRequired, status: .pending, createdActor: .init(kind: .user))).proposal
      let recorder = WorkflowDefinitionChangeRecorder(sessionStoreRoot: fixture.storeRoot.path,
        workingDirectory: fixture.root.path,
        fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
      let registry = WorkflowMutableRegistry(hooks: .init(afterPhase: { phase in
        if phase == .prepared { throw CLIUsageError("interrupted") }
      }), definitionRecorder: recorder)
      let digest = try registry.withWorkflowPinnedAccess(workflowId: "flow") { pinned in
        try registry.bundleDigest(at: registry.root.appendingPathComponent("flow"), pinned: XCTUnwrap(pinned))
      }
      let attribution = WorkflowDefinitionChangeAttribution(operation: .rollback, actor: .init(kind: .user),
        reason: "rollback", rollbackProposalId: proposal.proposalId)
      XCTAssertThrowsError(try registry.withWorkflowMutationAccess(workflowId: "flow", expectedDigest: digest,
        attribution: attribution, beforePublication: { transactionId in
          _ = try proposals.claim(proposalId: proposal.proposalId, expectedHeadVersionId: head.currentVersionId,
            claimTransactionId: transactionId)
        }, { workspace, publish in
          try "replacement".write(to: workspace.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
          try publish(workspace)
        }))
      XCTAssertEqual(try proposals.proposal(id: proposal.proposalId)?.status, .pending)
      XCTAssertEqual(try String(contentsOf: registry.root.appendingPathComponent("flow/prompts/p.md"), encoding: .utf8), "original")
    }
  }

  func testRecorderlessRestoredBackupPreservesRollbackClaimForReplay() throws {
    let fixture = try makeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": fixture.home.path]) {
      _ = try fixture.service.register(input: fixture.input, overwrite: false, workingDirectory: fixture.root.path)
      let head = try XCTUnwrap(fixture.store.head(workflowName: "flow"))
      let proposals = WorkflowRollbackProposalStore(rootDirectory: fixture.storeRoot.path)
      let proposal = try proposals.insertIfAbsent(.init(workflowName: "flow", regressedVersionId: head.currentVersionId,
        rollbackToVersionId: head.currentVersionId, mode: .bundle, baselineSessionId: "baseline", targetSessionId: "target",
        regressions: [], policy: .approvalRequired, status: .pending, createdActor: .init(kind: .user))).proposal
      let base = WorkflowDefinitionChangeRecorder(sessionStoreRoot: fixture.storeRoot.path, workingDirectory: fixture.root.path,
        fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
      let interruption = RecoveryInterruption()
      let registry = WorkflowMutableRegistry(hooks: .init(afterPhase: { phase in
        if phase == .prepared { try interruption.interrupt() }
      }, beforeRecordRead: { _ in try interruption.check() }), definitionRecorder: base)
      let digest = try registry.withWorkflowPinnedAccess(workflowId: "flow") { pinned in
        try registry.bundleDigest(at: registry.root.appendingPathComponent("flow"), pinned: XCTUnwrap(pinned))
      }
      let attribution = WorkflowDefinitionChangeAttribution(operation: .rollback, actor: .init(kind: .user),
        reason: "rollback", rollbackProposalId: proposal.proposalId)
      XCTAssertThrowsError(try registry.withWorkflowMutationAccess(workflowId: "flow", expectedDigest: digest,
        attribution: attribution, beforePublication: { transactionId in
          _ = try proposals.claim(proposalId: proposal.proposalId, expectedHeadVersionId: head.currentVersionId,
            claimTransactionId: transactionId)
        }, { workspace, publish in
          try "replacement".write(to: workspace.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
          try publish(workspace)
        }))
      let recordURL = registry.root.appendingPathComponent(".registry-state/transactions/flow.json")
      var record = try JSONDecoder().decode(WorkflowMutableRegistryTransaction.self, from: Data(contentsOf: recordURL))
      let backup = registry.root.appendingPathComponent(try XCTUnwrap(record.backupPath))
      try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: registry.root.appendingPathComponent("flow"), to: backup)
      record.phase = .originalBackedUp
      try JSONEncoder().encode(record).write(to: recordURL)
      try WorkflowMutableRegistry().withWorkflowPinnedAccess(workflowId: "flow") { _ in
        XCTAssertTrue(FileManager.default.fileExists(atPath: registry.root.appendingPathComponent("flow/workflow.json").path))
      }
      XCTAssertEqual(try proposals.proposal(id: proposal.proposalId)?.status, .applying)
      XCTAssertEqual(try JSONDecoder().decode(WorkflowMutableRegistryTransaction.self, from: Data(contentsOf: recordURL)).phase, .prepared)
      try WorkflowMutableRegistry(definitionRecorder: base).recoverWorkflow(workflowId: "flow")
      XCTAssertEqual(try proposals.proposal(id: proposal.proposalId)?.status, .pending)
      XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))
    }
  }

  private func makeBundleProposal(fixture: Fixture, targetImproved: Bool) throws -> (WorkflowRollbackProposal, WorkflowDefinitionVersion) {
    _ = try fixture.service.register(input: fixture.input, overwrite: false, workingDirectory: fixture.root.path)
    let initial = try XCTUnwrap(fixture.store.current(workflowName: "flow"))
    let recorder = WorkflowDefinitionChangeRecorder(sessionStoreRoot: fixture.storeRoot.path, workingDirectory: fixture.root.path,
      fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
    let registry = WorkflowMutableRegistry(definitionRecorder: recorder)
    let digest = try registry.withWorkflowPinnedAccess(workflowId: "flow") { pinned in
      try registry.bundleDigest(at: registry.root.appendingPathComponent("flow"), pinned: XCTUnwrap(pinned))
    }
    let attribution = WorkflowDefinitionChangeAttribution(operation: .selfImprove, actor: .init(kind: .cli), reason: "improve")
    _ = try registry.withWorkflowMutationAccess(workflowId: "flow", expectedDigest: digest, attribution: attribution) { workspace, publish in
      try "improved".write(to: workspace.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
      try publish(workspace)
    }
    let improved = try XCTUnwrap(fixture.store.current(workflowName: "flow"))
    let audit = try XCTUnwrap(fixture.store.audit(forVersionId: improved.version.versionId))
    let snapshot = try XCTUnwrap(audit.evidence.first { $0.kind == .bundleSnapshotBefore }?.id)
    let proposal = try WorkflowRollbackProposalStore(rootDirectory: fixture.storeRoot.path).insertIfAbsent(.init(
      workflowName: "flow", regressedVersionId: improved.version.versionId,
      rollbackToVersionId: targetImproved ? improved.version.versionId : initial.version.versionId,
      mode: .bundle, bundleSnapshotId: snapshot, baselineSessionId: "base", targetSessionId: "target", regressions: [],
      policy: .approvalRequired, status: .pending, createdActor: .init(kind: .system))).proposal
    return (proposal, improved.version)
  }

  private struct Fixture {
    let root: URL
    var home: URL { root.appendingPathComponent("home") }
    var input: URL { root.appendingPathComponent("flow") }
    var storeRoot: URL { root.appendingPathComponent("store") }
    var store: WorkflowDefinitionStore { WorkflowDefinitionStore(rootDirectory: storeRoot.path) }
    var service: WorkflowRegistryService {
      WorkflowRegistryService(definitionStoreRoot: storeRoot.path, workingDirectory: root.path,
        definitionActor: .init(kind: .cli, id: "test"), surfaceLabel: "test", fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
    }
  }

  private func makeFixture() throws -> Fixture {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/workflow-history-unification/whu-08-rollback-service/fixture-\(UUID().uuidString)")
    let fixture = Fixture(root: root)
    try FileManager.default.createDirectory(at: fixture.input.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: fixture.input.appendingPathComponent("prompts"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: fixture.home, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    try """
    {"workflowId":"flow","defaults":{"maxLoopIterations":3,"nodeTimeoutMs":120000},"entryStepId":"first",
    "nodeRegistry":[{"id":"worker","nodeFile":"nodes/worker.json"}],
    "steps":[{"id":"first","nodeId":"worker","role":"worker"}],
    "nodes":[{"id":"worker","nodeFile":"nodes/worker.json"}]}
    """.write(to: fixture.input.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {"id":"worker","executionBackend":"codex-agent","agentSandbox":"workspace-write","model":"model","promptTemplateFile":"prompts/p.md","variables":{}}
    """.write(to: fixture.input.appendingPathComponent("nodes/worker.json"), atomically: true, encoding: .utf8)
    try "original".write(to: fixture.input.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
    return fixture
  }
}

private final class FailOnceRecorder: WorkflowDefinitionChangeRecording, @unchecked Sendable {
  private let base: WorkflowDefinitionChangeRecorder
  private let lock = NSLock()
  private var shouldFail = true
  private let failDelete: Bool

  init(base: WorkflowDefinitionChangeRecorder, failDelete: Bool = false) { self.base = base; self.failDelete = failDelete }
  func storeRoot(workflowName: String, sourceScope: WorkflowScope) throws -> String {
    try base.storeRoot(workflowName: workflowName, sourceScope: sourceScope)
  }
  func captureBaselineIfAbsent(workflowName: String, liveDirectory: URL, sourceScope: WorkflowScope,
                               transactionId: String, actor: WorkflowDefinitionActor, operation: WorkflowDefinitionOperation,
                               bundleSnapshotBefore: String?) throws -> WorkflowDefinitionBaselineOutcome? {
    try base.captureBaselineIfAbsent(workflowName: workflowName, liveDirectory: liveDirectory, sourceScope: sourceScope,
      transactionId: transactionId, actor: actor, operation: operation, bundleSnapshotBefore: bundleSnapshotBefore)
  }
  func prepareIntent(workflowName: String, stagingDirectory: URL, liveDirectory: URL, sourceScope: WorkflowScope,
                     transactionId: String, expectedAfterBundleDigest: String?, bundleSnapshotBefore: String?, bundleSnapshotAfter: String?,
                     attribution: WorkflowDefinitionChangeAttribution) throws -> WorkflowDefinitionSyncIntent {
    try base.prepareIntent(workflowName: workflowName, stagingDirectory: stagingDirectory, liveDirectory: liveDirectory,
      sourceScope: sourceScope, transactionId: transactionId, expectedAfterBundleDigest: expectedAfterBundleDigest,
      bundleSnapshotBefore: bundleSnapshotBefore, bundleSnapshotAfter: bundleSnapshotAfter, attribution: attribution)
  }
  func sync(_ intent: WorkflowDefinitionSyncIntent) throws -> WorkflowDefinitionSyncOutcome {
    lock.lock()
    let fail = shouldFail
    shouldFail = false
    lock.unlock()
    if fail { throw CLIUsageError("injected sync failure") }
    return try base.sync(intent)
  }
  func recordDelete(workflowName: String, sourceScope: WorkflowScope, transactionId: String,
                    bundleSnapshotBefore: String?, attribution: WorkflowDefinitionChangeAttribution) throws -> WorkflowDefinitionSyncOutcome {
    lock.lock()
    let fail = failDelete && shouldFail
    if fail { shouldFail = false }
    lock.unlock()
    if fail { throw CLIUsageError("injected delete failure") }
    return try base.recordDelete(workflowName: workflowName, sourceScope: sourceScope, transactionId: transactionId,
      bundleSnapshotBefore: bundleSnapshotBefore, attribution: attribution)
  }
}

private final class RecoveryInterruption: @unchecked Sendable {
  private let lock = NSLock()
  private var interrupted = false
  func interrupt() throws { lock.lock(); interrupted = true; lock.unlock(); throw CLIUsageError("interrupted") }
  func check() throws { lock.lock(); let fail = interrupted; lock.unlock(); if fail { throw CLIUsageError("crash") } }
}
