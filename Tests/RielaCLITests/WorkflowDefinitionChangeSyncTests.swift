import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore
@testable import RielaWorkflowRegistry

final class WorkflowDefinitionChangeSyncTests: XCTestCase {
  private let actor = WorkflowDefinitionActor(kind: .user)

  func testBaselineChangedSyncAndReplay() throws {
    let fixture = try makeFixture()
    let recorder = fixture.recorder
    guard case let .captured(baseline)? = try recorder.captureBaselineIfAbsent(
      workflowName: "flow", liveDirectory: fixture.live, sourceScope: .direct, transactionId: "tx",
      actor: actor, operation: .selfImprove, bundleSnapshotBefore: "before") else {
      return XCTFail("expected baseline")
    }
    let store = fixture.store
    let baselineAudit = try XCTUnwrap(store.history(workflowName: "flow").first)
    XCTAssertEqual(baselineAudit.operation, .import)
    XCTAssertTrue(baselineAudit.evidence.contains(.init(kind: .baselineTransaction, id: "tx")))
    XCTAssertFalse(baselineAudit.evidence.contains(.init(kind: .fileTransaction, id: "tx")))
    XCTAssertFalse(try store.isChangeComplete(workflowName: "flow", operation: .selfImprove,
      transactionId: "tx", documentDigest: nil))
    try fixture.changePrompt("changed")
    let intent = try fixture.intent(transaction: "tx")
    guard case let .versionWritten(version, audit, _) = try recorder.sync(intent) else {
      return XCTFail("expected new version")
    }
    XCTAssertEqual(version.parentVersionId, baseline)
    XCTAssertEqual(version.documentDigest, intent.documentDigest)
    XCTAssertEqual(audit.operation, .selfImprove)
    XCTAssertTrue(audit.evidence.contains(.init(kind: .fileTransaction, id: "tx")))
    let count = try store.history(workflowName: "flow").count
    XCTAssertEqual(try recorder.sync(intent), .alreadyComplete)
    XCTAssertEqual(try store.history(workflowName: "flow").count, count)
    let service = WorkflowDefinitionService(storeRoot: fixture.storeRoot.path, fileResolver: FileSystemWorkflowBundleResolver())
    _ = try service.undo(workflowName: "flow", reason: "undo", evidence: [], actor: actor,
      expectedRevision: nil, expectedVersionId: version.versionId)
    XCTAssertEqual(try store.head(workflowName: "flow")?.currentVersionId, baseline)
  }

  func testUnchangedSyncCollapsesAndReplayIsIdempotent() throws {
    let fixture = try makeFixture()
    _ = try fixture.baseline()
    let head = try XCTUnwrap(fixture.store.head(workflowName: "flow"))
    var intents: [WorkflowDefinitionSyncIntent] = []
    for index in 1...5 {
      let intent = try fixture.intent(transaction: "tx\(index)")
      intents.append(intent)
      let outcome = try fixture.recorder.sync(intent)
      if index == 1 {
        guard case let .auditOnly(audit) = outcome else { return XCTFail("first no-op must be audited") }
        XCTAssertEqual(audit.versionId, head.currentVersionId)
        XCTAssertEqual(audit.previousVersionId, head.currentVersionId)
        XCTAssertTrue(audit.evidence.contains(.init(kind: .fileTransaction, id: "tx1")))
        XCTAssertTrue(audit.evidence.contains(.init(kind: .bundleSnapshotBefore, id: "before")))
        XCTAssertTrue(audit.evidence.contains(.init(kind: .bundleSnapshotAfter, id: "after")))
      } else {
        XCTAssertEqual(outcome, .collapsed)
      }
    }
    XCTAssertEqual(try fixture.store.history(workflowName: "flow").count, 2)
    XCTAssertEqual(try fixture.store.head(workflowName: "flow")?.currentVersionId, head.currentVersionId)
    XCTAssertEqual(try fixture.recorder.sync(intents[0]), .alreadyComplete)
    let replay = try fixture.recorder.sync(intents[2])
    XCTAssertTrue(replay == .collapsed || replay == .alreadyComplete)
    XCTAssertTrue(try fixture.store.isChangeComplete(workflowName: "flow", operation: .selfImprove,
      transactionId: "tx3", documentDigest: intents[2].documentDigest))
    XCTAssertEqual(try fixture.store.history(workflowName: "flow").count, 2)
  }

  func testDeleteAndStaleRollback() throws {
    let fixture = try makeFixture()
    let delete = WorkflowDefinitionChangeAttribution(operation: .registryDelete, actor: actor, reason: "delete", evidence: [],
      expectedHeadVersionId: nil, rollbackProposalId: nil)
    XCTAssertEqual(try fixture.recorder.recordDelete(workflowName: "flow", sourceScope: .direct, transactionId: "delete0",
      bundleSnapshotBefore: nil, attribution: delete), .noHead)
    _ = try fixture.baseline()
    guard case let .auditOnly(audit) = try fixture.recorder.recordDelete(workflowName: "flow", sourceScope: .direct,
      transactionId: "delete1", bundleSnapshotBefore: "before", attribution: delete) else {
      return XCTFail("expected delete audit")
    }
    XCTAssertEqual(audit.operation, .registryDelete)
    XCTAssertTrue(audit.evidence.contains(.init(kind: .bundleSnapshotBefore, id: "before")))
    try fixture.changePrompt("new")
    var intent = try fixture.intent(transaction: "rollback")
    intent.attribution.operation = .rollback
    intent.attribution.expectedHeadVersionId = "stale"
    let before = try fixture.store.history(workflowName: "flow").count
    XCTAssertThrowsError(try fixture.recorder.sync(intent))
    XCTAssertEqual(try fixture.store.history(workflowName: "flow").count, before)
  }

