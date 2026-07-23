import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

extension WorkflowDirectoryTransactionTests {
  func testDetachedRecoveryHandlesBothLiveMovedRenameWindows() async throws {
    for boundary in [WorkflowDirectoryTransactionBoundary.liveMovedRecord, .stagingToLiveRename] {
      let fixture = try await makeDetachedInterruptionFixture(boundary: boundary)
      defer { try? FileManager.default.removeItem(at: fixture.detachedRoot.deletingLastPathComponent()) }

      let discovered = try XCTUnwrap(try discoverWorkflowTransaction(
        transactions: fixture.historyRoot.appendingPathComponent("transactions", isDirectory: true),
        active: fixture.historyRoot.appendingPathComponent("transactions/active.json"),
        historyRoot: fixture.historyRoot
      ))
      XCTAssertEqual(discovered.record.phase, .liveMoved)
      if boundary == .liveMovedRecord {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.detachedRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: discovered.record.stagingPath))
      } else {
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.detachedRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: discovered.record.stagingPath))
      }

      let recovered = try WorkflowDirectoryTransactionCoordinator().recover(
        historyRoot: fixture.historyRoot,
        target: fixture.target,
        authoritativeBundleDigest: fixture.beforeDigest
      )

      XCTAssertEqual(recovered?.phase, .recovered)
      XCTAssertEqual(
        try WorkflowHistoryIdentityResolver.inventory(
          for: fixture.target,
          rootOverride: fixture.detachedRoot
        ).bundleDigest,
        fixture.beforeDigest
      )
      XCTAssertFalse(FileManager.default.fileExists(atPath: discovered.record.stagingPath))
      XCTAssertFalse(FileManager.default.fileExists(atPath: discovered.record.rollbackPath))
    }
  }

  func testForgedDetachedOwnershipRootIsRejectedBeforeExternalMutation() async throws {
    let fixture = try await makeDetachedInterruptionFixture(boundary: .liveMovedRecord)
    defer { try? FileManager.default.removeItem(at: fixture.detachedRoot.deletingLastPathComponent()) }
    let transactions = fixture.historyRoot.appendingPathComponent("transactions", isDirectory: true)
    var record = try XCTUnwrap(try discoverWorkflowTransaction(
      transactions: transactions,
      active: transactions.appendingPathComponent("active.json"),
      historyRoot: fixture.historyRoot
    )).record
    let external = fixture.historyRoot.appendingPathComponent("external-victim", isDirectory: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    let marker = external.appendingPathComponent("must-remain.txt")
    try Data("preserve".utf8).write(to: marker)
    let parent = external.deletingLastPathComponent()
    record.physicalOwnershipRoot = external.path
    record.stagingPath = parent.appendingPathComponent(
      ".external-victim.riela-stage-\(record.transactionId)", isDirectory: true
    ).path
    record.rollbackPath = parent.appendingPathComponent(
      ".external-victim.riela-rollback-\(record.transactionId)", isDirectory: true
    ).path

    XCTAssertThrowsError(try validateWorkflowTransactionRecordForDiscovery(
      record,
      historyRoot: fixture.historyRoot
    )) { error in
      XCTAssertTrue(String(describing: error).contains("canonical temporary namespace"))
    }
    XCTAssertEqual(try Data(contentsOf: marker), Data("preserve".utf8))

    _ = try WorkflowDirectoryTransactionCoordinator().recover(
      historyRoot: fixture.historyRoot,
      target: fixture.target,
      authoritativeBundleDigest: fixture.beforeDigest
    )
  }

  func testDetachedRecoveryFailsClosedWhenOwnershipContainerChangesAfterValidation() async throws {
    let fixture = try await makeDetachedInterruptionFixture(boundary: .stagingToLiveRename)
    let container = fixture.detachedRoot.deletingLastPathComponent()
    let retainedContainer = container.deletingLastPathComponent().appendingPathComponent(
      container.lastPathComponent + "-retained",
      isDirectory: true
    )
    defer {
      try? FileManager.default.removeItem(at: container)
      try? FileManager.default.removeItem(at: retainedContainer)
    }
    let transactions = fixture.historyRoot.appendingPathComponent("transactions", isDirectory: true)
    let active = transactions.appendingPathComponent("active.json")
    let discovered = try XCTUnwrap(try discoverWorkflowTransaction(
      transactions: transactions,
      active: active,
      historyRoot: fixture.historyRoot
    ))
    let retainedRoot = retainedContainer.appendingPathComponent("root", isDirectory: true)
    let retainedRollback = retainedContainer.appendingPathComponent(
      URL(fileURLWithPath: discovered.record.rollbackPath).lastPathComponent,
      isDirectory: true
    )
    let retainedStableMarker = retainedContainer.appendingPathComponent(
      WorkflowTransactionStableMetadata.url(forOwnershipRoot: fixture.detachedRoot).lastPathComponent
    )
    let replacementRoot = container.appendingPathComponent("root", isDirectory: true)
    let replacementSentinel = replacementRoot.appendingPathComponent("replacement-must-remain.txt")
    let coordinator = WorkflowDirectoryTransactionCoordinator(
      auditStore: FileWorkflowTransactionAuditStore(),
      detachedRecoveryValidatedHook: {
        try FileManager.default.moveItem(at: container, to: retainedContainer)
        try FileManager.default.createDirectory(at: replacementRoot, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: replacementSentinel)
      }
    )

    XCTAssertThrowsError(try coordinator.recover(
      historyRoot: fixture.historyRoot,
      target: fixture.target,
      authoritativeBundleDigest: fixture.beforeDigest
    )) { error in
      XCTAssertTrue(String(describing: error).contains("ownership container changed"))
    }

    XCTAssertEqual(try Data(contentsOf: replacementSentinel), Data("replacement".utf8))
    XCTAssertEqual(
      try WorkflowHistoryIdentityResolver.inventory(
        for: fixture.target,
        rootOverride: retainedRoot
      ).bundleDigest,
      discovered.record.expectedAfterBundleDigest
    )
    XCTAssertEqual(
      try WorkflowHistoryIdentityResolver.inventory(
        for: fixture.target,
        rootOverride: retainedRollback
      ).bundleDigest,
      fixture.beforeDigest
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: retainedStableMarker.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
    XCTAssertEqual(
      try WorkflowTransactionGenerationStore.readLatest(
        logicalURL: discovered.recordURL,
        historyRoot: fixture.historyRoot
      )?.phase,
      .liveMoved
    )
  }

  func testDetachedCommitFailsClosedWhenOwnershipContainerChangesAfterValidation() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveMutableTransactionTarget(root: root)
    let before = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: before)
    let source = URL(fileURLWithPath: resolved.identity.ownershipRoot, isDirectory: true)
    let detachedRoot = try WorkflowDetachedOwnershipRoot.create()
    for entry in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
      try FileManager.default.copyItem(at: entry, to: detachedRoot.appendingPathComponent(entry.lastPathComponent))
    }
    let updated = try updatedWorkflowBytes(root: detachedRoot)
    let expectedAfter = try replacingWorkflowDigest(in: before, with: updated)
    let container = detachedRoot.deletingLastPathComponent()
    let retainedContainer = container.deletingLastPathComponent().appendingPathComponent(
      container.lastPathComponent + "-retained",
      isDirectory: true
    )
    let retainedRoot = retainedContainer.appendingPathComponent("root", isDirectory: true)
    let replacementRoot = container.appendingPathComponent("root", isDirectory: true)
    let replacementSentinel = replacementRoot.appendingPathComponent("replacement-must-remain.txt")
    defer {
      try? FileManager.default.removeItem(at: container)
      try? FileManager.default.removeItem(at: retainedContainer)
    }
    let coordinator = WorkflowDirectoryTransactionCoordinator(
      auditStore: FileWorkflowTransactionAuditStore(),
      lockedPreflightHook: {
        try FileManager.default.moveItem(at: container, to: retainedContainer)
        try FileManager.default.createDirectory(at: replacementRoot, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: replacementSentinel)
      }
    )

    XCTAssertThrowsError(try coordinator.commit(
      target: resolved.identity,
      historyRoot: resolved.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: before.bundleDigest,
      expectedAfterBundleDigest: expectedAfter,
      preOperationSnapshotId: snapshot.snapshotId,
      physicalOwnershipRoot: detachedRoot
    ) { staging in
      try updated.write(to: staging.appendingPathComponent("workflow.json"), options: .atomic)
    }) { error in
      XCTAssertTrue(String(describing: error).contains("ownership container changed"))
    }

    XCTAssertEqual(try Data(contentsOf: replacementSentinel), Data("replacement".utf8))
    XCTAssertEqual(
      try WorkflowHistoryIdentityResolver.inventory(
        for: resolved.identity,
        rootOverride: retainedRoot
      ).bundleDigest,
      before.bundleDigest
    )
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: WorkflowTransactionStableMetadata.url(forOwnershipRoot: retainedRoot).path
    ))
    let retainedNames = try FileManager.default.contentsOfDirectory(atPath: retainedContainer.path)
    XCTAssertEqual(retainedNames, ["root"])
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: resolved.historyRoot.appendingPathComponent("transactions/active.json").path
    ))
  }

  private struct DetachedInterruptionFixture {
    var target: WorkflowBundleIdentity
    var historyRoot: URL
    var detachedRoot: URL
    var beforeDigest: String
  }

  private func makeDetachedInterruptionFixture(
    boundary: WorkflowDirectoryTransactionBoundary
  ) async throws -> DetachedInterruptionFixture {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveMutableTransactionTarget(root: root)
    let before = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: before)
    let source = URL(fileURLWithPath: resolved.identity.ownershipRoot, isDirectory: true)
    let detached = try WorkflowDetachedOwnershipRoot.create()
    for entry in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
      try FileManager.default.copyItem(at: entry, to: detached.appendingPathComponent(entry.lastPathComponent))
    }
    let updated = try updatedWorkflowBytes(root: detached)
    let expectedAfter = try replacingWorkflowDigest(in: before, with: updated)
    let coordinator = WorkflowDirectoryTransactionCoordinator(
      auditStore: FileWorkflowTransactionAuditStore(),
      boundaryHook: { observed in
        if observed == boundary { throw WorkflowDirectoryInjectedInterruption(boundary: observed) }
      }
    )

    XCTAssertThrowsError(try coordinator.commit(
      target: resolved.identity,
      historyRoot: resolved.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: before.bundleDigest,
      expectedAfterBundleDigest: expectedAfter,
      preOperationSnapshotId: snapshot.snapshotId,
      physicalOwnershipRoot: detached
    ) { staging in
      try updated.write(to: staging.appendingPathComponent("workflow.json"), options: .atomic)
    }) { error in
      guard let interruption = error as? WorkflowDirectoryInjectedInterruption else {
        return XCTFail("unexpected interruption error: \(error)")
      }
      XCTAssertEqual(interruption.boundary, boundary)
    }
    return DetachedInterruptionFixture(
      target: resolved.identity,
      historyRoot: resolved.historyRoot,
      detachedRoot: detached,
      beforeDigest: before.bundleDigest
    )
  }
}
