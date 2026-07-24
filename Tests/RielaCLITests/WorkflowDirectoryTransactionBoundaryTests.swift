import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

extension WorkflowDirectoryTransactionTests {
  func testNonterminalMutableRecoveryRejectsRegistryRootSwapWithoutChangingEvidence() async throws {
    let fixture = try await makeMutableWorkflowVersioningFixture(self)
    let resolved = fixture.resolved
    let before = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: before)
    let updated = try updatedWorkflowBytes(root: fixture.workflowDirectory)
    let expected = try replacingWorkflowDigest(in: before, with: updated)
    let coordinator = WorkflowDirectoryTransactionCoordinator(
      auditStore: FileWorkflowTransactionAuditStore(),
      boundaryHook: { boundary in
        if boundary == .publishedRecord {
          throw WorkflowDirectoryInjectedInterruption(boundary: boundary)
        }
      }
    )
    let registryDigest = try XCTUnwrap(resolved.bundle.mutableRegistryDigest)
    XCTAssertThrowsError(try CLIRuntimeEnvironment.$overrides.withValue(fixture.environment) {
      try WorkflowMutableRegistry().withWorkflowMutationAccess(
        workflowId: resolved.identity.workflowId,
        expectedDigest: registryDigest
      ) { detachedWorkflowDirectory, publish in
        try coordinator.commit(
          target: resolved.identity,
          historyRoot: resolved.historyRoot,
          kind: .apply,
          expectedBeforeBundleDigest: before.bundleDigest,
          expectedAfterBundleDigest: expected,
          preOperationSnapshotId: snapshot.snapshotId,
          physicalOwnershipRoot: detachedWorkflowDirectory,
          postCommitPublication: publish
        ) { staging in
          try updated.write(to: staging.appendingPathComponent("workflow.json"), options: .atomic)
        }
      }
    })

