import Darwin
import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class WorkflowDirectoryTransactionTests: XCTestCase {
  func testNestedWorkflowReferencesResolveFromDeclaringWorkflowDirectory() async throws {
    let (root, created) = try await makeWorkflowVersioningFixture(self)
    let target = try resolveVersioningTarget(root: root).identity
    let workflowURL = URL(fileURLWithPath: created.workflowDirectory).appendingPathComponent("workflow.json")
    var workflow = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workflowURL)) as? [String: Any])
    workflow["nestedWorkflowDirectory"] = "nested"
    try JSONSerialization.data(withJSONObject: workflow, options: [.sortedKeys]).write(to: workflowURL)
    let nested = URL(fileURLWithPath: created.workflowDirectory).appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nested.appendingPathComponent("prompts"), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["nodeFile": "nodes/nested.json"], options: [.sortedKeys])
      .write(to: nested.appendingPathComponent("workflow.json"))
    try JSONSerialization.data(withJSONObject: ["promptTemplateFile": "prompts/nested.txt"], options: [.sortedKeys])
      .write(to: nested.appendingPathComponent("nodes/nested.json"))
    try Data("nested prompt".utf8).write(to: nested.appendingPathComponent("prompts/nested.txt"))

    let inventory = try WorkflowHistoryIdentityResolver.inventory(for: target)

    XCTAssertTrue(inventory.files.map(\.metadata.relativePath).contains("nested/nodes/nested.json"))
    XCTAssertTrue(inventory.files.map(\.metadata.relativePath).contains("nested/prompts/nested.txt"))
  }

  func testMalformedNestedDeclarationAndUnreadableDirectoryFailClosed() async throws {
    let (root, created) = try await makeWorkflowVersioningFixture(self)
    let target = try resolveVersioningTarget(root: root).identity
    let workflowURL = URL(fileURLWithPath: created.workflowDirectory).appendingPathComponent("workflow.json")
    var workflow = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workflowURL)) as? [String: Any])
    workflow["nestedWorkflowDirectory"] = "nested"
    try JSONSerialization.data(withJSONObject: workflow, options: [.sortedKeys]).write(to: workflowURL)
    let nested = URL(fileURLWithPath: created.workflowDirectory).appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("{ malformed".utf8).write(to: nested.appendingPathComponent("workflow.json"))
    XCTAssertThrowsError(try WorkflowHistoryIdentityResolver.inventory(for: target)) { error in
      XCTAssertTrue(String(describing: error).contains("read or parse declaration JSON"))
    }

    try Data("{}".utf8).write(to: nested.appendingPathComponent("workflow.json"))
    let unreadable = URL(fileURLWithPath: created.workflowDirectory).appendingPathComponent("unreadable", isDirectory: true)
    try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
    try Data("secret".utf8).write(to: unreadable.appendingPathComponent("secret.txt"))
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
    XCTAssertThrowsError(try WorkflowHistoryIdentityResolver.inventory(for: target))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path)
  }

  func testHistoryRootMustBeCanonicallyDisjointFromOwnershipRootInBothDirections() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let target = try resolveVersioningTarget(root: root).identity
    XCTAssertThrowsError(try WorkflowHistoryIdentityResolver.historyRoot(
      for: target,
      workingDirectory: root,
      configuredRoot: ".riela/workflows"
    ))
    let directWorkingDirectory = URL(fileURLWithPath: target.ownershipRoot, isDirectory: true)
    XCTAssertThrowsError(try WorkflowHistoryIdentityResolver.historyRoot(
      for: target,
      workingDirectory: directWorkingDirectory,
      configuredRoot: ".history"
    ))
  }

  func testTransactionCommitsCompleteStagedBundleAndRetainsRecord() async throws {
    let (root, created) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveMutableTransactionTarget(root: root)
    let (target, historyRoot) = (resolved.identity, resolved.historyRoot)
    let before = try WorkflowHistoryIdentityResolver.inventory(for: target)
    let workflowPath = URL(fileURLWithPath: created.workflowDirectory).appendingPathComponent("workflow.json")
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workflowPath)) as? [String: Any])
    object["description"] = "transaction-updated"
    let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    let relativePath = "workflow.json"
    var afterFiles = before.files.map(\.metadata)
    let index = try XCTUnwrap(afterFiles.firstIndex(where: { $0.relativePath == relativePath }))
    afterFiles[index].contentDigest = WorkflowHistoryCanonicalCoding.sha256(updated)
    afterFiles[index].byteCount = updated.count
    let expected = try WorkflowHistoryCanonicalCoding.bundleDigest(target: target, files: afterFiles)
    let snapshot = try WorkflowHistoryStore(root: historyRoot).createSnapshot(inventory: before)

    let result = try WorkflowDirectoryTransactionCoordinator().commit(
      target: target,
      historyRoot: historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: before.bundleDigest,
      expectedAfterBundleDigest: expected,
      preOperationSnapshotId: snapshot.snapshotId
    ) { staging in
      try updated.write(to: staging.appendingPathComponent(relativePath), options: .atomic)
    }
    XCTAssertEqual(result.resultBundleDigest, expected)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: historyRoot.appendingPathComponent("transactions/\(result.transactionId).json.generations").path
    ))
    XCTAssertFalse(FileManager.default.fileExists(atPath: historyRoot.appendingPathComponent("transactions/active.json").path))
  }

  func testTransactionRejectsDirtyBeforeDigestAndTraversalValidation() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveMutableTransactionTarget(root: root)
    let (target, historyRoot) = (resolved.identity, resolved.historyRoot)
    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator().commit(
      target: target,
      historyRoot: historyRoot,
      kind: .restore,
      expectedBeforeBundleDigest: String(repeating: "0", count: 64),
      expectedAfterBundleDigest: String(repeating: "1", count: 64),
      preOperationSnapshotId: "snapshot-test"
    ) { _ in })
    XCTAssertThrowsError(try WorkflowHistoryCanonicalCoding.validateRelativePath("nested/../../escape"))
  }

  func testTransactionRejectsInvalidStagedWorkflowBeforeSourceMutation() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveMutableTransactionTarget(root: root)
    let (target, historyRoot) = (resolved.identity, resolved.historyRoot)
    let before = try WorkflowHistoryIdentityResolver.inventory(for: target)
    let snapshot = try WorkflowHistoryStore(root: historyRoot).createSnapshot(inventory: before)
    let workflow = URL(fileURLWithPath: target.ownershipRoot).appendingPathComponent("workflow.json")
    let original = try Data(contentsOf: workflow)
    let invalid = Data("{}".utf8)
    var files = before.files.map(\.metadata)
    let workflowPath = try XCTUnwrap(files.firstIndex(where: { $0.relativePath == "workflow.json" }))
    files[workflowPath].contentDigest = WorkflowHistoryCanonicalCoding.sha256(invalid)
    files[workflowPath].byteCount = invalid.count
    let expectedAfter = try WorkflowHistoryCanonicalCoding.bundleDigest(target: target, files: files)

    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator().commit(
      target: target,
      historyRoot: historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: before.bundleDigest,
      expectedAfterBundleDigest: expectedAfter,
      preOperationSnapshotId: snapshot.snapshotId
    ) { staging in
      try invalid.write(to: staging.appendingPathComponent("workflow.json"))
    })
    XCTAssertEqual(try Data(contentsOf: workflow), original)
  }

  func testLiveMovedRecoveryRestoresVerifiedBeforeTreeInsteadOfPublishingStaging() async throws {
    let fixture = try await makeRecoveryFixture(phase: .liveMoved, moveLiveToRollback: true)

    let recovered = try WorkflowDirectoryTransactionCoordinator().recover(historyRoot: fixture.historyRoot, target: fixture.target)

    XCTAssertEqual(recovered?.phase, .recovered)
    XCTAssertEqual(try WorkflowHistoryIdentityResolver.inventory(for: fixture.target).bundleDigest, fixture.beforeDigest)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rollback.path))
    let restore = try WorkflowHistorySecurePersistence.readCanonical(
      WorkflowRestoreRecord.self,
      from: fixture.historyRoot.appendingPathComponent("restores/restore-recovery-test.json"),
      historyRoot: fixture.historyRoot
    )
    XCTAssertEqual(restore.outcome, .recovered)
  }

  func testCommittingRecoveryHandlesPersistedFirstRenameWindow() async throws {
    let fixture = try await makeRecoveryFixture(phase: .committing, moveLiveToRollback: true)

    let recovered = try WorkflowDirectoryTransactionCoordinator().recover(historyRoot: fixture.historyRoot, target: fixture.target)

    XCTAssertEqual(recovered?.phase, .recovered)
    XCTAssertEqual(try WorkflowHistoryIdentityResolver.inventory(for: fixture.target).bundleDigest, fixture.beforeDigest)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rollback.path))
  }

  func testStableMetadataRecoversLiveAbsentTreeBeforeInventoryRead() async throws {
    let fixture = try await makeRecoveryFixture(phase: .committing, moveLiveToRollback: true)
    _ = try WorkflowDirectoryTransactionCoordinator().recover(
      historyRoot: fixture.historyRoot,
      target: fixture.target
    )
    XCTAssertEqual(try WorkflowHistoryIdentityResolver.inventory(for: fixture.target).bundleDigest, fixture.beforeDigest)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.active.path))
  }

  func testAmbiguousLiveMovedRecoveryFailsClosedAndPreservesEveryTree() async throws {
    let fixture = try await makeRecoveryFixture(phase: .liveMoved, moveLiveToRollback: false)

    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator().recover(historyRoot: fixture.historyRoot, target: fixture.target))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.live.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staging.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.active.path))
  }

  func testRecoveryRejectsUnownedInventoryDriftBeforeRenameOrDeletion() async throws {
    let fixture = try await makeRecoveryFixture(phase: .liveMoved, moveLiveToRollback: true)
    let drift = fixture.rollback.appendingPathComponent("unowned-drift.txt")
    try Data("attacker".utf8).write(to: drift)

    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator().recover(historyRoot: fixture.historyRoot, target: fixture.target))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.rollback.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staging.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.active.path))
  }

  func testCommittingRecoveryMatrixCoversEveryExistenceRow() async throws {
    let states = treeStates
    for (index, state) in states.enumerated() {
      let fixture = try await makeRecoveryFixture(phase: .committing, state: state)
      if state == TreeState(live: true, rollback: false, staging: true)
          || state == TreeState(live: false, rollback: true, staging: true) {
        let recovered = try WorkflowDirectoryTransactionCoordinator().recover(historyRoot: fixture.historyRoot, target: fixture.target)
        XCTAssertEqual(recovered?.phase, .recovered, "row \(index)")
        XCTAssertEqual(try WorkflowHistoryIdentityResolver.inventory(for: fixture.target).bundleDigest, fixture.beforeDigest)
      } else {
        XCTAssertThrowsError(
          try WorkflowDirectoryTransactionCoordinator().recover(historyRoot: fixture.historyRoot, target: fixture.target),
          "row \(index)"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.active.path), "row \(index)")
      }
    }
  }

  func testLiveMovedRecoveryMatrixCoversEveryExistenceRow() async throws {
    for (index, state) in treeStates.enumerated() {
      let fixture = try await makeRecoveryFixture(phase: .liveMoved, state: state)
      switch state {
      case TreeState(live: false, rollback: true, staging: false),
           TreeState(live: false, rollback: true, staging: true):
        let recovered = try WorkflowDirectoryTransactionCoordinator().recover(historyRoot: fixture.historyRoot, target: fixture.target)
        XCTAssertEqual(recovered?.phase, .recovered, "row \(index)")
        XCTAssertEqual(try WorkflowHistoryIdentityResolver.inventory(for: fixture.target).bundleDigest, fixture.beforeDigest)
      case TreeState(live: true, rollback: true, staging: false):
        let recovered = try WorkflowDirectoryTransactionCoordinator().recover(historyRoot: fixture.historyRoot, target: fixture.target)
        XCTAssertEqual(recovered?.phase, .committed, "row \(index)")
      default:
        XCTAssertThrowsError(
          try WorkflowDirectoryTransactionCoordinator().recover(historyRoot: fixture.historyRoot, target: fixture.target),
          "row \(index)"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.active.path), "row \(index)")
      }
    }
  }

  func testAuditFailurePreservesPublishedAndRollbackTreesForRecovery() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveMutableTransactionTarget(root: root)
    let before = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: before)
    let updated = try updatedWorkflowBytes(root: URL(fileURLWithPath: resolved.identity.ownershipRoot))
    let expected = try replacingWorkflowDigest(in: before, with: updated)

    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator(auditStore: ThrowingAuditStore()).commit(
      target: resolved.identity,
      historyRoot: resolved.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: before.bundleDigest,
      expectedAfterBundleDigest: expected,
      preOperationSnapshotId: snapshot.snapshotId
    ) { staging in
      try updated.write(to: staging.appendingPathComponent("workflow.json"), options: .atomic)
    })

    let active = resolved.historyRoot.appendingPathComponent("transactions/active.json")
    let record = try loadActiveRecord(active, historyRoot: resolved.historyRoot)
    XCTAssertEqual(record.phase, .published)
    XCTAssertTrue(FileManager.default.fileExists(atPath: record.rollbackPath))
    XCTAssertEqual(try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity).bundleDigest, expected)

    let recovered = try WorkflowDirectoryTransactionCoordinator().recover(historyRoot: resolved.historyRoot, target: resolved.identity)
    XCTAssertEqual(recovered?.phase, .committed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: record.rollbackPath))
    XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: resolved.historyRoot.appendingPathComponent("audits/transaction-\(record.transactionId).json").path
    ))
  }

  func testRecoveryCompletesOperationSpecificAuditBeforeRollbackCleanup() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveMutableTransactionTarget(root: root)
    let before = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: before)
    let updated = try updatedWorkflowBytes(root: URL(fileURLWithPath: resolved.identity.ownershipRoot))
    let expected = try replacingWorkflowDigest(in: before, with: updated)
    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator().commit(
      target: resolved.identity,
      historyRoot: resolved.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: before.bundleDigest,
      expectedAfterBundleDigest: expected,
      preOperationSnapshotId: snapshot.snapshotId,
      persistOperationAudit: { _ in throw CLIUsageError("injected operation audit failure") },
      mutateStaging: { staging in
        try updated.write(to: staging.appendingPathComponent("workflow.json"), options: .atomic)
      }
    ))
    let active = resolved.historyRoot.appendingPathComponent("transactions/active.json")
    let record = try loadActiveRecord(active, historyRoot: resolved.historyRoot)
    let audit = resolved.historyRoot.appendingPathComponent("audits/\(record.transactionId).json")
    XCTAssertFalse(FileManager.default.fileExists(atPath: audit.path))

    let recovered = try WorkflowDirectoryTransactionCoordinator().recover(historyRoot: resolved.historyRoot, target: resolved.identity)

    XCTAssertEqual(recovered?.phase, .committed)
    let evidence = try WorkflowHistorySecurePersistence.readCanonical(
      LoopWorkflowMutationEvidence.self,
      from: audit,
      historyRoot: resolved.historyRoot
    )
    XCTAssertTrue(evidence.applied)
    XCTAssertEqual(evidence.afterBundleDigest, expected)
    XCTAssertFalse(FileManager.default.fileExists(atPath: record.rollbackPath))
  }

  func testLockSymlinkIsRejectedWithoutTruncatingTarget() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveMutableTransactionTarget(root: root)
    let before = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: before)
    let victim = root.appendingPathComponent("lock-victim.txt")
    try Data("preserve-me".utf8).write(to: victim)
    let lock = workflowTargetLockURL(target: resolved.identity)
    try FileManager.default.removeItem(at: lock)
    defer { try? FileManager.default.removeItem(at: lock.deletingLastPathComponent()) }
    try FileManager.default.createSymbolicLink(
      at: lock,
      withDestinationURL: victim
    )

    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator().commit(
      target: resolved.identity,
      historyRoot: resolved.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: before.bundleDigest,
      expectedAfterBundleDigest: before.bundleDigest,
      preOperationSnapshotId: snapshot.snapshotId
    ) { _ in })
    XCTAssertEqual(try String(contentsOf: victim), "preserve-me")
  }

  func testRecoveryRejectsNoncanonicalAndDigestMismatchedTransactionBytes() async throws {
    let fixture = try await makeRecoveryFixture(phase: .committing, moveLiveToRollback: false)
    let canonical = try WorkflowHistorySecurePersistence.readPersistedBytes(
      from: fixture.active,
      historyRoot: fixture.historyRoot
    )
    try WorkflowHistorySecurePersistence.writePersistedBytes(
      Data(" ".utf8) + canonical,
      to: fixture.active,
      historyRoot: fixture.historyRoot
    )
    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator().recover(historyRoot: fixture.historyRoot, target: fixture.target))

    try canonical.write(to: fixture.active)
    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator().recover(historyRoot: fixture.historyRoot, target: fixture.target))

    let unknownFixture = try await makeRecoveryFixture(phase: .committing, moveLiveToRollback: false)
    let unknownCanonical = try WorkflowHistorySecurePersistence.readPersistedBytes(
      from: unknownFixture.active,
      historyRoot: unknownFixture.historyRoot
    )
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: unknownCanonical) as? [String: Any])
    object["unknownField"] = true
    let unknownBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try WorkflowHistorySecurePersistence.writePersistedBytes(
      unknownBytes,
      to: unknownFixture.active,
      historyRoot: unknownFixture.historyRoot
    )
    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator().recover(
      historyRoot: unknownFixture.historyRoot,
      target: unknownFixture.target
    ))
  }

  func testTransactionRejectsValidSnapshotWhoseIdentityStateDoesNotMatchBeforeDigest() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveMutableTransactionTarget(root: root)
    let original = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let workflowURL = URL(fileURLWithPath: resolved.identity.ownershipRoot)
      .appendingPathComponent("workflow.json")
    let originalBytes = try Data(contentsOf: workflowURL)
    let updated = try updatedWorkflowBytes(root: URL(fileURLWithPath: resolved.identity.ownershipRoot))
    try updated.write(to: workflowURL)
    let changed = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let wrongSnapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: changed)
    try originalBytes.write(to: workflowURL)

    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator().commit(
      target: resolved.identity,
      historyRoot: resolved.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: original.bundleDigest,
      expectedAfterBundleDigest: original.bundleDigest,
      preOperationSnapshotId: wrongSnapshot.snapshotId
    ) { _ in }) { error in
      XCTAssertTrue(String(describing: error).contains("snapshot does not match"))
    }
  }

  func testStaleLockFileDoesNotBlockCommitOrRecovery() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveMutableTransactionTarget(root: root)
    let before = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: before)
    let transactions = resolved.historyRoot.appendingPathComponent("transactions", isDirectory: true)
    try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: true)
    try Data("crashed-owner".utf8).write(to: transactions.appendingPathComponent("target.lock"))
    let updated = try updatedWorkflowBytes(root: URL(fileURLWithPath: resolved.identity.ownershipRoot))
    let expected = try replacingWorkflowDigest(in: before, with: updated)

    let result = try WorkflowDirectoryTransactionCoordinator().commit(
      target: resolved.identity,
      historyRoot: resolved.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: before.bundleDigest,
      expectedAfterBundleDigest: expected,
      preOperationSnapshotId: snapshot.snapshotId
    ) { staging in
      try updated.write(to: staging.appendingPathComponent("workflow.json"), options: .atomic)
    }
    XCTAssertEqual(result.resultBundleDigest, expected)
  }

  func testLockedPreflightRejectsDeterministicStaleCurrentTreeBeforePreparing() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveMutableTransactionTarget(root: root)
    let before = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: before)
    let live = URL(fileURLWithPath: resolved.identity.ownershipRoot)
    let updated = try updatedWorkflowBytes(root: live)
    let coordinator = WorkflowDirectoryTransactionCoordinator(
      auditStore: FileWorkflowTransactionAuditStore(),
      lockedPreflightHook: {
        try updated.write(to: live.appendingPathComponent("workflow.json"), options: .atomic)
      }
    )

    XCTAssertThrowsError(try coordinator.commit(
      target: resolved.identity,
      historyRoot: resolved.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: before.bundleDigest,
      expectedAfterBundleDigest: before.bundleDigest,
      preOperationSnapshotId: snapshot.snapshotId
    ) { _ in }) { error in
      XCTAssertTrue(String(describing: error).contains("changed since review"))
    }
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: resolved.historyRoot.appendingPathComponent("transactions/active.json").path
    ))
    let transactionFiles = (try? FileManager.default.contentsOfDirectory(
      at: resolved.historyRoot.appendingPathComponent("transactions"),
      includingPropertiesForKeys: nil
    )) ?? []
    XCTAssertTrue(transactionFiles.allSatisfy { $0.lastPathComponent == "target.lock" })
  }

  func testPreparingFailurePersistsFailedOperationAndTransactionAuditsBeforeCleanup() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveMutableTransactionTarget(root: root)
    let before = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: before)

    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator(auditStore: ThrowingAuditStore()).commit(
      target: resolved.identity,
      historyRoot: resolved.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: before.bundleDigest,
      expectedAfterBundleDigest: before.bundleDigest,
      preOperationSnapshotId: snapshot.snapshotId
    ) { _ in
      throw CLIUsageError("injected preparing failure")
    }) { error in
      XCTAssertTrue(String(describing: error).contains("recovery state was retained"))
    }
    let active = resolved.historyRoot.appendingPathComponent("transactions/active.json")
    let retained = try loadActiveRecord(active, historyRoot: resolved.historyRoot)
    XCTAssertEqual(retained.phase, .preparing)
    XCTAssertTrue(FileManager.default.fileExists(atPath: retained.stagingPath))
    let mutationURL = resolved.historyRoot.appendingPathComponent("audits/\(retained.transactionId).json")
    let failedMutation = try WorkflowHistorySecurePersistence.readCanonical(
      LoopWorkflowMutationEvidence.self,
      from: mutationURL,
      historyRoot: resolved.historyRoot
    )
    XCTAssertEqual(failedMutation.outcome, .failed)

    let recovered = try WorkflowDirectoryTransactionCoordinator().recover(historyRoot: resolved.historyRoot, target: resolved.identity)

    XCTAssertEqual(recovered?.phase, .failed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: retained.stagingPath))
    XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
    let transactionAudit = try WorkflowHistorySecurePersistence.readCanonical(
      WorkflowDirectoryTransactionAudit.self,
      from: resolved.historyRoot.appendingPathComponent("audits/transaction-\(retained.transactionId).json"),
      historyRoot: resolved.historyRoot
    )
    XCTAssertEqual(transactionAudit.outcome, .failed)
  }

  func testTransactionStagingIsAVerifiedSameDeviceSiblingBoundary() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveMutableTransactionTarget(root: root)
    let before = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: before)
    let live = URL(fileURLWithPath: resolved.identity.ownershipRoot)

    _ = try WorkflowDirectoryTransactionCoordinator().commit(
      target: resolved.identity,
      historyRoot: resolved.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: before.bundleDigest,
      expectedAfterBundleDigest: before.bundleDigest,
      preOperationSnapshotId: snapshot.snapshotId
    ) { staging in
      XCTAssertEqual(staging.deletingLastPathComponent().standardizedFileURL, live.deletingLastPathComponent().standardizedFileURL)
      var liveStatus = stat()
      var stagingStatus = stat()
      XCTAssertEqual(lstat(live.path, &liveStatus), 0)
      XCTAssertEqual(lstat(staging.path, &stagingStatus), 0)
      XCTAssertEqual(liveStatus.st_dev, stagingStatus.st_dev)
    }
  }

  func testRequiredMockScenarioIsExecutedAndActualEvidenceIsPersisted() async throws {
    let (root, created) = try await makeWorkflowVersioningFixture(self)
    let workflowURL = URL(fileURLWithPath: created.workflowDirectory).appendingPathComponent("workflow.json")
    var workflow = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workflowURL)) as? [String: Any])
    workflow["loop"] = selfEvolutionLoop(requiredVerification: ["workflow validate", "mock-scenario"])
    try JSONSerialization.data(withJSONObject: workflow, options: [.prettyPrinted, .sortedKeys]).write(to: workflowURL)
    let nodeRegistry = try XCTUnwrap(workflow["nodes"] as? [[String: Any]])
    let nodeId = try XCTUnwrap(nodeRegistry.first?["id"] as? String)
    let scenario = [nodeId: ["payload": ["verified": true]]]
    try JSONSerialization.data(withJSONObject: scenario, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: created.workflowDirectory).appendingPathComponent("mock-scenario.json"))
    let resolved = try resolveMutableTransactionTarget(root: root)
    let before = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: before)

    let result = try WorkflowDirectoryTransactionCoordinator().commit(
      target: resolved.identity,
      historyRoot: resolved.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: before.bundleDigest,
      expectedAfterBundleDigest: before.bundleDigest,
      preOperationSnapshotId: snapshot.snapshotId
    ) { _ in }

    XCTAssertEqual(result.verification.map(\.id), ["mock-scenario-mock-scenario", "workflow-validate"])
    XCTAssertTrue(result.verification.allSatisfy { $0.outcome == "passed" })
    let recordURL = resolved.historyRoot.appendingPathComponent("transactions/\(result.transactionId).json")
    let record = try WorkflowHistorySecurePersistence.readCanonical(
      WorkflowDirectoryTransactionRecord.self,
      from: recordURL,
      historyRoot: resolved.historyRoot
    )
    XCTAssertEqual(record.verification, result.verification)
  }

  func testRequiredMockScenarioMissingFailsBeforeLiveMutation() async throws {
    let (root, created) = try await makeWorkflowVersioningFixture(self)
    let workflowURL = URL(fileURLWithPath: created.workflowDirectory).appendingPathComponent("workflow.json")
    var workflow = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workflowURL)) as? [String: Any])
    workflow["loop"] = selfEvolutionLoop(requiredVerification: ["workflow validate", "mock-scenario"])
    try JSONSerialization.data(withJSONObject: workflow, options: [.prettyPrinted, .sortedKeys]).write(to: workflowURL)
    let resolved = try resolveMutableTransactionTarget(root: root)
    let before = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: before)

    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator().commit(
      target: resolved.identity,
      historyRoot: resolved.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: before.bundleDigest,
      expectedAfterBundleDigest: before.bundleDigest,
      preOperationSnapshotId: snapshot.snapshotId
    ) { _ in }) { error in
      XCTAssertTrue(String(describing: error).contains("no mock scenario"))
    }
    XCTAssertEqual(try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity).bundleDigest, before.bundleDigest)
  }

  func testSnapshotAndProposalExactFileChecksRejectEnumeratedSymlinks() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveMutableTransactionTarget(root: root)
    let inventory = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: inventory)
    let snapshotDirectory = resolved.historyRoot.appendingPathComponent("snapshots/\(snapshot.snapshotId)")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snapshotDirectory.path)
    let snapshotLink = snapshotDirectory.appendingPathComponent("extra-link")
    try FileManager.default.createSymbolicLink(
      at: snapshotLink,
      withDestinationURL: snapshotDirectory.appendingPathComponent("manifest.json")
    )
    XCTAssertThrowsError(try WorkflowHistoryStore(root: resolved.historyRoot).loadSnapshot(
      snapshot.snapshotId,
      expectedIdentity: resolved.identity
    )) { error in
      XCTAssertTrue(String(describing: error).contains("contains a link"))
    }

    let proposal = WorkflowChangeProposal(
      proposalId: "proposal-symlink-test",
      sourceSessionId: "session-test",
      target: resolved.identity,
      beforeBundleDigest: inventory.bundleDigest,
      operations: [],
      expectedAfterBundleDigest: inventory.bundleDigest,
      rationale: "verify exact-file symlink rejection",
      createdAt: Date(),
      proposalDigest: String(repeating: "0", count: 64)
    )
    var finalizedProposal = proposal
    finalizedProposal.proposalDigest = try WorkflowHistoryCanonicalCoding.proposalDigest(finalizedProposal)
    let store = WorkflowChangeSetStore(root: resolved.historyRoot)
    try store.publishProposal(finalizedProposal, contentObjects: [:])
    let proposalDirectory = resolved.historyRoot.appendingPathComponent("proposals/\(finalizedProposal.proposalId)")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: proposalDirectory.path)
    try FileManager.default.createSymbolicLink(
      at: proposalDirectory.appendingPathComponent("extra-link"),
      withDestinationURL: proposalDirectory.appendingPathComponent("proposal.json")
    )
    XCTAssertThrowsError(try store.loadProposal(finalizedProposal.proposalId, expectedIdentity: resolved.identity)) { error in
      XCTAssertTrue(String(describing: error).contains("contains a link"))
    }
  }

  func testIncompleteSnapshotFailsClosedBeforeUse() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveMutableTransactionTarget(root: root)
    let inventory = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: inventory)
    let file = try XCTUnwrap(snapshot.files.first)
    let objectDirectory = resolved.historyRoot
      .appendingPathComponent("snapshots/\(snapshot.snapshotId)/objects/sha256/\(file.contentDigest.prefix(2))")
    let objectURL = objectDirectory.appendingPathComponent(file.contentDigest)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: objectDirectory.path)
    try FileManager.default.removeItem(at: objectURL)

    XCTAssertThrowsError(try WorkflowHistoryStore(root: resolved.historyRoot).loadSnapshot(
      snapshot.snapshotId,
      expectedIdentity: resolved.identity
    ))
  }

  func testResolutionUsesConfiguredContainedHistoryRootForActiveMarker() async throws {
    let (root, created) = try await makeWorkflowVersioningFixture(self)
    let workflowURL = URL(fileURLWithPath: created.workflowDirectory).appendingPathComponent("workflow.json")
    var workflow = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workflowURL)) as? [String: Any])
    workflow["loop"] = selfEvolutionLoop(historyRoot: "custom/workflow-history")
    try JSONSerialization.data(withJSONObject: workflow, options: [.prettyPrinted, .sortedKeys]).write(to: workflowURL)
    let marker = root.appendingPathComponent("custom/workflow-history/versioned-flow/transactions/active.json")
    try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: marker)

    XCTAssertThrowsError(try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
      workflowName: "versioned-flow",
      scope: .project,
      workingDirectory: root.path
    ))) { error in
      XCTAssertTrue(String(describing: error).contains("nonterminal directory transaction"))
    }
  }

  private struct RecoveryFixture {
    var target: WorkflowBundleIdentity
    var historyRoot: URL
    var live: URL
    var staging: URL
    var rollback: URL
    var active: URL
    var beforeDigest: String
  }

  private struct TreeState: Equatable {
    var live: Bool
    var rollback: Bool
    var staging: Bool
  }

  private var treeStates: [TreeState] {
    [false, true].flatMap { live in
      [false, true].flatMap { rollback in
        [false, true].map { staging in TreeState(live: live, rollback: rollback, staging: staging) }
      }
    }
  }

  private func makeRecoveryFixture(
    phase: WorkflowDirectoryTransactionPhase,
    moveLiveToRollback: Bool
  ) async throws -> RecoveryFixture {
    try await makeRecoveryFixture(
      phase: phase,
      state: moveLiveToRollback
        ? TreeState(live: false, rollback: true, staging: true)
        : TreeState(live: true, rollback: false, staging: true)
    )
  }

  private func makeRecoveryFixture(
    phase: WorkflowDirectoryTransactionPhase,
    state: TreeState
  ) async throws -> RecoveryFixture {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveMutableTransactionTarget(root: root)
    let (target, historyRoot) = (resolved.identity, resolved.historyRoot)
    let before = try WorkflowHistoryIdentityResolver.inventory(for: target)
    let snapshot = try WorkflowHistoryStore(root: historyRoot).createSnapshot(
      inventory: before,
      snapshotId: "snapshot-recovery-test"
    )
    let transactionId = "transaction-recovery-test"
    let live = URL(fileURLWithPath: target.ownershipRoot, isDirectory: true)
    let parent = live.deletingLastPathComponent()
    let staging = parent.appendingPathComponent(".\(live.lastPathComponent).riela-stage-\(transactionId)")
    let rollback = parent.appendingPathComponent(".\(live.lastPathComponent).riela-rollback-\(transactionId)")
    try FileManager.default.copyItem(at: live, to: staging)
    let workflow = staging.appendingPathComponent("workflow.json")
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workflow)) as? [String: Any])
    object["description"] = "recovery-after"
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: workflow)
    let after = try WorkflowHistoryIdentityResolver.inventory(for: target, rootOverride: staging)
    if state.rollback { try FileManager.default.copyItem(at: live, to: rollback) }
    if !state.live {
      try FileManager.default.removeItem(at: live)
    } else if state.rollback && !state.staging {
      try FileManager.default.removeItem(at: live)
      try FileManager.default.copyItem(at: staging, to: live)
    }
    if !state.staging { try FileManager.default.removeItem(at: staging) }
    let transactions = historyRoot.appendingPathComponent("transactions", isDirectory: true)
    try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: true)
    let active = transactions.appendingPathComponent("active.json")
    let record = WorkflowDirectoryTransactionRecord(
      transactionId: transactionId,
      kind: .restore,
      target: target,
      beforeBundleDigest: before.bundleDigest,
      expectedAfterBundleDigest: after.bundleDigest,
      preOperationSnapshotId: snapshot.snapshotId,
      beforeUnownedInventory: before.unownedFiles.map(WorkflowUnownedInventoryEntry.init),
      expectedAfterUnownedInventory: after.unownedFiles.map(WorkflowUnownedInventoryEntry.init),
      operationAuditIntent: .restore(WorkflowRestoreRecord(
        restoreId: "restore-recovery-test",
        target: target,
        sourceSnapshotId: snapshot.snapshotId,
        preRestoreSnapshotId: snapshot.snapshotId,
        requestedBundleDigest: after.bundleDigest,
        beforeBundleDigest: before.bundleDigest,
        approved: true,
        dirtyConflictPolicy: "reject",
        transactionId: transactionId,
        startedAt: Date(timeIntervalSince1970: 1),
        outcome: .failed
      )),
      stagingPath: staging.path,
      rollbackPath: rollback.path,
      phase: phase
    )
    try WorkflowTransactionGenerationStore.write(
      record,
      logicalURL: transactions.appendingPathComponent("\(transactionId).json"),
      historyRoot: historyRoot,
      betweenPayloadAndSidecar: {}
    )
    try WorkflowHistorySecurePersistence.writeCanonical(
      WorkflowTransactionActiveMarker(transactionId: transactionId),
      to: active,
      historyRoot: historyRoot
    )
    let stableMarker = WorkflowTransactionStableMetadata.url(forOwnershipRoot: live)
    try WorkflowHistorySecurePersistence.writeCanonical(
      WorkflowTransactionStableMetadata(
        transactionId: transactionId,
        target: target,
        historyRoot: historyRoot.path
      ),
      to: stableMarker,
      historyRoot: live.deletingLastPathComponent()
    )
    return RecoveryFixture(
      target: target,
      historyRoot: historyRoot,
      live: live,
      staging: staging,
      rollback: rollback,
      active: active,
      beforeDigest: before.bundleDigest
    )
  }

  func updatedWorkflowBytes(root: URL) throws -> Data {
    let url = root.appendingPathComponent("workflow.json")
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    object["description"] = "transaction-updated"
    return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
  }

  private func loadActiveRecord(_ active: URL, historyRoot: URL) throws -> WorkflowDirectoryTransactionRecord {
    let bytes = try WorkflowHistorySecurePersistence.readPersistedBytes(from: active, historyRoot: historyRoot)
    if let record = try? WorkflowHistoryCanonicalCoding.decode(WorkflowDirectoryTransactionRecord.self, from: bytes) {
      return record
    }
    let marker = try WorkflowHistoryCanonicalCoding.decode(WorkflowTransactionActiveMarker.self, from: bytes)
    return try WorkflowHistorySecurePersistence.readCanonical(
      WorkflowDirectoryTransactionRecord.self,
      from: historyRoot.appendingPathComponent("transactions/\(marker.transactionId).json"),
      historyRoot: historyRoot
    )
  }

  func replacingWorkflowDigest(
    in inventory: WorkflowBundleInventory,
    with bytes: Data
  ) throws -> String {
    var files = inventory.files.map(\.metadata)
    let index = try XCTUnwrap(files.firstIndex(where: { $0.relativePath == "workflow.json" }))
    files[index].contentDigest = WorkflowHistoryCanonicalCoding.sha256(bytes)
    files[index].byteCount = bytes.count
    return try WorkflowHistoryCanonicalCoding.bundleDigest(target: inventory.target, files: files)
  }

  private func selfEvolutionLoop(
    historyRoot: String = ".riela/workflow-history",
    requiredVerification: [String] = ["workflow validate"]
  ) -> [String: Any] {
    ["selfEvolution": [
      "allowed": true,
      "defaultMode": "propose",
      "requiresReviewGate": true,
      "snapshotPolicy": "bundle-before-apply",
      "historyRoot": historyRoot,
      "immutablePackageMutation": "deny",
      "requiredVerification": requiredVerification
    ]]
  }
}

private struct ThrowingAuditStore: WorkflowTransactionAuditPersisting {
  func persist(_ audit: WorkflowDirectoryTransactionAudit, historyRoot: URL) throws {
    throw CLIUsageError("injected audit persistence failure")
  }
}
