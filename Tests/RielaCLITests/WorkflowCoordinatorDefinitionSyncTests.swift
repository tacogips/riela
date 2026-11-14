import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore
@testable import RielaWorkflowRegistry

final class WorkflowCoordinatorDefinitionSyncTests: XCTestCase {
  func testDefinitionImportReplaysPendingIntentBeforeImport() async throws {
    let fixture = try await makeCoordinatorFixture()
    let coordinator = WorkflowDirectoryTransactionCoordinator()
    let result = try coordinator.commit(target: fixture.target, historyRoot: fixture.historyRoot, kind: .apply,
      expectedBeforeBundleDigest: fixture.beforeDigest, expectedAfterBundleDigest: fixture.afterDigest,
      preOperationSnapshotId: fixture.snapshotId,
      definitionSync: fixture.sync(recorder: CoordinatorFailingRecorder(base: fixture.recorder))) { staging in
        try fixture.updated.write(to: staging.appendingPathComponent("workflow.json"), options: .atomic)
      }
    XCTAssertNotNil(result.definitionSyncError)
    let root = URL(fileURLWithPath: fixture.store.rootDirectory).deletingLastPathComponent()
    let response = CLIRuntimeEnvironment.$overrides.withValue(mutableWorkflowVersioningEnvironment(root: root)) {
      WorkflowDefinitionCommand().run(.init(arguments: ["import", fixture.target.workflowId, "--scope", "user",
        "--working-dir", root.path, "--session-store", fixture.store.rootDirectory, "--output", "json"]))
    }
    XCTAssertEqual(response.exitCode, .success, response.stdout + response.stderr)
    XCTAssertTrue(try WorkflowDefinitionSyncIntentStore(historyRoot: fixture.historyRoot).pending().isEmpty)
    let audit = try XCTUnwrap(fixture.store.history(workflowName: fixture.target.workflowId).first { $0.operation == .selfImprove })
    XCTAssertEqual(audit.reason, "coordinator test")
    XCTAssertTrue(audit.evidence.contains(.init(kind: .fileTransaction, id: result.transactionId)))
    XCTAssertTrue(response.stdout.contains("unchanged"))
  }

  func testCoordinatorReplayAfterDatabaseCommitDoesNotDuplicateHistory() async throws {
    let fixture = try await makeCoordinatorFixture()
    let coordinator = WorkflowDirectoryTransactionCoordinator()
    let recorder = CoordinatorFailingRecorder(base: fixture.recorder, commitBeforeFailure: true)
    let result = try coordinator.commit(target: fixture.target, historyRoot: fixture.historyRoot, kind: .apply,
      expectedBeforeBundleDigest: fixture.beforeDigest, expectedAfterBundleDigest: fixture.afterDigest,
      preOperationSnapshotId: fixture.snapshotId, definitionSync: fixture.sync(recorder: recorder)) { staging in
        try fixture.updated.write(to: staging.appendingPathComponent("workflow.json"), options: .atomic)
      }
    XCTAssertNotNil(result.definitionSyncError)
    XCTAssertEqual(try WorkflowDefinitionSyncIntentStore(historyRoot: fixture.historyRoot).pending().count, 1)
    let history = try fixture.store.history(workflowName: fixture.target.workflowId)
    XCTAssertEqual(history.filter { $0.operation == .selfImprove }.count, 1)
    try coordinator.replayDefinitionSyncIntents(target: fixture.target, historyRoot: fixture.historyRoot, recorder: fixture.recorder)
    XCTAssertEqual(try fixture.store.history(workflowName: fixture.target.workflowId), history)
    XCTAssertTrue(try WorkflowDefinitionSyncIntentStore(historyRoot: fixture.historyRoot).pending().isEmpty)
  }

