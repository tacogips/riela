import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

extension WorkflowDirectoryTransactionTests {
  func testEveryDurabilityBoundaryRecoversThroughPublicValidateCommand() async throws {
    for boundary in WorkflowDirectoryTransactionBoundary.allCases {
      let (root, _) = try await makeWorkflowVersioningFixture(self)
      let resolved = try resolveVersioningTarget(root: root)
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

      XCTAssertThrowsError(try coordinator.commit(
        target: resolved.identity,
        historyRoot: resolved.historyRoot,
        kind: .apply,
        expectedBeforeBundleDigest: before.bundleDigest,
        expectedAfterBundleDigest: expected,
        preOperationSnapshotId: snapshot.snapshotId
      ) { staging in
        try updated.write(to: staging.appendingPathComponent("workflow.json"), options: .atomic)
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
        "--scope", "project", "--working-dir", root.path, "--output", "json"
      ])
      XCTAssertEqual(response.exitCode, .success, "\(boundary.rawValue): \(response.stdout)")
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