    let interrupted = try XCTUnwrap(transactionRecords(in: resolved.historyRoot).first)
    XCTAssertEqual(interrupted.record.phase, .published)
    let physicalRoot = try XCTUnwrap(interrupted.record.physicalOwnershipRoot)
    let generationDirectory = URL(
      fileURLWithPath: interrupted.url.path + ".generations",
      isDirectory: true
    )
    let generationsBefore = try FileManager.default.contentsOfDirectory(
      atPath: generationDirectory.path
    ).sorted()
    let activeMarker = resolved.historyRoot.appendingPathComponent("transactions/active.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: activeMarker.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: physicalRoot))
    XCTAssertTrue(FileManager.default.fileExists(atPath: interrupted.record.rollbackPath))

    let home = URL(
      fileURLWithPath: try XCTUnwrap(fixture.environment["HOME"]),
      isDirectory: true
    )
    let registryRoot = home.appendingPathComponent(
      ".riela/temporary-workflows",
      isDirectory: true
    )
    let displaced = fixture.root.appendingPathComponent(
      "displaced-mutable-registry",
      isDirectory: true
    )
    let swap = HistoryRecoveryRootSwapOnce {
      try FileManager.default.moveItem(at: registryRoot, to: displaced)
      try FileManager.default.createDirectory(at: registryRoot, withIntermediateDirectories: false)
      try FileManager.default.copyItem(
        at: URL(fileURLWithPath: physicalRoot, isDirectory: true),
        to: registryRoot.appendingPathComponent(resolved.identity.workflowId, isDirectory: true)
      )
    }
    defer {
      if FileManager.default.fileExists(atPath: displaced.path) {
        try? FileManager.default.removeItem(at: registryRoot)
        try? FileManager.default.moveItem(at: displaced, to: registryRoot)
      }
    }
    let resolver = FileSystemWorkflowBundleResolver(
      mutableRegistryHistoryRecoveryHook: { try swap.run() }
    )
    XCTAssertThrowsError(try CLIRuntimeEnvironment.$overrides.withValue(fixture.environment) {
      try resolver.resolve(WorkflowResolutionOptions(
        workflowName: resolved.identity.workflowId,
        scope: .user,
        workingDirectory: fixture.root.path
      ))
    }) { error in
      XCTAssertTrue(String(describing: error).contains("root changed"), "\(error)")
    }

    let preserved = try XCTUnwrap(transactionRecords(in: resolved.historyRoot).first)
    XCTAssertEqual(preserved.record.phase, .published)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: generationDirectory.path).sorted(),
      generationsBefore
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: activeMarker.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: physicalRoot))
    XCTAssertTrue(FileManager.default.fileExists(atPath: interrupted.record.rollbackPath))
  }

  func testEveryDurabilityBoundaryRecoversMutableCoordinatorThroughPublicValidate() async throws {
    for boundary in WorkflowDirectoryTransactionBoundary.allCases {
      let (root, _) = try await makeWorkflowVersioningFixture(self)
      let resolved = try resolveMutableTransactionTarget(root: root)
      let before = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
      let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: before)
      let updated = try updatedWorkflowBytes(root: URL(fileURLWithPath: resolved.identity.ownershipRoot))
      let expected = try replacingWorkflowDigest(in: before, with: updated)
      let coordinator = WorkflowDirectoryTransactionCoordinator(
        auditStore: FileWorkflowTransactionAuditStore(),
        boundaryHook: { observed in
          if observed == boundary { throw WorkflowDirectoryInjectedInterruption(boundary: boundary) }
        }
      )
      let environment = mutableWorkflowVersioningEnvironment(root: root)
      let registryDigest = try XCTUnwrap(resolved.bundle.mutableRegistryDigest)

      XCTAssertThrowsError(try CLIRuntimeEnvironment.$overrides.withValue(environment) {
        try WorkflowMutableRegistry().withWorkflowMutationAccess(
          workflowId: resolved.identity.workflowId,
          expectedDigest: registryDigest
        ) { detachedWorkflowDirectory, publish in
          try coordinator.commit(
            target: resolved.identity,
            historyRoot: resolved.historyRoot,
            kind: .apply,
            expectedBeforeBundleDigest: before.bundleDigest,
            expectedAfterBundleDigest: expected,
            preOperationSnapshotId: snapshot.snapshotId,
            physicalOwnershipRoot: detachedWorkflowDirectory,
            postCommitPublication: publish
          ) { staging in
            try updated.write(
              to: staging.appendingPathComponent("workflow.json"),
              options: .atomic
            )
          }
        }
      }, boundary.rawValue)

      let interruptedRecord = try transactionRecords(in: resolved.historyRoot).first
      if unresolvedBoundaries.contains(boundary) {
        XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator().commit(
          target: resolved.identity,
          historyRoot: resolved.historyRoot,
          kind: .apply,
          expectedBeforeBundleDigest: before.bundleDigest,
          expectedAfterBundleDigest: expected,
          preOperationSnapshotId: snapshot.snapshotId
        ) { _ in }) { error in
          XCTAssertTrue(String(describing: error).contains("nonterminal"), boundary.rawValue)
        }
      }

      let response = await RielaCLIApplication().run([
        "workflow", "validate", resolved.identity.workflowId,
        "--scope", "user", "--working-dir", root.path, "--output", "json"
      ], environment: environment)
      XCTAssertEqual(
        response.exitCode,
        .success,
        "\(boundary.rawValue): \(response.stdout)\(response.stderr)"
      )
      if let interruptedRecord {
        try assertTerminalState(interruptedRecord, resolved: resolved, boundary: boundary)
      } else {
        XCTAssertEqual(boundary, .preparingPayloadBeforeSidecar)
      }
    }
  }

  private var unresolvedBoundaries: Set<WorkflowDirectoryTransactionBoundary> {
    [
      .transactionRecord, .activeMarker, .stableMarker, .preparedRecord, .committingRecord,
      .liveToRollbackRename, .liveMovedRecord, .stagingToLiveRename, .publishedRecord,
      .operationAudit, .transactionAudit
    ]
  }

  private func assertTerminalState(
    _ interrupted: (url: URL, record: WorkflowDirectoryTransactionRecord),
    resolved: WorkflowVersioningResolvedTarget,
    boundary: WorkflowDirectoryTransactionBoundary
  ) throws {
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: resolved.historyRoot.appendingPathComponent("transactions/active.json").path
    ), boundary.rawValue)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: WorkflowTransactionStableMetadata.url(
        forOwnershipRoot: URL(fileURLWithPath: resolved.identity.ownershipRoot)
      ).path
    ), boundary.rawValue)
    let terminal = try WorkflowHistorySecurePersistence.readCanonical(
      WorkflowDirectoryTransactionRecord.self,
      from: interrupted.url,
      historyRoot: resolved.historyRoot
    )
    XCTAssertTrue([.committed, .failed, .recovered].contains(terminal.phase), boundary.rawValue)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: resolved.historyRoot.appendingPathComponent("audits/transaction-\(terminal.transactionId).json").path
    ), boundary.rawValue)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: resolved.historyRoot.appendingPathComponent("audits/\(terminal.transactionId).json").path
    ), boundary.rawValue)
  }

  private func transactionRecords(
    in historyRoot: URL
  ) throws -> [(url: URL, record: WorkflowDirectoryTransactionRecord)] {
    let directory = historyRoot.appendingPathComponent("transactions", isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasSuffix(".json.generations") }
      .compactMap { generations in
        let name = String(generations.lastPathComponent.dropLast(".generations".count))
        let url = directory.appendingPathComponent(name)
        return try WorkflowTransactionGenerationStore.readLatest(logicalURL: url, historyRoot: historyRoot)
          .map { (url, $0) }
      }
  }
}

private final class HistoryRecoveryRootSwapOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false
  private let action: () throws -> Void

  init(action: @escaping () throws -> Void) {
    self.action = action
  }

  func run() throws {
    lock.lock()
    defer { lock.unlock() }
    guard !completed else { return }
    try action()
    completed = true
  }
}