  func testOverwriteAndRestoreCAS() throws {
    let fixture = try makeFixture()
    guard case let .captured(baseline)? = try fixture.baseline() else { return XCTFail("expected baseline") }
    let service = WorkflowDefinitionService(storeRoot: fixture.storeRoot.path, fileResolver: FileSystemWorkflowBundleResolver())
    let update = try service.updatePrompt(workflowName: "flow", nodeId: "worker", field: .init(parsing: "promptTemplate"),
      text: "store-only", reason: "update", expectedVersionId: baseline, evidence: [], actor: actor)
    try fixture.changePrompt("file-derived")
    guard case let .versionWritten(version, _, overwritten) = try fixture.recorder.sync(fixture.intent(transaction: "file")) else {
      return XCTFail("expected file-derived version")
    }
    XCTAssertTrue(overwritten.contains(update.1.auditId))
    XCTAssertEqual(try fixture.store.head(workflowName: "flow")?.lastFileVersionId, version.versionId)
    let count = try fixture.store.history(workflowName: "flow").count
    XCTAssertThrowsError(try service.restore(workflowName: "flow", versionId: baseline, reason: "restore", evidence: [],
      actor: actor, expectedVersionId: "stale")) { error in
      XCTAssertEqual((error as? WorkflowDefinitionServiceError)?.code, .definitionConflict)
    }
    XCTAssertEqual(try fixture.store.history(workflowName: "flow").count, count)
  }

  func testInjectedStoreRoots() throws {
    let fixture = try makeFixture()
    let home = fixture.root.appendingPathComponent("home").path
    let recorder = WorkflowDefinitionChangeRecorder(workingDirectory: fixture.root.path, environment: ["HOME": home], fileResolver: FileSystemWorkflowBundleResolver())
    XCTAssertEqual(try recorder.storeRoot(workflowName: "missing", sourceScope: .user),
      home + "/.riela/sessions")
    let override = fixture.root.appendingPathComponent("override").path
    let overridden = WorkflowDefinitionChangeRecorder(workingDirectory: fixture.root.path,
      environment: ["HOME": home, "RIELA_SESSION_STORE": override], fileResolver: FileSystemWorkflowBundleResolver())
    XCTAssertEqual(try overridden.storeRoot(workflowName: "missing", sourceScope: .user), override)
    let resolution = WorkflowResolutionOptions(workflowName: "flow", scope: .auto, workingDirectory: fixture.root.path)
    var bundle = try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
      workflowName: "flow", scope: .direct, workflowDefinitionDir: fixture.root.path, workingDirectory: fixture.root.path))
    for scope: WorkflowScope in [.user, .project, .direct] {
      bundle.sourceScope = scope
      XCTAssertEqual(try recorder.storeRoot(workflowName: "missing", sourceScope: scope),
        WorkflowDefinitionStoreSelection.seedRoot(sessionStore: nil, resolution: resolution,
          fileBundle: bundle, environment: ["HOME": home]))
    }
  }

  private struct Fixture {
    let root: URL
    let live: URL
    let staging: URL
    var storeRoot: URL { root.appendingPathComponent("store") }
    var store: WorkflowDefinitionStore { WorkflowDefinitionStore(rootDirectory: storeRoot.path) }
    var recorder: WorkflowDefinitionChangeRecorder {
      WorkflowDefinitionChangeRecorder(sessionStoreRoot: storeRoot.path, workingDirectory: root.path, environment: ["HOME": root.path], fileResolver: FileSystemWorkflowBundleResolver())
    }
    func baseline() throws -> WorkflowDefinitionBaselineOutcome? {
      try recorder.captureBaselineIfAbsent(workflowName: "flow", liveDirectory: live, sourceScope: .direct,
        transactionId: "baseline", actor: .init(kind: .user), operation: .selfImprove, bundleSnapshotBefore: nil)
    }
    func changePrompt(_ text: String) throws {
      try text.write(to: staging.appendingPathComponent("prompts/p.md"), atomically: true, encoding: .utf8)
    }
    func intent(transaction: String) throws -> WorkflowDefinitionSyncIntent {
      try recorder.prepareIntent(workflowName: "flow", stagingDirectory: staging, liveDirectory: live, sourceScope: .direct,
        transactionId: transaction, expectedAfterBundleDigest: nil, bundleSnapshotBefore: "before", bundleSnapshotAfter: "after",
        attribution: .init(operation: .selfImprove, actor: .init(kind: .user), reason: "improve", evidence: [],
          expectedHeadVersionId: nil, rollbackProposalId: nil))
    }
  }

  private func makeFixture() throws -> Fixture {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/workflow-history-unification/whu-05-definition-sync/fixture-\(UUID().uuidString)")
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
