import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class WorkflowHistoryAdversarialTests: XCTestCase {
  func testSameTargetDifferentHistoryRootsShareOneCanonicalLock() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveVersioningTarget(root: root)
    let inventory = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: inventory)
    let otherHistory = root.appendingPathComponent("alternate-history/versioned-flow", isDirectory: true)
    let held = try acquireWorkflowTargetLock(target: resolved.identity, owner: "first-history")
    defer { releaseWorkflowTargetLock(held) }

    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator().commit(
      target: resolved.identity,
      historyRoot: otherHistory,
      kind: .apply,
      expectedBeforeBundleDigest: inventory.bundleDigest,
      expectedAfterBundleDigest: inventory.bundleDigest,
      preOperationSnapshotId: snapshot.snapshotId
    ) { _ in }) { error in
      XCTAssertTrue(String(describing: error).contains("locked by another"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: otherHistory.appendingPathComponent("transactions").path))
    let attempts = try FileManager.default.contentsOfDirectory(
      at: otherHistory.appendingPathComponent("attempts"),
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }
    XCTAssertEqual(attempts.count, 1)
    let attempt = try WorkflowHistorySecurePersistence.readCanonical(
      WorkflowPreflightAttemptRecord.self,
      from: try XCTUnwrap(attempts.first),
      historyRoot: otherHistory
    )
    XCTAssertEqual(attempt.status, .failed)
    XCTAssertFalse(attempt.mutationOccurred)
  }

  func testPinnedRecordGenerationRefusesAncestorRedirection() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveVersioningTarget(root: root)
    let inventory = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: inventory)
    let transactions = resolved.historyRoot.appendingPathComponent("transactions", isDirectory: true)
    let logical = transactions.appendingPathComponent("transaction-ancestor-swap.json")
    let live = URL(fileURLWithPath: resolved.identity.ownershipRoot)
    let record = WorkflowDirectoryTransactionRecord(
      transactionId: "transaction-ancestor-swap",
      kind: .apply,
      target: resolved.identity,
      beforeBundleDigest: inventory.bundleDigest,
      expectedAfterBundleDigest: inventory.bundleDigest,
      preOperationSnapshotId: snapshot.snapshotId,
      beforeUnownedInventory: inventory.unownedFiles.map(WorkflowUnownedInventoryEntry.init),
      expectedAfterUnownedInventory: inventory.unownedFiles.map(WorkflowUnownedInventoryEntry.init),
      operationAuditIntent: .mutation(LoopWorkflowMutationEvidence(
        mode: "ancestor-swap-test",
        snapshotId: snapshot.snapshotId,
        transactionId: "transaction-ancestor-swap",
        target: resolved.identity,
        beforeBundleDigest: inventory.bundleDigest,
        afterBundleDigest: inventory.bundleDigest,
        applied: false,
        restored: false,
        outcome: .failed
      )),
      stagingPath: live.deletingLastPathComponent().appendingPathComponent(
        ".\(live.lastPathComponent).riela-stage-transaction-ancestor-swap"
      ).path,
      rollbackPath: live.deletingLastPathComponent().appendingPathComponent(
        ".\(live.lastPathComponent).riela-rollback-transaction-ancestor-swap"
      ).path,
      phase: .preparing
    )
    let displaced = resolved.historyRoot.deletingLastPathComponent().appendingPathComponent("history-displaced")
    try WorkflowTransactionGenerationStore.write(
      record,
      logicalURL: logical,
      historyRoot: resolved.historyRoot
    ) {
      try FileManager.default.moveItem(at: resolved.historyRoot, to: displaced)
      try FileManager.default.createDirectory(at: resolved.historyRoot, withIntermediateDirectories: true)
    }

    XCTAssertFalse(FileManager.default.fileExists(
      atPath: resolved.historyRoot.appendingPathComponent("transactions").path
    ))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: displaced.appendingPathComponent("transactions/transaction-ancestor-swap.json.generations").path
    ))
  }

  func testPinnedSnapshotAndProposalPublicationRefuseAncestorRedirection() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveVersioningTarget(root: root)
    let inventory = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshotDisplaced = resolved.historyRoot.deletingLastPathComponent().appendingPathComponent("snapshot-displaced")
    let snapshotStore = WorkflowHistoryStore(root: resolved.historyRoot) {
      try FileManager.default.moveItem(at: resolved.historyRoot, to: snapshotDisplaced)
      try FileManager.default.createDirectory(at: resolved.historyRoot, withIntermediateDirectories: true)
    }
    XCTAssertThrowsError(try snapshotStore.createSnapshot(inventory: inventory, snapshotId: "snapshot-ancestor-swap"))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: resolved.historyRoot.appendingPathComponent("snapshots/snapshot-ancestor-swap").path
    ))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: snapshotDisplaced.appendingPathComponent("snapshots/snapshot-ancestor-swap").path
    ))

    try FileManager.default.removeItem(at: resolved.historyRoot)
    try FileManager.default.moveItem(at: snapshotDisplaced, to: resolved.historyRoot)
    let proposalDisplaced = resolved.historyRoot.deletingLastPathComponent().appendingPathComponent("proposal-displaced")
    var proposal = WorkflowChangeProposal(
      proposalId: "proposal-ancestor-swap",
      sourceSessionId: "session-ancestor-swap",
      target: resolved.identity,
      beforeBundleDigest: inventory.bundleDigest,
      operations: [],
      expectedAfterBundleDigest: inventory.bundleDigest,
      rationale: "descriptor-relative publication",
      createdAt: Date(timeIntervalSince1970: 0),
      proposalDigest: String(repeating: "0", count: 64)
    )
    proposal.proposalDigest = try WorkflowHistoryCanonicalCoding.proposalDigest(proposal)
    let proposalStore = WorkflowChangeSetStore(root: resolved.historyRoot) {
      try FileManager.default.moveItem(at: resolved.historyRoot, to: proposalDisplaced)
      try FileManager.default.createDirectory(at: resolved.historyRoot, withIntermediateDirectories: true)
    }
    XCTAssertThrowsError(try proposalStore.publishProposal(proposal, contentObjects: [:]))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: resolved.historyRoot.appendingPathComponent("proposals/proposal-ancestor-swap").path
    ))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: proposalDisplaced.appendingPathComponent("proposals/proposal-ancestor-swap").path
    ))
  }

  func testPinnedTargetLockRefusesAncestorRedirection() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveVersioningTarget(root: root)
    let lock = workflowTargetLockURL(target: resolved.identity)
    try? FileManager.default.removeItem(at: lock)
    let parent = lock.deletingLastPathComponent()
    let displaced = parent.deletingLastPathComponent().appendingPathComponent(
      "\(parent.lastPathComponent)-displaced-\(UUID().uuidString.lowercased())"
    )
    let descriptor = try acquireWorkflowTargetLock(target: resolved.identity, owner: "ancestor-swap") {
      try FileManager.default.moveItem(at: parent, to: displaced)
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.appendingPathComponent(lock.lastPathComponent).path))
    releaseWorkflowTargetLock(descriptor)
    try FileManager.default.removeItem(at: parent)
    try FileManager.default.removeItem(at: displaced)
  }

  func testOrphanAndMultipleNonterminalRecordsAreDiscoveredFailClosed() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveVersioningTarget(root: root)
    let inventory = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: inventory)
    let coordinator = WorkflowDirectoryTransactionCoordinator(
      auditStore: FileWorkflowTransactionAuditStore(),
      boundaryHook: { boundary in
        if boundary == .transactionRecord { throw WorkflowDirectoryInjectedInterruption(boundary: boundary) }
      }
    )
    XCTAssertThrowsError(try coordinator.commit(
      target: resolved.identity,
      historyRoot: resolved.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: inventory.bundleDigest,
      expectedAfterBundleDigest: inventory.bundleDigest,
      preOperationSnapshotId: snapshot.snapshotId
    ) { _ in })
    let transactions = resolved.historyRoot.appendingPathComponent("transactions", isDirectory: true)
    let originalGenerations = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
      at: transactions,
      includingPropertiesForKeys: nil
    ).first { $0.lastPathComponent.hasSuffix(".json.generations") })
    let originalURL = transactions.appendingPathComponent(
      String(originalGenerations.lastPathComponent.dropLast(".generations".count))
    )
    var duplicate = try WorkflowHistorySecurePersistence.readCanonical(
      WorkflowDirectoryTransactionRecord.self,
      from: originalURL,
      historyRoot: resolved.historyRoot
    )
    duplicate.transactionId = "transaction-ambiguous"
    let live = URL(fileURLWithPath: duplicate.target.ownershipRoot)
    duplicate.stagingPath = live.deletingLastPathComponent()
      .appendingPathComponent(".\(live.lastPathComponent).riela-stage-\(duplicate.transactionId)").path
    duplicate.rollbackPath = live.deletingLastPathComponent()
      .appendingPathComponent(".\(live.lastPathComponent).riela-rollback-\(duplicate.transactionId)").path
    switch duplicate.operationAuditIntent {
    case var .mutation(evidence):
      evidence.transactionId = duplicate.transactionId
      duplicate.operationAuditIntent = .mutation(evidence)
    case .restore:
      XCTFail("expected apply audit intent")
    }
    try WorkflowTransactionGenerationStore.write(
      duplicate,
      logicalURL: transactions.appendingPathComponent("\(duplicate.transactionId).json"),
      historyRoot: resolved.historyRoot,
      betweenPayloadAndSidecar: {}
    )

    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator().recover(
      historyRoot: resolved.historyRoot,
      target: resolved.identity
    )) { error in
      XCTAssertTrue(String(describing: error).contains("multiple nonterminal"), String(describing: error))
    }
  }

  func testAutoScopeDoesNotRetargetAfterCorruptProjectTransaction() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveVersioningTarget(root: root)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let userWorkflow = home.appendingPathComponent(".riela/workflows/versioned-flow", isDirectory: true)
    try FileManager.default.createDirectory(at: userWorkflow.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: resolved.identity.ownershipRoot), to: userWorkflow)
    let inventory = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: inventory)
    let coordinator = WorkflowDirectoryTransactionCoordinator(
      auditStore: FileWorkflowTransactionAuditStore(),
      boundaryHook: { boundary in
        if boundary == .transactionRecord { throw WorkflowDirectoryInjectedInterruption(boundary: boundary) }
      }
    )
    XCTAssertThrowsError(try coordinator.commit(
      target: resolved.identity,
      historyRoot: resolved.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: inventory.bundleDigest,
      expectedAfterBundleDigest: inventory.bundleDigest,
      preOperationSnapshotId: snapshot.snapshotId
    ) { _ in })
    let generations = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
      at: resolved.historyRoot.appendingPathComponent("transactions"),
      includingPropertiesForKeys: nil
    ).first { $0.lastPathComponent.hasSuffix(".json.generations") })
    let generation = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
      at: generations,
      includingPropertiesForKeys: nil
    ).first { !$0.lastPathComponent.hasPrefix(".") })
    let payload = generation.appendingPathComponent("record.json")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: payload.path)
    try Data("corrupt".utf8).write(to: payload)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: payload.path)

    let response = await CLIRuntimeEnvironment.$overrides.withValue(["HOME": home.path]) {
      await RielaCLIApplication().run([
        "workflow", "validate", "versioned-flow", "--scope", "auto",
        "--working-dir", root.path, "--output", "json"
      ])
    }
    XCTAssertNotEqual(response.exitCode, .success)
    XCTAssertTrue((response.stdout + response.stderr).contains("transaction recovery failed"))
  }

  func testConcurrentSameIdentifierPublicationNeverOverwrites() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveVersioningTarget(root: root)
    let inventory = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    async let firstSnapshot = Self.publishSnapshot(inventory, root: resolved.historyRoot, id: "snapshot-concurrent")
    async let secondSnapshot = Self.publishSnapshot(inventory, root: resolved.historyRoot, id: "snapshot-concurrent")
    let snapshotOutcomes = await (firstSnapshot, secondSnapshot)
    XCTAssertEqual([snapshotOutcomes.0, snapshotOutcomes.1].filter { $0 }.count, 1)
    _ = try WorkflowHistoryStore(root: resolved.historyRoot).loadSnapshot(
      "snapshot-concurrent",
      expectedIdentity: resolved.identity
    )

    var proposal = WorkflowChangeProposal(
      proposalId: "proposal-concurrent",
      sourceSessionId: "session-concurrent",
      target: resolved.identity,
      beforeBundleDigest: inventory.bundleDigest,
      operations: [],
      expectedAfterBundleDigest: inventory.bundleDigest,
      rationale: "concurrency fixture",
      createdAt: Date(timeIntervalSince1970: 0),
      proposalDigest: String(repeating: "0", count: 64)
    )
    proposal.proposalDigest = try WorkflowHistoryCanonicalCoding.proposalDigest(proposal)
    let firstProposalValue = proposal
    let secondProposalValue = proposal
    async let firstProposal = Self.publishProposal(firstProposalValue, root: resolved.historyRoot)
    async let secondProposal = Self.publishProposal(secondProposalValue, root: resolved.historyRoot)
    let proposalOutcomes = await (firstProposal, secondProposal)
    XCTAssertEqual([proposalOutcomes.0, proposalOutcomes.1].filter { $0 }.count, 1)
    XCTAssertEqual(
      try WorkflowChangeSetStore(root: resolved.historyRoot).loadProposal(
        proposal.proposalId,
        expectedIdentity: resolved.identity
      ),
      proposal
    )

    let recordURL = resolved.historyRoot.appendingPathComponent("audits/concurrent-record.json")
    async let firstRecord = Self.publishRecord(Data("first".utf8), to: recordURL, root: resolved.historyRoot)
    async let secondRecord = Self.publishRecord(Data("second".utf8), to: recordURL, root: resolved.historyRoot)
    let recordOutcomes = await (firstRecord, secondRecord)
    XCTAssertEqual([recordOutcomes.0, recordOutcomes.1].filter { $0 }.count, 1)
    let persisted = try WorkflowHistorySecurePersistence.readPersistedBytes(
      from: recordURL,
      historyRoot: resolved.historyRoot
    )
    XCTAssertTrue(persisted == Data("first".utf8) || persisted == Data("second".utf8))
  }

  private static func publishSnapshot(_ inventory: WorkflowBundleInventory, root: URL, id: String) -> Bool {
    (try? WorkflowHistoryStore(root: root).createSnapshot(inventory: inventory, snapshotId: id)) != nil
  }

  private static func publishProposal(_ proposal: WorkflowChangeProposal, root: URL) -> Bool {
    do {
      try WorkflowChangeSetStore(root: root).publishProposal(proposal, contentObjects: [:])
      return true
    } catch {
      return false
    }
  }

  private static func publishRecord(_ bytes: Data, to url: URL, root: URL) -> Bool {
    do {
      try WorkflowHistorySecurePersistence.writePersistedBytes(bytes, to: url, historyRoot: root, overwrite: false)
      return true
    } catch {
      return false
    }
  }
}
