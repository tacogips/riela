import Foundation
import RielaSQLite
import XCTest
@testable import RielaCore

final class WorkflowDefinitionFileChangeStoreTests: XCTestCase {
  func testAuditOnlyRejectsHeadMovedByAnotherStore() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowDefinitionStore(rootDirectory: root.path)
    let other = WorkflowDefinitionStore(rootDirectory: root.path)
    guard case let .created(seed, _) = try store.commit(write(.seed, "one")),
          case let .created(moved, _) = try other.commit(write(.update, "two", expected: seed.versionId)) else {
      return XCTFail("expected versions")
    }
    let count = try store.history(workflowName: "w").count
    XCTAssertThrowsError(try store.recordAuditOnlyChange(workflowName: "w", operation: .selfImprove,
      reason: "sync", evidence: [.init(kind: .fileTransaction, id: "T")], actor: .init(kind: .system),
      expectedHeadVersionId: seed.versionId)) {
      XCTAssertEqual(($0 as? WorkflowDefinitionStoreError)?.code, .staleHead)
    }
    XCTAssertEqual(try store.history(workflowName: "w").count, count)
    XCTAssertEqual(try store.head(workflowName: "w")?.currentVersionId, moved.versionId)
    XCTAssertFalse(try store.isChangeComplete(workflowName: "w", operation: .selfImprove, transactionId: "T", documentDigest: nil))
  }

  func testCompletionAndAuditOnlyCollapse() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowDefinitionStore(rootDirectory: root.path)
    let actor = WorkflowDefinitionActor(kind: .system)
    XCTAssertEqual(try store.recordAuditOnlyChange(workflowName: "absent", operation: .registryDelete,
      reason: "delete", evidence: [], actor: actor), .noHead)
    guard case let .created(seed, _) = try store.commit(write(.seed, "one")) else { return XCTFail("Expected requested store result") }
    let file = WorkflowDefinitionEvidenceRef(kind: .fileTransaction, id: "T")
    guard case let .recorded(audit) = try store.recordAuditOnlyChange(workflowName: "w", operation: .selfImprove,
      reason: "sync", evidence: [file], actor: actor) else { return XCTFail("Expected requested store result") }
    XCTAssertEqual(try store.recordAuditOnlyChange(workflowName: "w", operation: .selfImprove,
      reason: "sync", evidence: [], actor: actor), .collapsed(auditId: audit.auditId))
    guard case .recorded = try store.recordAuditOnlyChange(workflowName: "w", operation: .registryDelete,
      reason: "delete", evidence: [], actor: actor) else { return XCTFail("Expected requested store result") }
    XCTAssertTrue(try store.isChangeComplete(workflowName: "w", operation: .selfImprove, transactionId: "T", documentDigest: nil))
    XCTAssertFalse(try store.isChangeComplete(workflowName: "w", operation: .registryWrite, transactionId: "T", documentDigest: nil))
    XCTAssertTrue(try store.isChangeComplete(workflowName: "w", operation: .registryWrite, transactionId: "other", documentDigest: seed.documentDigest))
    XCTAssertFalse(try store.isChangeComplete(workflowName: "w", operation: .rollback, transactionId: "other", documentDigest: seed.documentDigest))
    _ = try store.recordAuditOnlyChange(workflowName: "w", operation: .import, reason: "baseline",
      evidence: [.init(kind: .baselineTransaction, id: "B")], actor: actor)
    XCTAssertFalse(try store.isChangeComplete(workflowName: "w", operation: .import, transactionId: "B", documentDigest: "different"))
    XCTAssertEqual(try store.latestVersion(workflowName: "w", documentDigest: seed.documentDigest), seed)
    XCTAssertEqual(try store.audit(forVersionId: seed.versionId)?.operation, .seed)
    XCTAssertThrowsError(try WorkflowDefinitionEvidenceRef.parse("fileTransaction:T"))
  }

  func testFileDerivedPointerAndRollbackClaim() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowDefinitionStore(rootDirectory: root.path)
    guard case let .created(seed, _) = try store.commit(write(.seed, "one")),
          case let .created(improved, _) = try store.commit(write(.selfImprove, "two", expected: seed.versionId)) else { return XCTFail("Expected requested store result") }
    XCTAssertEqual(try store.head(workflowName: "w")?.lastFileVersionId, improved.versionId)
    let db = try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path))
    try db.execute("""
      INSERT INTO definition_rollback_proposals(proposal_id,workflow_name,regressed_version_id,rollback_to_version_id,
        mode,baseline_session_id,target_session_id,regressions_json,policy,status,created_actor_kind,created_at,updated_at)
      VALUES('p','w',?,?,'bundle','b','t','[]','approvalRequired','applying','system','2025-01-01T00:00:00Z','2025-01-01T00:00:00Z')
      """, bindings: [.text(improved.versionId), .text(seed.versionId)])
    XCTAssertThrowsError(try store.commit(write(.update, "three", expected: improved.versionId))) {
      XCTAssertEqual(($0 as? WorkflowDefinitionStoreError)?.code, .rollbackInProgress)
    }
    XCTAssertThrowsError(try store.moveHead(workflowName: "w", direction: .undo, reason: "undo", expectedRevision: nil,
      expectedVersionId: improved.versionId, evidence: [], actorKind: "user", actorId: nil)) {
      XCTAssertEqual(($0 as? WorkflowDefinitionStoreError)?.code, .rollbackInProgress)
    }
    var rollback = write(.rollback, "one", expected: improved.versionId)
    rollback.rollbackProposalId = "p"
    guard case let .created(restored, audit) = try store.commit(rollback) else { return XCTFail("Expected requested store result") }
    XCTAssertEqual(try store.head(workflowName: "w")?.lastFileVersionId, improved.versionId)
    let proposal = try db.query("SELECT status,applied_version_id,applied_audit_id FROM definition_rollback_proposals WHERE proposal_id='p'").first
    XCTAssertEqual(proposal?["status"], "applied")
    XCTAssertEqual(proposal?["applied_version_id"], restored.versionId)
    XCTAssertEqual(proposal?["applied_audit_id"], audit.auditId)
    var fileRollback = write(.rollback, "four", expected: restored.versionId)
    fileRollback.evidence = [.init(kind: .fileTransaction, id: "F")]
    guard case let .created(fileRestored, _) = try store.commit(fileRollback) else { return XCTFail("Expected requested store result") }
    XCTAssertEqual(try store.head(workflowName: "w")?.lastFileVersionId, fileRestored.versionId)
    try db.execute("""
      INSERT INTO definition_rollback_proposals(proposal_id,workflow_name,regressed_version_id,rollback_to_version_id,
        mode,baseline_session_id,target_session_id,regressions_json,policy,status,created_actor_kind,created_at,updated_at)
      VALUES('rejected','w',?,?,'store','b','t','[]','approvalRequired','rejected','system','2025-01-01T00:00:00Z','2025-01-01T00:00:00Z')
      """, bindings: [.text(fileRestored.versionId), .text(seed.versionId)])
    var rejected = write(.rollback, "five", expected: fileRestored.versionId)
    rejected.rollbackProposalId = "rejected"
    XCTAssertThrowsError(try store.commit(rejected)) {
      XCTAssertEqual(($0 as? WorkflowDefinitionStoreError)?.code, .rollbackProposalNotPending)
    }
    XCTAssertEqual(try store.head(workflowName: "w")?.currentVersionId, fileRestored.versionId)
  }

  private func makeRoot() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/workflow-history-unification/whu-01-store-core/test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func write(_ operation: WorkflowDefinitionOperation, _ text: String, expected: String? = nil) -> WorkflowDefinitionWrite {
    let data = Data("{\"value\":\"\(text)\"}".utf8)
    return WorkflowDefinitionWrite(workflowName: "w", operation: operation, documentData: data,
      documentDigest: JSONCanonical.sha256Hex(data), sourceDirectory: "/w", sourceScope: "project", provenance: "test",
      actor: .init(kind: .system), reason: "test", expectedCurrentVersionId: expected)
  }
}
