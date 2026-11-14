import Foundation
import RielaSQLite
import XCTest
@testable import RielaCore

final class WorkflowRollbackProposalStoreTests: XCTestCase {
  func testInsertionClaimAndTransitions() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let definitions = WorkflowDefinitionStore(rootDirectory: root.path)
    let data = Data("{}".utf8)
    let write = WorkflowDefinitionWrite(workflowName: "w", operation: .seed, documentData: data,
      documentDigest: JSONCanonical.sha256Hex(data), sourceDirectory: "/w", sourceScope: "project",
      provenance: "test", actor: .init(kind: .system), reason: "seed")
    guard case let .created(version, _) = try definitions.commit(write) else { return XCTFail("Expected requested store result") }
    let store = WorkflowRollbackProposalStore(rootDirectory: root.path)
    func draft(_ regressed: String) -> WorkflowRollbackProposalDraft {
      .init(workflowName: "w", regressedVersionId: regressed, rollbackToVersionId: version.versionId,
        mode: .bundle, baselineSessionId: "b", targetSessionId: "t", regressions: [],
        policy: .approvalRequired, status: .pending, createdActor: .init(kind: .system))
    }
    let first = try store.insertIfAbsent(draft("one"))
    XCTAssertTrue(first.created)
    let duplicate = try store.insertIfAbsent(draft("one"))
    XCTAssertFalse(duplicate.created)
    XCTAssertEqual(duplicate.proposal.proposalId, first.proposal.proposalId)
    let stale = try store.insertIfAbsent(draft("two")).proposal
    XCTAssertThrowsError(try store.claim(proposalId: stale.proposalId, expectedHeadVersionId: "wrong", claimTransactionId: "tx")) {
      XCTAssertEqual(($0 as? WorkflowDefinitionStoreError)?.code, .staleHead)
    }
    XCTAssertEqual(try store.proposal(id: stale.proposalId)?.status, .superseded)
    XCTAssertEqual(try store.claim(proposalId: first.proposal.proposalId, expectedHeadVersionId: version.versionId,
      claimTransactionId: "tx").status, .applying)
    _ = try store.transition(proposalId: first.proposal.proposalId, from: [.applying], to: .pending,
      decidedActor: nil, decisionReason: nil, failureCode: nil, diagnostics: [], expectedClaimTransactionId: "tx")
    _ = try store.claim(proposalId: first.proposal.proposalId, expectedHeadVersionId: version.versionId,
      claimTransactionId: "newer")
    XCTAssertThrowsError(try store.transition(proposalId: first.proposal.proposalId, from: [.applying], to: .pending,
      decidedActor: nil, decisionReason: nil, failureCode: nil, diagnostics: [], expectedClaimTransactionId: "tx"))
    XCTAssertThrowsError(try store.transition(proposalId: first.proposal.proposalId, from: [.applying], to: .failed,
      decidedActor: nil, decisionReason: nil, failureCode: "stale", diagnostics: [], expectedClaimTransactionId: "tx"))
    for claimId in [nil, ""] as [String?] {
      XCTAssertThrowsError(try store.transition(proposalId: first.proposal.proposalId, from: [.applying], to: .pending,
        decidedActor: nil, decisionReason: nil, failureCode: nil, diagnostics: [], expectedClaimTransactionId: claimId))
    }
    XCTAssertEqual(try store.proposal(id: first.proposal.proposalId)?.claimTransactionId, "newer")
    XCTAssertEqual(try store.proposal(id: first.proposal.proposalId)?.status, .applying)
    let second = try store.insertIfAbsent(draft("three")).proposal
    XCTAssertThrowsError(try store.claim(proposalId: second.proposalId, expectedHeadVersionId: version.versionId, claimTransactionId: "other"))
    XCTAssertThrowsError(try store.transition(proposalId: second.proposalId, from: [.applying], to: .failed,
      decidedActor: nil, decisionReason: nil, failureCode: nil, diagnostics: [])) {
      XCTAssertEqual(($0 as? WorkflowDefinitionStoreError)?.code, .rollbackProposalNotPending)
    }
    _ = try store.transition(proposalId: second.proposalId, from: [.pending], to: .rejected,
      decidedActor: .init(kind: .user), decisionReason: "no", failureCode: nil, diagnostics: [])
    XCTAssertThrowsError(try store.claim(proposalId: second.proposalId, expectedHeadVersionId: version.versionId, claimTransactionId: "other")) {
      XCTAssertEqual(($0 as? WorkflowDefinitionStoreError)?.code, .rollbackProposalNotPending)
    }
    XCTAssertEqual(try store.list(workflowName: "w", status: .rejected, limit: 10).count, 1)
  }

  func testAppliedDiagnosticIsIdempotentAndRequiresMatchingAppliedVersion() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let definitions = WorkflowDefinitionStore(rootDirectory: root.path)
    let data = Data("{}".utf8)
    let write = WorkflowDefinitionWrite(workflowName: "w", operation: .seed, documentData: data,
      documentDigest: JSONCanonical.sha256Hex(data), sourceDirectory: "/w", sourceScope: "project",
      provenance: "test", actor: .init(kind: .system), reason: "seed")
    guard case let .created(version, _) = try definitions.commit(write) else { return XCTFail("Expected a version") }
    let store = WorkflowRollbackProposalStore(rootDirectory: root.path)
    let draft = WorkflowRollbackProposalDraft(workflowName: "w", regressedVersionId: version.versionId,
      rollbackToVersionId: version.versionId, mode: .bundle, baselineSessionId: "b", targetSessionId: "t",
      regressions: [], policy: .approvalRequired, status: .pending, createdActor: .init(kind: .system))
    let proposal = try store.insertIfAbsent(draft).proposal
    XCTAssertThrowsError(try store.appendAppliedDiagnostic(proposalId: proposal.proposalId,
      expectedAppliedVersionId: version.versionId, diagnostic: "rollbackDigestMismatch"))
    _ = try store.transition(proposalId: proposal.proposalId, from: [.pending], to: .applied,
      decidedActor: .init(kind: .user), decisionReason: "approved", failureCode: nil, diagnostics: ["existing"])
    try definitions.openDatabase().execute("UPDATE definition_rollback_proposals SET applied_version_id=? WHERE proposal_id=?",
      bindings: [.text(version.versionId), .text(proposal.proposalId)])
    XCTAssertThrowsError(try store.appendAppliedDiagnostic(proposalId: proposal.proposalId,
      expectedAppliedVersionId: "other", diagnostic: "rollbackDigestMismatch"))
    let updated = try store.appendAppliedDiagnostic(proposalId: proposal.proposalId,
      expectedAppliedVersionId: version.versionId, diagnostic: "rollbackDigestMismatch")
    XCTAssertEqual(updated.diagnostics, ["existing", "rollbackDigestMismatch"])
    XCTAssertEqual(updated.status, .applied)
    XCTAssertEqual(updated.decisionReason, "approved")
    XCTAssertEqual(try store.appendAppliedDiagnostic(proposalId: proposal.proposalId,
      expectedAppliedVersionId: version.versionId, diagnostic: "rollbackDigestMismatch"), updated)
    XCTAssertEqual(try store.proposal(id: proposal.proposalId), updated)
  }

  func testPruneAndPurgeRemoveTerminalProposalsAndProtectPending() throws {
    for purge in [false, true] {
      let root = try makeRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let old = WorkflowDefinitionStore(rootDirectory: root.path, now: { Date(timeIntervalSince1970: 1_000_000) })
      var versions: [String] = []
      for index in 0..<7 {
        let data = Data("{\"revision\":\(index)}".utf8)
        let write = WorkflowDefinitionWrite(workflowName: "w", operation: index == 0 ? .seed : .update,
          documentData: data, documentDigest: JSONCanonical.sha256Hex(data), sourceDirectory: "/w", sourceScope: "project",
          provenance: "test", actor: .init(kind: .system), reason: "change", expectedCurrentVersionId: versions.last,
          defaultHistoryRetention: 100)
        guard case let .created(version, _) = try old.commit(write) else { return XCTFail("Expected a version") }
        versions.append(version.versionId)
      }
      let proposals = WorkflowRollbackProposalStore(rootDirectory: root.path)
      func draft(_ regressed: String, _ target: String, _ status: WorkflowRollbackProposalStatus) -> WorkflowRollbackProposalDraft {
        .init(workflowName: "w", regressedVersionId: regressed, rollbackToVersionId: target, mode: .store,
          baselineSessionId: "b", targetSessionId: "t", regressions: [], policy: .approvalRequired,
          status: status, createdActor: .init(kind: .system))
      }
      let terminal = try proposals.insertIfAbsent(draft(versions[1], versions[2], .recorded)).proposal
      let pending = try proposals.insertIfAbsent(draft(versions[3], versions[4], .pending)).proposal
      let store = WorkflowDefinitionStore(rootDirectory: root.path, now: { Date(timeIntervalSince1970: 2_000_000) })
      let actor = WorkflowDefinitionActor(kind: .system)
      func retain(_ dryRun: Bool) throws -> WorkflowDefinitionRetentionResult {
        if purge { return try store.purgeHistory(workflowName: "w", reason: "test", actor: actor, dryRun: dryRun) }
        return try store.prune(workflowName: "w", keepVersions: 2, reason: "test", actor: actor, dryRun: dryRun)
      }
      XCTAssertEqual(try retain(true).proposalsDropped, 1)
      XCTAssertNotNil(try proposals.proposal(id: terminal.proposalId))
      let result = try retain(false)
      XCTAssertEqual(result.proposalsDropped, 1)
      XCTAssertNil(try proposals.proposal(id: terminal.proposalId))
      XCTAssertNotNil(try proposals.proposal(id: pending.proposalId))
      XCTAssertTrue(result.keptVersionIds.contains(versions[3]))
      XCTAssertTrue(result.keptVersionIds.contains(versions[4]))
    }
  }

  private func makeRoot() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/workflow-history-unification/whu-01-store-core/test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
