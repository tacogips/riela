import Darwin
import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class WorkflowRound7AdversarialTests: XCTestCase {
  func testPublishedGenerationPayloadSidecarAndDirectoryAreNonWritable() async throws {
    let fixture = try await transactionFixture()
    let result = try commitNoOp(fixture)
    let generation = try latestGeneration(result.transactionId, historyRoot: fixture.historyRoot)

    try assertNonWritable(generation)
    try assertNonWritable(generation.appendingPathComponent("record.json"))
    try assertNonWritable(generation.appendingPathComponent("record.sha256"))
  }

  func testGenerationReadRejectsPayloadRewriteEvenWhenModeIsRestored() async throws {
    let fixture = try await transactionFixture()
    let result = try commitNoOp(fixture)
    let generation = try latestGeneration(result.transactionId, historyRoot: fixture.historyRoot)
    let payload = generation.appendingPathComponent("record.json")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: payload.path)
    try Data("tampered".utf8).write(to: payload)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: payload.path)

    XCTAssertThrowsError(try readTransaction(result.transactionId, historyRoot: fixture.historyRoot))
  }

  func testGenerationReadRejectsWritablePayloadAndDirectoryModes() async throws {
    let fixture = try await transactionFixture()
    let result = try commitNoOp(fixture)
    let generation = try latestGeneration(result.transactionId, historyRoot: fixture.historyRoot)
    let payload = generation.appendingPathComponent("record.json")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: payload.path)
    XCTAssertThrowsError(try readTransaction(result.transactionId, historyRoot: fixture.historyRoot))
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: payload.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: generation.path)
    XCTAssertThrowsError(try readTransaction(result.transactionId, historyRoot: fixture.historyRoot))
  }

  func testGenerationTransitionRejectsRewrittenVerificationAndRemovedDiagnostics() async throws {
    let fixture = try await transactionFixture()
    let coordinator = WorkflowDirectoryTransactionCoordinator(
      auditStore: FileWorkflowTransactionAuditStore(),
      boundaryHook: { boundary in
        if boundary == .preparedRecord { throw WorkflowDirectoryInjectedInterruption(boundary: boundary) }
      }
    )
    XCTAssertThrowsError(try coordinator.commit(
      target: fixture.target,
      historyRoot: fixture.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: fixture.inventory.bundleDigest,
      expectedAfterBundleDigest: fixture.inventory.bundleDigest,
      preOperationSnapshotId: fixture.snapshot.snapshotId
    ) { _ in })
    let transactionId = try onlyTransactionId(historyRoot: fixture.historyRoot)
    let logical = fixture.historyRoot.appendingPathComponent("transactions/\(transactionId).json")
    var record = try readTransaction(transactionId, historyRoot: fixture.historyRoot)
    XCTAssertFalse(record.verification.isEmpty)
    record.verification[0].diagnosticSummary = "rewritten evidence"
    XCTAssertThrowsError(try WorkflowTransactionGenerationStore.write(
      record,
      logicalURL: logical,
      historyRoot: fixture.historyRoot,
      betweenPayloadAndSidecar: {}
    ))

    record = try readTransaction(transactionId, historyRoot: fixture.historyRoot)
    record.diagnostics = ["durable diagnostic"]
    try WorkflowTransactionGenerationStore.write(
      record,
      logicalURL: logical,
      historyRoot: fixture.historyRoot,
      betweenPayloadAndSidecar: {}
    )
    record.diagnostics = []
    XCTAssertThrowsError(try WorkflowTransactionGenerationStore.write(
      record,
      logicalURL: logical,
      historyRoot: fixture.historyRoot,
      betweenPayloadAndSidecar: {}
    ))
  }

  func testSnapshotRejectsUnexpectedFIFO() async throws {
    try await assertSnapshotRejectsSpecialEntry(name: "unexpected-fifo") { url in
      guard mkfifo(url.path, S_IRUSR | S_IWUSR) == 0 else { throw POSIXError(.EIO) }
    }
  }

  func testProposalRejectsUnexpectedFIFO() async throws {
    try await assertProposalRejectsSpecialEntry(name: "unexpected-fifo") { url in
      guard mkfifo(url.path, S_IRUSR | S_IWUSR) == 0 else { throw POSIXError(.EIO) }
    }
  }

  func testChangeSetRejectsUnexpectedFIFO() async throws {
    try await assertChangeSetRejectsSpecialEntry(name: "unexpected-fifo") { url in
      guard mkfifo(url.path, S_IRUSR | S_IWUSR) == 0 else { throw POSIXError(.EIO) }
    }
  }

  func testSnapshotRejectsUnexpectedUnixSocket() async throws {
    try await assertSnapshotRejectsSpecialEntry(name: "unexpected.sock", create: createUnixSocket)
  }

  func testProposalRejectsUnexpectedUnixSocket() async throws {
    try await assertProposalRejectsSpecialEntry(name: "unexpected.sock", create: createUnixSocket)
  }

  func testChangeSetRejectsUnexpectedUnixSocket() async throws {
    try await assertChangeSetRejectsSpecialEntry(name: "unexpected.sock", create: createUnixSocket)
  }

  func testSnapshotRejectsUnexpectedDirectory() async throws {
    try await assertSnapshotRejectsSpecialEntry(name: "unexpected-directory") { url in
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
  }

  func testProposalRejectsUnexpectedDirectory() async throws {
    try await assertProposalRejectsSpecialEntry(name: "unexpected-directory") { url in
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
  }

  func testChangeSetRejectsUnexpectedDirectory() async throws {
    try await assertChangeSetRejectsSpecialEntry(name: "unexpected-directory") { url in
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
  }

  func testImmutableTargetPreflightAttemptIsDurablyFailedWithoutMutation() async throws {
    let fixture = try await transactionFixture()
    var immutable = fixture.target
    immutable.sourceMutable = false
    XCTAssertThrowsError(try commitNoOp(fixture, target: immutable))
    try assertOnlyFailedAttempt(historyRoot: fixture.historyRoot)
  }

  func testLockedTargetPreflightAttemptIsDurablyFailedWithoutMutation() async throws {
    let fixture = try await transactionFixture()
    let lock = try acquireWorkflowTargetLock(target: fixture.target, owner: "adversarial-holder")
    defer { releaseWorkflowTargetLock(lock) }
    XCTAssertThrowsError(try commitNoOp(fixture))
    try assertOnlyFailedAttempt(historyRoot: fixture.historyRoot)
  }

  func testPreexistingTransactionPreflightAttemptIsDurablyFailedWithoutMutation() async throws {
    let fixture = try await transactionFixture()
    let interrupted = WorkflowDirectoryTransactionCoordinator(
      auditStore: FileWorkflowTransactionAuditStore(),
      boundaryHook: { boundary in
        if boundary == .transactionRecord { throw WorkflowDirectoryInjectedInterruption(boundary: boundary) }
      }
    )
    XCTAssertThrowsError(try interrupted.commit(
      target: fixture.target,
      historyRoot: fixture.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: fixture.inventory.bundleDigest,
      expectedAfterBundleDigest: fixture.inventory.bundleDigest,
      preOperationSnapshotId: fixture.snapshot.snapshotId
    ) { _ in })
    XCTAssertThrowsError(try commitNoOp(fixture))
    XCTAssertTrue(try loadAttempts(historyRoot: fixture.historyRoot).contains { $0.status == .failed })
  }

  func testSnapshotAuthorityMismatchPreflightAttemptIsDurablyFailedWithoutMutation() async throws {
    let fixture = try await transactionFixture()
    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator().commit(
      target: fixture.target,
      historyRoot: fixture.historyRoot,
      kind: .restore,
      expectedBeforeBundleDigest: String(repeating: "0", count: 64),
      expectedAfterBundleDigest: fixture.inventory.bundleDigest,
      preOperationSnapshotId: fixture.snapshot.snapshotId
    ) { _ in })
    try assertOnlyFailedAttempt(historyRoot: fixture.historyRoot)
  }

  func testLockedDigestDriftPreflightAttemptIsDurablyFailedWithoutCoordinatorMutation() async throws {
    let fixture = try await transactionFixture()
    let workflow = URL(fileURLWithPath: fixture.target.workflowDirectory).appendingPathComponent("workflow.json")
    var drifted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workflow)) as? [String: Any])
    drifted["description"] = "external locked drift"
    let driftedBytes = try JSONSerialization.data(withJSONObject: drifted, options: [.sortedKeys])
    let coordinator = WorkflowDirectoryTransactionCoordinator(
      auditStore: FileWorkflowTransactionAuditStore(),
      lockedPreflightHook: { try driftedBytes.write(to: workflow, options: .atomic) }
    )
    XCTAssertThrowsError(try coordinator.commit(
      target: fixture.target,
      historyRoot: fixture.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: fixture.inventory.bundleDigest,
      expectedAfterBundleDigest: fixture.inventory.bundleDigest,
      preOperationSnapshotId: fixture.snapshot.snapshotId
    ) { _ in })
    XCTAssertEqual(try Data(contentsOf: workflow), driftedBytes)
    try assertOnlyFailedAttempt(historyRoot: fixture.historyRoot)
  }

  func testPreflightAuditWriteFailureFailsClosedBeforeMutation() async throws {
    let fixture = try await transactionFixture()
    let coordinator = WorkflowDirectoryTransactionCoordinator(
      auditStore: FileWorkflowTransactionAuditStore(),
      preflightAttemptStore: ThrowingPreflightAttemptStore()
    )
    XCTAssertThrowsError(try coordinator.commit(
      target: fixture.target,
      historyRoot: fixture.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: fixture.inventory.bundleDigest,
      expectedAfterBundleDigest: fixture.inventory.bundleDigest,
      preOperationSnapshotId: fixture.snapshot.snapshotId
    ) { _ in XCTFail("mutation closure must not execute when attempt audit fails") })
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.historyRoot.appendingPathComponent("transactions").path))
  }

  func testPreflightAttemptPersistenceIsIdempotentOnlyForExactIntent() async throws {
    let fixture = try await transactionFixture()
    let store = FileWorkflowPreflightAttemptStore()
    var attempt = WorkflowPreflightAttemptRecord(
      attemptId: "attempt-idempotency-round7",
      transactionId: "transaction-idempotency-round7",
      kind: .apply,
      target: fixture.target,
      expectedBeforeBundleDigest: fixture.inventory.bundleDigest,
      expectedAfterBundleDigest: fixture.inventory.bundleDigest,
      preOperationSnapshotId: fixture.snapshot.snapshotId,
      status: .attempted,
      mutationOccurred: false,
      diagnostics: [],
      startedAt: Date(timeIntervalSince1970: 0)
    )
    try store.persist(attempt, historyRoot: fixture.historyRoot)
    try store.persist(attempt, historyRoot: fixture.historyRoot)
    attempt.expectedAfterBundleDigest = String(repeating: "0", count: 64)
    XCTAssertThrowsError(try store.persist(attempt, historyRoot: fixture.historyRoot)) { error in
      XCTAssertTrue(String(describing: error).contains("changed immutable intent"))
    }
  }

  func testFailedPreflightAuditFinalizationFailureFailsClosedAndRetainsAttempt() async throws {
    let fixture = try await transactionFixture()
    var immutable = fixture.target
    immutable.sourceMutable = false
    let store = FailSecondPreflightAttemptStore()
    let coordinator = WorkflowDirectoryTransactionCoordinator(
      auditStore: FileWorkflowTransactionAuditStore(),
      preflightAttemptStore: store
    )
    XCTAssertThrowsError(try coordinator.commit(
      target: immutable,
      historyRoot: fixture.historyRoot,
      kind: .restore,
      expectedBeforeBundleDigest: fixture.inventory.bundleDigest,
      expectedAfterBundleDigest: fixture.inventory.bundleDigest,
      preOperationSnapshotId: fixture.snapshot.snapshotId
    ) { _ in XCTFail("immutable preflight must not mutate") }) { error in
      XCTAssertTrue(String(describing: error).contains("failure audit persistence also failed"))
    }
    let attempts = try loadAttempts(historyRoot: fixture.historyRoot)
    XCTAssertEqual(attempts.map(\.status), [.attempted])
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.historyRoot.appendingPathComponent("transactions").path))
  }
}

