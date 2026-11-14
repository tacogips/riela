import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class WorkflowRound8AdversarialTests: XCTestCase {
  func testCommittedRecoveryRejectsMissingOperationAuditBeforeCleanup() async throws {
    let fixture = try await committedFixture()
    try removePersistedPair(operationAuditURL(fixture))
    try assertRecoveryFailsClosed(fixture)
  }

  func testCommittedRecoveryRejectsMissingTransactionAuditBeforeCleanup() async throws {
    let fixture = try await committedFixture()
    try removePersistedPair(transactionAuditURL(fixture))
    try assertRecoveryFailsClosed(fixture)
  }

  func testCommittedRecoveryRejectsCorruptOperationAuditBeforeCleanup() async throws {
    let fixture = try await committedFixture()
    try corruptPersistedRecord(operationAuditURL(fixture))
    try assertRecoveryFailsClosed(fixture)
  }

  func testCommittedRecoveryRejectsCorruptTransactionAuditBeforeCleanup() async throws {
    let fixture = try await committedFixture()
    try corruptPersistedRecord(transactionAuditURL(fixture))
    try assertRecoveryFailsClosed(fixture)
  }

  func testCommittedRecoveryRejectsFieldMismatchedOperationAuditBeforeCleanup() async throws {
    let fixture = try await committedFixture()
    let url = operationAuditURL(fixture)
    var evidence = try WorkflowHistorySecurePersistence.readCanonical(
      LoopWorkflowMutationEvidence.self,
      from: url,
      historyRoot: fixture.historyRoot
    )
    evidence.mode = "field-mismatch"
    try rewritePersistedPair(evidence, at: url)
    try assertRecoveryFailsClosed(fixture)
  }

  func testCommittedRecoveryRejectsFieldMismatchedTransactionAuditBeforeCleanup() async throws {
    let fixture = try await committedFixture()
    let url = transactionAuditURL(fixture)
    var audit = try WorkflowHistorySecurePersistence.readCanonical(
      WorkflowDirectoryTransactionAudit.self,
      from: url,
      historyRoot: fixture.historyRoot
    )
    audit.resultBundleDigest = String(repeating: "0", count: 64)
    try rewritePersistedPair(audit, at: url)
    try assertRecoveryFailsClosed(fixture)
  }

  func testStableMarkerCleanupUsesPinnedParentAcrossAncestorSwap() async throws {
    let fixture = try await transactionFixture()
    let parent = URL(fileURLWithPath: fixture.target.ownershipRoot).deletingLastPathComponent()
    let held = parent.deletingLastPathComponent().appendingPathComponent("held-stable-parent")
    let replacement = parent
    let coordinator = WorkflowDirectoryTransactionCoordinator(
      auditStore: FileWorkflowTransactionAuditStore(),
      boundaryHook: { boundary in
        guard boundary == .stableMarkerUnlink else { return }
        try FileManager.default.moveItem(at: parent, to: held)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: replacement.appendingPathComponent("sentinel"))
      }
    )
    _ = try commitNoOp(fixture, coordinator: coordinator)
    let retainedMarker = WorkflowTransactionStableMetadata.url(
      forOwnershipRoot: held.appendingPathComponent(URL(fileURLWithPath: fixture.target.ownershipRoot).lastPathComponent)
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: retainedMarker.path))
    XCTAssertEqual(try Data(contentsOf: replacement.appendingPathComponent("sentinel")), Data("replacement".utf8))
  }

  func testActiveMarkerCleanupUsesPinnedParentAcrossAncestorSwap() async throws {
    let fixture = try await transactionFixture()
    let transactions = fixture.historyRoot.appendingPathComponent("transactions", isDirectory: true)
    let held = fixture.historyRoot.appendingPathComponent("held-transactions", isDirectory: true)
    let coordinator = WorkflowDirectoryTransactionCoordinator(
      auditStore: FileWorkflowTransactionAuditStore(),
      boundaryHook: { boundary in
        guard boundary == .activeMarkerUnlink else { return }
        try FileManager.default.moveItem(at: transactions, to: held)
        try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: transactions.appendingPathComponent("sentinel"))
      }
    )
    _ = try commitNoOp(fixture, coordinator: coordinator)
    XCTAssertFalse(FileManager.default.fileExists(atPath: held.appendingPathComponent("active.json").path))
    XCTAssertEqual(try Data(contentsOf: transactions.appendingPathComponent("sentinel")), Data("replacement".utf8))
  }

  func testSnapshotConstructionRejectsChildDirectorySwap() async throws {
    let fixture = try await transactionFixture()
    let snapshots = fixture.historyRoot.appendingPathComponent("snapshots", isDirectory: true)
    let outside = fixture.historyRoot.appendingPathComponent("outside-snapshot", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let hook = OneShotConstructionHook(boundary: .childDirectory) {
      let temporary = try round8TemporaryDirectory(in: snapshots)
      try FileManager.default.moveItem(
        at: temporary.appendingPathComponent("objects"),
        to: temporary.appendingPathComponent("objects-held")
      )
      try FileManager.default.createSymbolicLink(
        at: temporary.appendingPathComponent("objects"),
        withDestinationURL: outside
      )
    }
    XCTAssertThrowsError(try WorkflowHistoryStore(
      root: fixture.historyRoot,
      beforePublication: {},
      constructionHook: hook.call
    ).createSnapshot(inventory: fixture.inventory, snapshotId: "snapshot-child-swap"))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  func testSnapshotConstructionRejectsLeafSwapBeforeVerification() async throws {
    let fixture = try await transactionFixture()
    let snapshots = fixture.historyRoot.appendingPathComponent("snapshots", isDirectory: true)
    try assertLeafSwapFails(parent: snapshots, leaf: "manifest.json") { hook in
      try WorkflowHistoryStore(
        root: fixture.historyRoot,
        beforePublication: {},
        constructionHook: hook
      ).createSnapshot(inventory: fixture.inventory, snapshotId: "snapshot-leaf-swap")
    }
  }

  func testProposalConstructionRejectsChildDirectorySwap() async throws {
    let fixture = try await transactionFixture()
    let proposal = try noOpProposal(fixture, id: "proposal-child-swap")
    let proposals = fixture.historyRoot.appendingPathComponent("proposals", isDirectory: true)
    let outside = fixture.historyRoot.appendingPathComponent("outside-proposal", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let hook = OneShotConstructionHook(boundary: .childDirectory) {
      let temporary = try round8TemporaryDirectory(in: proposals)
      try FileManager.default.moveItem(
        at: temporary.appendingPathComponent("objects"),
        to: temporary.appendingPathComponent("objects-held")
      )
      try FileManager.default.createSymbolicLink(
        at: temporary.appendingPathComponent("objects"),
        withDestinationURL: outside
      )
    }
    XCTAssertThrowsError(try WorkflowChangeSetStore(
      root: fixture.historyRoot,
      beforePublication: {},
      constructionHook: hook.call
    ).publishProposal(proposal, contentObjects: [:]))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  func testProposalConstructionRejectsLeafSwapBeforeVerification() async throws {
    let fixture = try await transactionFixture()
    let proposal = try noOpProposal(fixture, id: "proposal-leaf-swap")
    let proposals = fixture.historyRoot.appendingPathComponent("proposals", isDirectory: true)
    try assertLeafSwapFails(parent: proposals, leaf: "proposal.json") { hook in
      try WorkflowChangeSetStore(
        root: fixture.historyRoot,
        beforePublication: {},
        constructionHook: hook
      ).publishProposal(proposal, contentObjects: [:])
    }
  }

  func testChangeSetConstructionRejectsLeafSwapBeforeVerification() async throws {
    let fixture = try await transactionFixture()
    let proposal = try noOpProposal(fixture, id: "proposal-for-change-set-swap")
    let store = WorkflowChangeSetStore(root: fixture.historyRoot)
    try store.publishProposal(proposal, contentObjects: [:])
    let changeSets = fixture.historyRoot.appendingPathComponent("change-sets", isDirectory: true)
    let review = acceptedReview(proposal)
    try assertLeafSwapFails(parent: changeSets, leaf: "change-set.json") { hook in
      _ = try WorkflowChangeSetStore(
        root: fixture.historyRoot,
        beforePublication: {},
        constructionHook: hook
      ).finalize(
        proposalId: proposal.proposalId,
        expectedIdentity: fixture.target,
        review: review,
        changeSetId: "change-set-leaf-swap"
      )
    }
  }

  func testRuntimeGateConstructionRejectsParentSwap() async throws {
    let fixture = try await transactionFixture()
    let gateResults = fixture.historyRoot.appendingPathComponent("gate-results", isDirectory: true)
    let held = fixture.historyRoot.appendingPathComponent("gate-results-held", isDirectory: true)
    let outside = fixture.historyRoot.appendingPathComponent("outside-gate-results", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let hook = OneShotConstructionHook(boundary: .childDirectory) {
      try FileManager.default.moveItem(at: gateResults, to: held)
      try FileManager.default.createSymbolicLink(at: gateResults, withDestinationURL: outside)
    }
    XCTAssertThrowsError(try WorkflowRuntimeGateEvidenceStore(
      root: fixture.historyRoot,
      constructionHook: hook.call
    ).publish(gateEvidence(id: "gate-result-parent-swap")))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  func testRuntimeGateConstructionRejectsLeafSwapBeforeVerification() async throws {
    let fixture = try await transactionFixture()
    let gateResults = fixture.historyRoot.appendingPathComponent("gate-results", isDirectory: true)
    let outside = fixture.historyRoot.appendingPathComponent("outside-gate-leaf")
    let hook = OneShotConstructionHook(boundary: .leafFile) {
      let record = gateResults.appendingPathComponent("gate-result-leaf-swap.json")
      try FileManager.default.removeItem(at: record)
      try FileManager.default.createSymbolicLink(at: record, withDestinationURL: outside)
    }
    XCTAssertThrowsError(try WorkflowRuntimeGateEvidenceStore(
      root: fixture.historyRoot,
      constructionHook: hook.call
    ).publish(gateEvidence(id: "gate-result-leaf-swap")))
    XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
  }

  func testLegacyReconciliationRejectsCommittedToFailedBranch() throws {
    let base = transactionRecord(phase: .committed)
    var failed = base
    failed.phase = .failed
    XCTAssertThrowsError(try reconcileWorkflowTransaction(record: failed, legacyActive: base))
  }

  func testLegacyReconciliationRejectsFailedToRecoveredBranch() throws {
    let base = transactionRecord(phase: .failed)
    var recovered = base
    recovered.phase = .recovered
    XCTAssertThrowsError(try reconcileWorkflowTransaction(record: recovered, legacyActive: base))
  }

  func testLegacyReconciliationRejectsReversedTransition() throws {
    let prepared = transactionRecord(phase: .prepared)
    var preparing = prepared
    preparing.phase = .preparing
    XCTAssertThrowsError(try reconcileWorkflowTransaction(record: preparing, legacyActive: prepared))
  }

  func testLegacyReconciliationRejectsRewrittenEvidence() throws {
    var previous = transactionRecord(phase: .prepared)
    previous.verification = [verification(summary: "original")]
    var next = previous
    next.phase = .committing
    next.verification = [verification(summary: "rewritten")]
    XCTAssertThrowsError(try reconcileWorkflowTransaction(record: next, legacyActive: previous))
  }
}

private extension WorkflowRound8AdversarialTests {
  struct TransactionFixture {
    var target: WorkflowBundleIdentity
    var historyRoot: URL
    var inventory: WorkflowBundleInventory
    var snapshot: WorkflowBundleSnapshotManifest
  }

  struct CommittedFixture {
    var target: WorkflowBundleIdentity
    var historyRoot: URL
    var record: WorkflowDirectoryTransactionRecord
    var active: URL
    var stable: URL
  }

  func transactionFixture() async throws -> TransactionFixture {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveMutableTransactionTarget(root: root)
    let inventory = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: inventory)
    return TransactionFixture(
      target: resolved.identity,
      historyRoot: resolved.historyRoot,
      inventory: inventory,
      snapshot: snapshot
    )
  }

  func committedFixture() async throws -> CommittedFixture {
    let fixture = try await transactionFixture()
    let coordinator = WorkflowDirectoryTransactionCoordinator(
      auditStore: FileWorkflowTransactionAuditStore(),
      boundaryHook: { boundary in
        if boundary == .committedRecord { throw WorkflowDirectoryInjectedInterruption(boundary: boundary) }
      }
    )
    XCTAssertThrowsError(try commitNoOp(fixture, coordinator: coordinator))
    let transactions = fixture.historyRoot.appendingPathComponent("transactions", isDirectory: true)
    let generations = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
      at: transactions,
      includingPropertiesForKeys: nil
    ).first { $0.lastPathComponent.hasSuffix(".json.generations") })
    let transactionId = String(generations.lastPathComponent.dropLast(".json.generations".count))
    let logical = transactions.appendingPathComponent("\(transactionId).json")
    let record = try XCTUnwrap(WorkflowTransactionGenerationStore.readLatest(
      logicalURL: logical,
      historyRoot: fixture.historyRoot
    ))
    XCTAssertEqual(record.phase, .committed)
    return CommittedFixture(
      target: fixture.target,
      historyRoot: fixture.historyRoot,
      record: record,
      active: transactions.appendingPathComponent("active.json"),
      stable: WorkflowTransactionStableMetadata.url(
        forOwnershipRoot: URL(fileURLWithPath: fixture.target.ownershipRoot)
      )
    )
  }

  func commitNoOp(
    _ fixture: TransactionFixture,
    coordinator: WorkflowDirectoryTransactionCoordinator
  ) throws -> WorkflowDirectoryTransactionResult {
    try coordinator.commit(
      target: fixture.target,
      historyRoot: fixture.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: fixture.inventory.bundleDigest,
      expectedAfterBundleDigest: fixture.inventory.bundleDigest,
      preOperationSnapshotId: fixture.snapshot.snapshotId
    ) { _ in }
  }

  func operationAuditURL(_ fixture: CommittedFixture) -> URL {
    fixture.historyRoot.appendingPathComponent("audits/\(fixture.record.transactionId).json")
  }

  func transactionAuditURL(_ fixture: CommittedFixture) -> URL {
    fixture.historyRoot.appendingPathComponent("audits/transaction-\(fixture.record.transactionId).json")
  }

  func assertRecoveryFailsClosed(_ fixture: CommittedFixture) throws {
    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator().recover(
      historyRoot: fixture.historyRoot,
      target: fixture.target
    ))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.record.rollbackPath))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.active.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.stable.path))
  }

  func removePersistedPair(_ url: URL) throws {
    try FileManager.default.removeItem(at: url)
    try FileManager.default.removeItem(at: WorkflowHistorySecurePersistence.digestSidecar(for: url))
  }

  func corruptPersistedRecord(_ url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    try Data("corrupt".utf8).write(to: url)
  }

  func rewritePersistedPair<T: Encodable>(_ value: T, at url: URL) throws {
    let bytes = try WorkflowHistoryCanonicalCoding.encode(value)
    let sidecar = WorkflowHistorySecurePersistence.digestSidecar(for: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sidecar.path)
    try bytes.write(to: url)
    try Data("\(WorkflowHistoryCanonicalCoding.sha256(bytes))\n".utf8).write(to: sidecar)
  }

  func assertLeafSwapFails<T>(
    parent: URL,
    leaf: String,
    operation: (@escaping @Sendable (WorkflowHistoryConstructionBoundary) throws -> Void) throws -> T
  ) throws {
    let outside = parent.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
    let hook = OneShotConstructionHook(boundary: .leafFile) {
      let temporary = try round8TemporaryDirectory(in: parent)
      let target = temporary.appendingPathComponent(leaf)
      try FileManager.default.removeItem(at: target)
      try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
    }
    XCTAssertThrowsError(try operation(hook.call))
    XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
  }

  func noOpProposal(_ fixture: TransactionFixture, id: String) throws -> WorkflowChangeProposal {
    var proposal = WorkflowChangeProposal(
      proposalId: id,
      sourceSessionId: "session-round8",
      target: fixture.target,
      beforeBundleDigest: fixture.inventory.bundleDigest,
      operations: [],
      expectedAfterBundleDigest: fixture.inventory.bundleDigest,
      rationale: "round eight adversarial construction",
      createdAt: Date(timeIntervalSince1970: 0),
      proposalDigest: String(repeating: "0", count: 64)
    )
    proposal.proposalDigest = try WorkflowHistoryCanonicalCoding.proposalDigest(proposal)
    return proposal
  }

  func acceptedReview(_ proposal: WorkflowChangeProposal) -> WorkflowChangeSetReviewEvidence {
    WorkflowChangeSetReviewEvidence(
      gateId: "review-gate",
      gateResultId: "gate-result-round8",
      decision: .accepted,
      reviewedProposalId: proposal.proposalId,
      reviewedProposalDigest: proposal.proposalDigest,
      reviewedBeforeBundleDigest: proposal.beforeBundleDigest,
      reviewerStepId: "review-step",
      reviewerStepExecutionId: "review-execution",
      reviewedAt: Date(timeIntervalSince1970: 0)
    )
  }

  func gateEvidence(id: String) -> WorkflowRuntimeGateEvidence {
    WorkflowRuntimeGateEvidence(
      resultId: id,
      workflowId: "workflow-round8",
      sessionId: "session-round8",
      result: LoopGateResult(
        gateId: "review-gate",
        stepId: "review-step",
        stepExecutionId: "review-execution",
        decision: .accepted
      )
    )
  }

  func transactionRecord(phase: WorkflowDirectoryTransactionPhase) -> WorkflowDirectoryTransactionRecord {
    let target = WorkflowBundleIdentity(
      workflowId: "workflow-round8",
      sourceScope: .project,
      sourceKind: .authoredWorkflow,
      workflowDirectory: "/tmp/workflow-round8",
      ownershipRoot: "/tmp/workflow-round8",
      workflowContractVersion: "1",
      sourceMutable: true
    )
    return WorkflowDirectoryTransactionRecord(
      transactionId: "transaction-round8",
      kind: .apply,
      target: target,
      beforeBundleDigest: String(repeating: "a", count: 64),
      expectedAfterBundleDigest: String(repeating: "b", count: 64),
      preOperationSnapshotId: "snapshot-round8",
      beforeUnownedInventory: [],
      expectedAfterUnownedInventory: [],
      operationAuditIntent: .mutation(LoopWorkflowMutationEvidence(
        mode: "directory-transaction",
        snapshotId: "snapshot-round8",
        transactionId: "transaction-round8",
        target: target,
        beforeBundleDigest: String(repeating: "a", count: 64),
        afterBundleDigest: String(repeating: "b", count: 64),
        applied: true,
        restored: false,
        outcome: .applied
      )),
      stagingPath: "/tmp/.workflow-round8.riela-stage-transaction-round8",
      rollbackPath: "/tmp/.workflow-round8.riela-rollback-transaction-round8",
      phase: phase
    )
  }

  func verification(summary: String) -> LoopVerificationEvidence {
    LoopVerificationEvidence(
      id: "verification-round8",
      commandRef: "swift test",
      evidenceRefs: [],
      outcome: "passed",
      diagnosticSummary: summary
    )
  }
}

private final class OneShotConstructionHook: @unchecked Sendable {
  private let lock = NSLock()
  private let boundary: WorkflowHistoryConstructionBoundary
  private let action: @Sendable () throws -> Void
  private var fired = false

  init(
    boundary: WorkflowHistoryConstructionBoundary,
    action: @escaping @Sendable () throws -> Void
  ) {
    self.boundary = boundary
    self.action = action
  }

  func call(_ observed: WorkflowHistoryConstructionBoundary) throws {
    lock.lock()
    let shouldFire = observed == boundary && !fired
    if shouldFire { fired = true }
    lock.unlock()
    if shouldFire { try action() }
  }
}

private func round8TemporaryDirectory(in parent: URL) throws -> URL {
  guard let temporary = try FileManager.default.contentsOfDirectory(
    at: parent,
    includingPropertiesForKeys: nil
  ).first(where: { $0.lastPathComponent.hasPrefix(".tmp-") }) else {
    throw CLIUsageError("round eight test did not find a private artifact directory")
  }
  return temporary
}