  func testPinRootClaimRecoversWithoutRegression() async throws {
    let fixture = try await makeCoordinatorFixture(planLocal: true)
    let workingRoot = URL(fileURLWithPath: fixture.store.rootDirectory).deletingLastPathComponent()
    let sessionRoot = workingRoot.appendingPathComponent("separate-sessions")
    try CLIRuntimeEnvironment.$overrides.withValue(mutableWorkflowVersioningEnvironment(root: workingRoot)) {
      _ = try fixture.recorder.captureBaselineIfAbsent(workflowName: fixture.target.workflowId,
        liveDirectory: URL(fileURLWithPath: fixture.target.ownershipRoot), sourceScope: .user,
        transactionId: "baseline", actor: .init(kind: .cli), operation: .selfImprove, bundleSnapshotBefore: fixture.snapshotId)
      let current = try XCTUnwrap(fixture.store.current(workflowName: fixture.target.workflowId))
      let proposals = WorkflowRollbackProposalStore(rootDirectory: fixture.store.rootDirectory)
      let proposal = try proposals.insertIfAbsent(.init(workflowName: fixture.target.workflowId,
        regressedVersionId: current.version.versionId, rollbackToVersionId: current.version.versionId,
        mode: .bundle, baselineSessionId: "base", targetSessionId: "target", regressions: [],
        policy: .approvalRequired, status: .pending, createdActor: .init(kind: .system))).proposal
      _ = try proposals.claim(proposalId: proposal.proposalId, expectedHeadVersionId: current.version.versionId,
        claimTransactionId: "interrupted")
      let date = Date(timeIntervalSince1970: 1_700_000_000)
      let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionRoot.path))
      for id in ["base", "target"] {
        let pin = WorkflowDefinitionSource(kind: .store, workflowName: fixture.target.workflowId,
          versionId: current.version.versionId, storeRoot: fixture.store.rootDirectory, digest: current.version.documentDigest,
          sourcePath: fixture.target.ownershipRoot, sourceScope: "user")
        let session = WorkflowSession(workflowId: fixture.target.workflowId, sessionId: id, status: .completed,
          entryStepId: "first", createdAt: date, updatedAt: date, definitionSource: pin)
        try CLIWorkflowSessionStore(rootDirectory: sessionRoot.path).save(.init(workflowName: fixture.target.workflowId,
          session: session, resolution: .init(workflowName: fixture.target.workflowId, scope: .user, workingDirectory: workingRoot.path)))
        var snapshot = try runtime.load(sessionId: id)
        snapshot.loopEvidence = LoopEvidenceManifest(schemaVersion: 1, manifestId: "evidence-\(id)",
          workflowId: fixture.target.workflowId, sessionId: id,
          workflowSource: .init(scope: "user", kind: "workflow-directory", mutable: true), policy: .init(),
          redaction: .init(policyName: "summary-only", status: "clean"), createdAt: date, updatedAt: date)
        try runtime.save(snapshot)
      }
      try runtime.setLoopBaseline(.init(workflowId: fixture.target.workflowId, sessionId: "base", setAt: date))
      let service = WorkflowRegressionRollbackService(workingDirectory: workingRoot.path, sessionStore: sessionRoot.path, scope: .user)
      let result = try service.check(workflowName: fixture.target.workflowId, targetSessionId: "target", actor: .init(kind: .system))
      XCTAssertEqual(result.outcome, .noRegression)
      XCTAssertEqual(try proposals.proposal(id: proposal.proposalId)?.status, .pending)
      XCTAssertEqual(try fixture.store.head(workflowName: fixture.target.workflowId)?.currentVersionId, current.version.versionId)
    }
  }

  func testCoordinatorRecoveryReleasesInterruptedRollbackClaim() async throws {
    let fixture = try await makeCoordinatorFixture()
    _ = try fixture.recorder.captureBaselineIfAbsent(workflowName: fixture.target.workflowId,
      liveDirectory: URL(fileURLWithPath: fixture.target.ownershipRoot), sourceScope: .user,
      transactionId: "baseline", actor: .init(kind: .cli), operation: .selfImprove, bundleSnapshotBefore: fixture.snapshotId)
    let head = try XCTUnwrap(fixture.store.head(workflowName: fixture.target.workflowId)?.currentVersionId)
    let root = try fixture.recorder.storeRoot(workflowName: fixture.target.workflowId, sourceScope: .user)
    let proposals = WorkflowRollbackProposalStore(rootDirectory: root)
    let proposal = try proposals.insertIfAbsent(.init(workflowName: fixture.target.workflowId,
      regressedVersionId: head, rollbackToVersionId: head, mode: .bundle, baselineSessionId: "baseline",
      targetSessionId: "target", regressions: [], policy: .approvalRequired, status: .pending,
      createdActor: .init(kind: .user))).proposal
    var sync = fixture.sync(recorder: fixture.recorder)
    sync.attribution = .init(operation: .rollback, actor: .init(kind: .user), reason: "rollback",
      expectedHeadVersionId: head, rollbackProposalId: proposal.proposalId)
    sync.beforePublication = { transactionId in
      _ = try proposals.claim(proposalId: proposal.proposalId, expectedHeadVersionId: head, claimTransactionId: transactionId)
    }
    let coordinator = WorkflowDirectoryTransactionCoordinator(auditStore: FileWorkflowTransactionAuditStore(), boundaryHook: { boundary in
      if boundary == .committingRecord { throw WorkflowDirectoryInjectedInterruption(boundary: boundary) }
    })
    XCTAssertThrowsError(try coordinator.commit(target: fixture.target, historyRoot: fixture.historyRoot, kind: .restore,
      expectedBeforeBundleDigest: fixture.beforeDigest, expectedAfterBundleDigest: fixture.afterDigest,
      preOperationSnapshotId: fixture.snapshotId, definitionSync: sync) { staging in
        try fixture.updated.write(to: staging.appendingPathComponent("workflow.json"), options: .atomic)
      })
    XCTAssertEqual(try proposals.proposal(id: proposal.proposalId)?.status, .applying)
    _ = try WorkflowDirectoryTransactionCoordinator().recover(historyRoot: fixture.historyRoot,
      target: fixture.target, recorder: fixture.recorder)
    XCTAssertEqual(try proposals.proposal(id: proposal.proposalId)?.status, .pending)
    XCTAssertEqual(try WorkflowHistoryIdentityResolver.inventory(for: fixture.target).bundleDigest, fixture.beforeDigest)
    XCTAssertTrue(try WorkflowDefinitionSyncIntentStore(historyRoot: fixture.historyRoot).pending().isEmpty)
  }

  func testCoordinatorReplaysPublishedRollbackClaim() async throws {
    let fixture = try await makeCoordinatorFixture(planLocal: true)
    _ = try fixture.recorder.captureBaselineIfAbsent(workflowName: fixture.target.workflowId,
      liveDirectory: URL(fileURLWithPath: fixture.target.ownershipRoot), sourceScope: .user,
      transactionId: "baseline", actor: .init(kind: .cli), operation: .selfImprove, bundleSnapshotBefore: fixture.snapshotId)
    let head = try XCTUnwrap(fixture.store.head(workflowName: fixture.target.workflowId)?.currentVersionId)
    let proposals = WorkflowRollbackProposalStore(rootDirectory: fixture.store.rootDirectory)
    let proposal = try proposals.insertIfAbsent(.init(workflowName: fixture.target.workflowId,
      regressedVersionId: head, rollbackToVersionId: head, mode: .bundle, baselineSessionId: "baseline",
      targetSessionId: "target", regressions: [], policy: .approvalRequired, status: .pending,
      createdActor: .init(kind: .user))).proposal
    var sync = fixture.sync(recorder: CoordinatorFailingRecorder(base: fixture.recorder))
    sync.attribution = .init(operation: .rollback, actor: .init(kind: .user), reason: "rollback",
      expectedHeadVersionId: head, rollbackProposalId: proposal.proposalId)
    sync.beforePublication = { transactionId in
      _ = try proposals.claim(proposalId: proposal.proposalId, expectedHeadVersionId: head, claimTransactionId: transactionId)
    }
    let coordinator = WorkflowDirectoryTransactionCoordinator()
    let result = try coordinator.commit(target: fixture.target, historyRoot: fixture.historyRoot, kind: .restore,
      expectedBeforeBundleDigest: fixture.beforeDigest, expectedAfterBundleDigest: fixture.afterDigest,
      preOperationSnapshotId: fixture.snapshotId, definitionSync: sync) { staging in
        try fixture.updated.write(to: staging.appendingPathComponent("workflow.json"), options: .atomic)
      }
    XCTAssertNotNil(result.definitionSyncError)
    XCTAssertEqual(try WorkflowHistoryIdentityResolver.inventory(for: fixture.target).bundleDigest, fixture.afterDigest)
    XCTAssertEqual(try proposals.proposal(id: proposal.proposalId)?.status, .applying)
    XCTAssertEqual(try WorkflowDefinitionSyncIntentStore(historyRoot: fixture.historyRoot).pending().count, 1)
    _ = try coordinator.recover(historyRoot: fixture.historyRoot, target: fixture.target, recorder: fixture.recorder)
    let applied = try XCTUnwrap(proposals.proposal(id: proposal.proposalId))
    XCTAssertEqual(applied.status, .applied)
    let history = try fixture.store.history(workflowName: fixture.target.workflowId)
    let rollbacks = history.filter { $0.operation == .rollback }
    XCTAssertEqual(rollbacks.count, 1)
    XCTAssertTrue(try XCTUnwrap(rollbacks.first).evidence.contains(.init(kind: .fileTransaction, id: result.transactionId)))
    XCTAssertTrue(try WorkflowDefinitionSyncIntentStore(historyRoot: fixture.historyRoot).pending().isEmpty)
    _ = try coordinator.recover(historyRoot: fixture.historyRoot, target: fixture.target, recorder: fixture.recorder)
    XCTAssertEqual(try fixture.store.history(workflowName: fixture.target.workflowId), history)
  }

  func testCoordinatorSyncFailureKeepsPublishedFilesAndReplaysOnce() async throws {
    let fixture = try await makeCoordinatorFixture()
    let original = try Data(contentsOf: URL(fileURLWithPath: fixture.target.ownershipRoot).appendingPathComponent("workflow.json"))
    let failing = CoordinatorFailingRecorder(base: fixture.recorder)
    let coordinator = WorkflowDirectoryTransactionCoordinator()
    let result = try coordinator.commit(target: fixture.target, historyRoot: fixture.historyRoot, kind: .apply,
      expectedBeforeBundleDigest: fixture.beforeDigest, expectedAfterBundleDigest: fixture.afterDigest,
      preOperationSnapshotId: fixture.snapshotId, definitionSync: fixture.sync(recorder: failing)) { staging in
        try fixture.updated.write(to: staging.appendingPathComponent("workflow.json"), options: .atomic)
      }
    XCTAssertNotNil(result.definitionSyncError)
    XCTAssertEqual(try WorkflowHistoryIdentityResolver.inventory(for: fixture.target).bundleDigest, fixture.afterDigest)
    let pending = try WorkflowDefinitionSyncIntentStore(historyRoot: fixture.historyRoot).pending()
    XCTAssertEqual(pending.count, 1)
    XCTAssertEqual(pending.first?.transactionId, result.transactionId)
    let published = try WorkflowHistoryIdentityResolver.inventory(for: fixture.target)
    let secondSnapshot = try WorkflowHistoryStore(root: fixture.historyRoot).createSnapshot(inventory: published)
    let beforeReplayHistory = try fixture.store.history(workflowName: fixture.target.workflowId)
    XCTAssertThrowsError(try coordinator.commit(target: fixture.target, historyRoot: fixture.historyRoot, kind: .apply,
      expectedBeforeBundleDigest: published.bundleDigest, expectedAfterBundleDigest: published.bundleDigest,
      preOperationSnapshotId: secondSnapshot.snapshotId, definitionSync: fixture.sync(recorder: failing)) { _ in }) { error in
        XCTAssertEqual((error as? WorkflowRegistryError)?.code, .definitionSyncPending)
      }
    XCTAssertEqual(try WorkflowHistoryIdentityResolver.inventory(for: fixture.target).bundleDigest, published.bundleDigest)
    XCTAssertEqual(try fixture.store.history(workflowName: fixture.target.workflowId), beforeReplayHistory)
    XCTAssertEqual(try WorkflowDefinitionSyncIntentStore(historyRoot: fixture.historyRoot).pending(), pending)

    let second = try coordinator.commit(target: fixture.target, historyRoot: fixture.historyRoot, kind: .restore,
      expectedBeforeBundleDigest: fixture.afterDigest, expectedAfterBundleDigest: fixture.beforeDigest,
      preOperationSnapshotId: secondSnapshot.snapshotId, definitionSync: fixture.sync(recorder: fixture.recorder)) { staging in
        try original.write(to: staging.appendingPathComponent("workflow.json"), options: .atomic)
      }
    XCTAssertNil(second.definitionSyncError)
    let history = try fixture.store.history(workflowName: fixture.target.workflowId)
    XCTAssertEqual(history.count, 3)
    let audit = try XCTUnwrap(history.first { $0.evidence.contains(.init(kind: .fileTransaction, id: result.transactionId)) })
    let secondAudit = try XCTUnwrap(history.first { $0.evidence.contains(.init(kind: .fileTransaction, id: second.transactionId)) })
    XCTAssertEqual(secondAudit.previousVersionId, audit.versionId)
    XCTAssertEqual(audit.reason, "coordinator test")
    XCTAssertTrue(audit.evidence.contains(.init(kind: .fileTransaction, id: result.transactionId)))
    XCTAssertTrue(try WorkflowDefinitionSyncIntentStore(historyRoot: fixture.historyRoot).pending().isEmpty)
    try coordinator.replayDefinitionSyncIntents(target: fixture.target, historyRoot: fixture.historyRoot, recorder: fixture.recorder)
    XCTAssertEqual(try fixture.store.history(workflowName: fixture.target.workflowId).count, history.count)
  }

  func testCoordinatorInterruptionBeforePublicationDiscardsIntent() async throws {
    let fixture = try await makeCoordinatorFixture()
    let coordinator = WorkflowDirectoryTransactionCoordinator(auditStore: FileWorkflowTransactionAuditStore(), boundaryHook: { boundary in
      if boundary == .committingRecord { throw WorkflowDirectoryInjectedInterruption(boundary: boundary) }
    })
    XCTAssertThrowsError(try coordinator.commit(target: fixture.target, historyRoot: fixture.historyRoot, kind: .apply,
      expectedBeforeBundleDigest: fixture.beforeDigest, expectedAfterBundleDigest: fixture.afterDigest,
      preOperationSnapshotId: fixture.snapshotId, definitionSync: fixture.sync(recorder: fixture.recorder)) { staging in
        try fixture.updated.write(to: staging.appendingPathComponent("workflow.json"), options: .atomic)
      })
    XCTAssertEqual(try WorkflowDefinitionSyncIntentStore(historyRoot: fixture.historyRoot).pending().count, 1)
    _ = try WorkflowDirectoryTransactionCoordinator().recover(historyRoot: fixture.historyRoot,
      target: fixture.target, recorder: fixture.recorder)
    XCTAssertEqual(try WorkflowHistoryIdentityResolver.inventory(for: fixture.target).bundleDigest, fixture.beforeDigest)
    XCTAssertTrue(try WorkflowDefinitionSyncIntentStore(historyRoot: fixture.historyRoot).pending().isEmpty)
    let history = try fixture.store.history(workflowName: fixture.target.workflowId)
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history.first?.operation, .import)
  }

  func testFailedReplayPreservesIntentAndItsOriginalDocument() throws {
    let fixture = try makeFixture()
    try fixture.captureBaseline()
    try fixture.changePrompt("first change")
    let intent = try fixture.intent("transaction-first")
    try fixture.intents.write(intent)
    let failing = CoordinatorFailingRecorder(base: fixture.recorder)

    XCTAssertThrowsError(try fixture.intents.replayPending(recorder: failing, isCommitted: { _ in true }))
    XCTAssertEqual(try fixture.intents.pending(), [intent])
    try fixture.changePrompt("later unrelated change")
    let outcomes = try fixture.intents.replayPending(recorder: fixture.recorder, isCommitted: { _ in true })
    guard case let .versionWritten(version, audit, _) = try XCTUnwrap(outcomes.first) else {
      return XCTFail("expected a version on replay")
    }
    XCTAssertEqual(version.documentDigest, intent.documentDigest)
    XCTAssertEqual(audit.operation, .selfImprove)
    XCTAssertEqual(audit.reason, "original attribution")
    XCTAssertTrue(audit.evidence.contains(.init(kind: .fileTransaction, id: intent.transactionId)))
    XCTAssertTrue(try fixture.intents.pending().isEmpty)
    XCTAssertEqual(try fixture.intents.replayPending(recorder: fixture.recorder, isCommitted: { _ in true }).count, 0)
  }

  func testReplayAfterDatabaseCommitDoesNotDuplicateAudit() throws {
    let fixture = try makeFixture()
    try fixture.captureBaseline()
    try fixture.changePrompt("committed change")
    let intent = try fixture.intent("transaction-committed")
    try fixture.intents.write(intent)
    _ = try fixture.recorder.sync(intent)
    let historyCount = try fixture.store.history(workflowName: "flow").count

    XCTAssertTrue(try fixture.intents.replayPending(recorder: fixture.recorder, isCommitted: { _ in true }).isEmpty)
    XCTAssertEqual(try fixture.store.history(workflowName: "flow").count, historyCount)
    XCTAssertTrue(try fixture.intents.pending().isEmpty)
  }

  func testUncommittedIntentIsDiscardedWithoutSync() throws {
    let fixture = try makeFixture()
    try fixture.captureBaseline()
    try fixture.changePrompt("never published")
    let intent = try fixture.intent("transaction-abandoned")
    try fixture.intents.write(intent)
    let historyCount = try fixture.store.history(workflowName: "flow").count

    XCTAssertTrue(try fixture.intents.replayPending(recorder: fixture.recorder, isCommitted: { _ in false }).isEmpty)
    XCTAssertEqual(try fixture.store.history(workflowName: "flow").count, historyCount)
    XCTAssertTrue(try fixture.intents.pending().isEmpty)
  }

  func testBaselineDoesNotSuppressPendingChange() throws {
    let fixture = try makeFixture()
    try fixture.captureBaseline(transaction: "transaction-first")
    let baseline = try XCTUnwrap(fixture.store.head(workflowName: "flow")?.currentVersionId)
    try fixture.changePrompt("improved")
    let intent = try fixture.intent("transaction-first")
    XCTAssertFalse(try fixture.store.isChangeComplete(workflowName: "flow", operation: .selfImprove,
      transactionId: intent.transactionId, documentDigest: intent.documentDigest))
    try fixture.intents.write(intent)

    let outcomes = try fixture.intents.replayPending(recorder: fixture.recorder, isCommitted: { _ in true })
    guard case let .versionWritten(version, _, _) = try XCTUnwrap(outcomes.first) else {
      return XCTFail("expected a version after baseline")
    }
    XCTAssertEqual(version.parentVersionId, baseline)
    XCTAssertEqual(try fixture.store.history(workflowName: "flow").count, 2)
  }

  private struct CoordinatorFixture {
    let target: WorkflowBundleIdentity
    let historyRoot: URL
    let recorder: WorkflowDefinitionChangeRecorder
    let store: WorkflowDefinitionStore
    let beforeDigest: String
    let afterDigest: String
    let snapshotId: String
    let updated: Data

    func sync(recorder: any WorkflowDefinitionChangeRecording) -> WorkflowDirectoryDefinitionSync {
      WorkflowDirectoryDefinitionSync(recorder: recorder, workflowName: target.workflowId, sourceScope: .user,
        attribution: .init(operation: .selfImprove, actor: .init(kind: .cli), reason: "coordinator test"),
        bundleSnapshotBefore: snapshotId, bundleSnapshotAfter: nil, beforePublication: nil)
    }
  }

  private func makeCoordinatorFixture(planLocal: Bool = false) async throws -> CoordinatorFixture {
    let root: URL
    if planLocal {
      root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("tmp/workflow-history-unification/whu-08-rollback-service/pin-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      addTeardownBlock { try? FileManager.default.removeItem(at: root) }
      let response = await RielaCLIApplication().run(["workflow", "create", "versioned-flow", "--working-dir", root.path, "--output", "json"])
      XCTAssertEqual(response.exitCode, .success, response.stderr)
    } else {
      (root, _) = try await makeWorkflowVersioningFixture(self)
    }
    let resolved = try resolveMutableTransactionTarget(root: root)
    let before = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let workflow = URL(fileURLWithPath: resolved.identity.ownershipRoot).appendingPathComponent("workflow.json")
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workflow)) as? [String: Any])
    object["description"] = "coordinator test change"
    let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    var files = before.files.map(\.metadata)
    let index = try XCTUnwrap(files.firstIndex { $0.relativePath == "workflow.json" })
    files[index].contentDigest = WorkflowHistoryCanonicalCoding.sha256(updated)
    files[index].byteCount = updated.count
    let after = try WorkflowHistoryCanonicalCoding.bundleDigest(target: resolved.identity, files: files)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: before)
    let storeRoot = root.appendingPathComponent("definition-store")
    let recorder = WorkflowDefinitionChangeRecorder(sessionStoreRoot: storeRoot.path, workingDirectory: root.path,
      environment: mutableWorkflowVersioningEnvironment(root: root),
      fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
    return CoordinatorFixture(target: resolved.identity, historyRoot: resolved.historyRoot, recorder: recorder,
      store: WorkflowDefinitionStore(rootDirectory: storeRoot.path), beforeDigest: before.bundleDigest,
      afterDigest: after, snapshotId: snapshot.snapshotId, updated: updated)
  }

  private struct Fixture {
    let root: URL
    let live: URL
    let staging: URL
    var storeRoot: URL { root.appendingPathComponent("store") }
    var store: WorkflowDefinitionStore { WorkflowDefinitionStore(rootDirectory: storeRoot.path) }
    var intents: WorkflowDefinitionSyncIntentStore { WorkflowDefinitionSyncIntentStore(historyRoot: root.appendingPathComponent("history")) }
    var recorder: WorkflowDefinitionChangeRecorder {
      WorkflowDefinitionChangeRecorder(sessionStoreRoot: storeRoot.path, workingDirectory: root.path,
        environment: ["HOME": root.path], fileResolver: FileSystemWorkflowBundleResolver())
    }
    func captureBaseline(transaction: String = "baseline") throws {
      _ = try recorder.captureBaselineIfAbsent(workflowName: "flow", liveDirectory: live, sourceScope: .direct,
        transactionId: transaction, actor: .init(kind: .cli), operation: .selfImprove, bundleSnapshotBefore: "before")
    }
    func changePrompt(_ value: String) throws {
      try value.write(to: staging.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
    }
    func intent(_ transaction: String) throws -> WorkflowDefinitionSyncIntent {
      try recorder.prepareIntent(workflowName: "flow", stagingDirectory: staging, liveDirectory: live, sourceScope: .direct,
        transactionId: transaction, expectedAfterBundleDigest: nil, bundleSnapshotBefore: "before", bundleSnapshotAfter: nil,
        attribution: .init(operation: .selfImprove, actor: .init(kind: .cli), reason: "original attribution",
          evidence: [.init(kind: .review, id: "review-1")]))
    }
  }

  private func makeFixture() throws -> Fixture {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/workflow-history-unification/whu-07-coordinator-sync/test-\(UUID().uuidString)")
    let live = root.appendingPathComponent("flow")
    let staging = root.appendingPathComponent("staging/flow")
    try FileManager.default.createDirectory(at: live.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: live.appendingPathComponent("prompts"), withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    try """
    {"workflowId":"flow","defaults":{"maxLoopIterations":3,"nodeTimeoutMs":120000},"entryStepId":"first",
    "nodeRegistry":[{"id":"worker","nodeFile":"nodes/worker.json"}],
    "steps":[{"id":"first","nodeId":"worker","role":"worker"}],
    "nodes":[{"id":"worker","nodeFile":"nodes/worker.json"}]}
    """.write(to: live.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {"id":"worker","executionBackend":"codex-agent","model":"model","promptTemplateFile":"prompts/p.md","variables":{}}
    """.write(to: live.appendingPathComponent("nodes/worker.json"), atomically: true, encoding: .utf8)
    try "original".write(to: live.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: live, to: staging)
    return Fixture(root: root, live: live, staging: staging)
  }
}

private struct CoordinatorFailingRecorder: WorkflowDefinitionChangeRecording {
  let base: WorkflowDefinitionChangeRecorder
  var commitBeforeFailure = false
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
                     transactionId: String, expectedAfterBundleDigest: String?, bundleSnapshotBefore: String?,
                     bundleSnapshotAfter: String?, attribution: WorkflowDefinitionChangeAttribution) throws -> WorkflowDefinitionSyncIntent {
    try base.prepareIntent(workflowName: workflowName, stagingDirectory: stagingDirectory, liveDirectory: liveDirectory,
      sourceScope: sourceScope, transactionId: transactionId, expectedAfterBundleDigest: expectedAfterBundleDigest,
      bundleSnapshotBefore: bundleSnapshotBefore, bundleSnapshotAfter: bundleSnapshotAfter, attribution: attribution)
  }
  func sync(_ intent: WorkflowDefinitionSyncIntent) throws -> WorkflowDefinitionSyncOutcome {
    if commitBeforeFailure { _ = try base.sync(intent) }
    throw CLIUsageError("injected sync failure")
  }
  func recordDelete(workflowName: String, sourceScope: WorkflowScope, transactionId: String,
                    bundleSnapshotBefore: String?, attribution: WorkflowDefinitionChangeAttribution) throws -> WorkflowDefinitionSyncOutcome {
    try base.recordDelete(workflowName: workflowName, sourceScope: sourceScope, transactionId: transactionId,
      bundleSnapshotBefore: bundleSnapshotBefore, attribution: attribution)
  }
}