private extension WorkflowRound7AdversarialTests {
  struct TransactionFixture {
    var target: WorkflowBundleIdentity
    var historyRoot: URL
    var inventory: WorkflowBundleInventory
    var snapshot: WorkflowBundleSnapshotManifest
  }

  func transactionFixture() async throws -> TransactionFixture {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveVersioningTarget(root: root)
    let inventory = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: inventory)
    return TransactionFixture(
      target: resolved.identity,
      historyRoot: resolved.historyRoot,
      inventory: inventory,
      snapshot: snapshot
    )
  }

  func commitNoOp(
    _ fixture: TransactionFixture,
    target: WorkflowBundleIdentity? = nil
  ) throws -> WorkflowDirectoryTransactionResult {
    try WorkflowDirectoryTransactionCoordinator().commit(
      target: target ?? fixture.target,
      historyRoot: fixture.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: fixture.inventory.bundleDigest,
      expectedAfterBundleDigest: fixture.inventory.bundleDigest,
      preOperationSnapshotId: fixture.snapshot.snapshotId
    ) { _ in }
  }

  func latestGeneration(_ transactionId: String, historyRoot: URL) throws -> URL {
    let directory = historyRoot.appendingPathComponent("transactions/\(transactionId).json.generations")
    return try XCTUnwrap(try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ).filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }.last)
  }

  func assertNonWritable(_ url: URL) throws {
    var status = stat()
    XCTAssertEqual(lstat(url.path, &status), 0)
    XCTAssertEqual(status.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH), 0)
  }

  func readTransaction(_ transactionId: String, historyRoot: URL) throws -> WorkflowDirectoryTransactionRecord {
    try WorkflowHistorySecurePersistence.readCanonical(
      WorkflowDirectoryTransactionRecord.self,
      from: historyRoot.appendingPathComponent("transactions/\(transactionId).json"),
      historyRoot: historyRoot
    )
  }

  func onlyTransactionId(historyRoot: URL) throws -> String {
    let transactions = historyRoot.appendingPathComponent("transactions")
    let entry = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
      at: transactions,
      includingPropertiesForKeys: nil
    ).first { $0.lastPathComponent.hasSuffix(".json.generations") })
    return String(entry.lastPathComponent.dropLast(".json.generations".count))
  }

  func assertSnapshotRejectsSpecialEntry(
    name: String,
    create: (URL) throws -> Void
  ) async throws {
    let fixture = try await transactionFixture()
    let directory = fixture.historyRoot.appendingPathComponent("snapshots/\(fixture.snapshot.snapshotId)")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    try create(directory.appendingPathComponent(name))
    XCTAssertThrowsError(try WorkflowHistoryStore(root: fixture.historyRoot).loadSnapshot(
      fixture.snapshot.snapshotId,
      expectedIdentity: fixture.target
    ))
  }

  func assertProposalRejectsSpecialEntry(
    name: String,
    create: (URL) throws -> Void
  ) async throws {
    let fixture = try await transactionFixture()
    var proposal = WorkflowChangeProposal(
      proposalId: "proposal-round7-\(UUID().uuidString.lowercased())",
      sourceSessionId: "session-round7",
      target: fixture.target,
      beforeBundleDigest: fixture.inventory.bundleDigest,
      operations: [],
      expectedAfterBundleDigest: fixture.inventory.bundleDigest,
      rationale: "round seven topology",
      createdAt: Date(timeIntervalSince1970: 0),
      proposalDigest: String(repeating: "0", count: 64)
    )
    proposal.proposalDigest = try WorkflowHistoryCanonicalCoding.proposalDigest(proposal)
    let store = WorkflowChangeSetStore(root: fixture.historyRoot)
    try store.publishProposal(proposal, contentObjects: [:])
    let directory = fixture.historyRoot.appendingPathComponent("proposals/\(proposal.proposalId)")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    try create(directory.appendingPathComponent(name))
    XCTAssertThrowsError(try store.loadProposal(proposal.proposalId, expectedIdentity: fixture.target))
  }

  func assertChangeSetRejectsSpecialEntry(
    name: String,
    create: (URL) throws -> Void
  ) async throws {
    let fixture = try await transactionFixture()
    var proposal = WorkflowChangeProposal(
      proposalId: "proposal-change-set-round7-\(UUID().uuidString.lowercased())",
      sourceSessionId: "session-round7",
      target: fixture.target,
      beforeBundleDigest: fixture.inventory.bundleDigest,
      operations: [],
      expectedAfterBundleDigest: fixture.inventory.bundleDigest,
      rationale: "round seven change-set topology",
      createdAt: Date(timeIntervalSince1970: 0),
      proposalDigest: String(repeating: "0", count: 64)
    )
    proposal.proposalDigest = try WorkflowHistoryCanonicalCoding.proposalDigest(proposal)
    let store = WorkflowChangeSetStore(root: fixture.historyRoot)
    try store.publishProposal(proposal, contentObjects: [:])
    let review = WorkflowChangeSetReviewEvidence(
      gateId: "review-gate",
      gateResultId: "gate-result-round7",
      decision: .accepted,
      reviewedProposalId: proposal.proposalId,
      reviewedProposalDigest: proposal.proposalDigest,
      reviewedBeforeBundleDigest: proposal.beforeBundleDigest,
      reviewerStepId: "review-step",
      reviewerStepExecutionId: "review-execution",
      reviewedAt: Date(timeIntervalSince1970: 0)
    )
    let changeSet = try store.finalize(
      proposalId: proposal.proposalId,
      expectedIdentity: fixture.target,
      review: review
    )
    let directory = fixture.historyRoot.appendingPathComponent("change-sets/\(changeSet.changeSetId)")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    try create(directory.appendingPathComponent(name))
    XCTAssertThrowsError(try store.loadChangeSet(changeSet.changeSetId, expectedIdentity: fixture.target))
  }

  func createUnixSocket(at url: URL) throws {
    let socketURL = URL(fileURLWithPath: "/tmp/riela-round7-\(UUID().uuidString.lowercased()).sock")
    defer { try? FileManager.default.removeItem(at: socketURL) }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    defer { _ = close(descriptor) }
    var address = sockaddr_un()
    let path = Array(socketURL.path.utf8) + [0]
    guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: path) }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + path.count)
    address.sun_len = UInt8(length)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, length) }
    }
    guard result == 0 else { throw POSIXError(.EIO) }
    try FileManager.default.moveItem(at: socketURL, to: url)
  }

  func loadAttempts(historyRoot: URL) throws -> [WorkflowPreflightAttemptRecord] {
    let directory = historyRoot.appendingPathComponent("attempts")
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .map {
        try WorkflowHistorySecurePersistence.readCanonical(
          WorkflowPreflightAttemptRecord.self,
          from: $0,
          historyRoot: historyRoot
        )
      }
  }

  func assertOnlyFailedAttempt(historyRoot: URL) throws {
    let attempts = try loadAttempts(historyRoot: historyRoot)
    XCTAssertEqual(attempts.count, 1)
    XCTAssertEqual(attempts[0].status, .failed)
    XCTAssertFalse(attempts[0].mutationOccurred)
    XCTAssertFalse(attempts[0].diagnostics.isEmpty)
    XCTAssertNotNil(attempts[0].completedAt)
  }
}

private struct ThrowingPreflightAttemptStore: WorkflowPreflightAttemptPersisting {
  func persist(_ record: WorkflowPreflightAttemptRecord, historyRoot: URL) throws {
    throw CLIUsageError("injected preflight attempt audit failure")
  }
}

private final class FailSecondPreflightAttemptStore: WorkflowPreflightAttemptPersisting, @unchecked Sendable {
  private let lock = NSLock()
  private var writes = 0

  func persist(_ record: WorkflowPreflightAttemptRecord, historyRoot: URL) throws {
    lock.lock()
    writes += 1
    let currentWrite = writes
    lock.unlock()
    guard currentWrite == 1 else { throw CLIUsageError("injected failed-attempt audit finalization failure") }
    try FileWorkflowPreflightAttemptStore().persist(record, historyRoot: historyRoot)
  }
}
