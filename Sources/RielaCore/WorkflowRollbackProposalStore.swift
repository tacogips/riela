import Foundation
import RielaSQLite

public enum WorkflowRollbackProposalStatus: String, Codable, Sendable {
  case recorded, pending, applying, applied, rejected, superseded, failed
  public var isTerminal: Bool { ![.pending, .applying].contains(self) }
}

public enum WorkflowRollbackMode: String, Codable, Sendable { case store, bundle }

public struct WorkflowRollbackRegressionEntry: Codable, Equatable, Sendable {
  public var kind: String
  public var gateId: String?
  public var detail: String
  public init(kind: String, gateId: String? = nil, detail: String) {
    self.kind = kind; self.gateId = gateId; self.detail = detail
  }
}

public struct WorkflowRollbackProposal: Codable, Equatable, Sendable {
  public var proposalId, workflowName, regressedVersionId, rollbackToVersionId: String
  public var mode: WorkflowRollbackMode
  public var bundleSnapshotId: String?
  public var baselineSessionId, targetSessionId: String
  public var regressions: [WorkflowRollbackRegressionEntry]
  public var policy: WorkflowRegressionRollbackPolicy
  public var status: WorkflowRollbackProposalStatus
  public var claimTransactionId: String?
  public var claimedAt: Date?
  public var createdActor: WorkflowDefinitionActor
  public var decidedActor: WorkflowDefinitionActor?
  public var decisionReason, appliedVersionId, appliedAuditId, failureCode: String?
  public var diagnostics: [String]
  public var createdAt, updatedAt: Date
}

public struct WorkflowRollbackProposalDraft: Sendable {
  public var workflowName, regressedVersionId, rollbackToVersionId: String
  public var mode: WorkflowRollbackMode
  public var bundleSnapshotId: String?
  public var baselineSessionId, targetSessionId: String
  public var regressions: [WorkflowRollbackRegressionEntry]
  public var policy: WorkflowRegressionRollbackPolicy
  public var status: WorkflowRollbackProposalStatus
  public var createdActor: WorkflowDefinitionActor

  public init(workflowName: String, regressedVersionId: String, rollbackToVersionId: String,
              mode: WorkflowRollbackMode, bundleSnapshotId: String? = nil, baselineSessionId: String,
              targetSessionId: String, regressions: [WorkflowRollbackRegressionEntry],
              policy: WorkflowRegressionRollbackPolicy, status: WorkflowRollbackProposalStatus,
              createdActor: WorkflowDefinitionActor) {
    self.workflowName = workflowName; self.regressedVersionId = regressedVersionId
    self.rollbackToVersionId = rollbackToVersionId; self.mode = mode; self.bundleSnapshotId = bundleSnapshotId
    self.baselineSessionId = baselineSessionId; self.targetSessionId = targetSessionId
    self.regressions = regressions; self.policy = policy; self.status = status; self.createdActor = createdActor
  }
}

public struct WorkflowRollbackProposalStore: Sendable {
  private let definitions: WorkflowDefinitionStore
  private let now: @Sendable () -> Date
  public init(rootDirectory: String, now: @escaping @Sendable () -> Date = Date.init) {
    self.definitions = WorkflowDefinitionStore(rootDirectory: rootDirectory, now: now); self.now = now
  }

  public func insertIfAbsent(_ draft: WorkflowRollbackProposalDraft) throws -> (proposal: WorkflowRollbackProposal, created: Bool) {
    guard draft.status == .pending || draft.status == .recorded else { throw notPending() }
    let db = try definitions.openDatabase()
    return try db.transaction { tx in
      let id = "defrp-\(UUID().uuidString.lowercased())"
      let timestamp = try dateString(now())
      let changed = try tx.executeAndReturnChangedRowCount("""
        INSERT OR IGNORE INTO definition_rollback_proposals(proposal_id,workflow_name,regressed_version_id,
          rollback_to_version_id,mode,bundle_snapshot_id,baseline_session_id,target_session_id,regressions_json,
          policy,status,created_actor_kind,created_actor_id,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, bindings: [.text(id), .text(draft.workflowName), .text(draft.regressedVersionId),
          .text(draft.rollbackToVersionId), .text(draft.mode.rawValue), .optionalText(draft.bundleSnapshotId),
          .text(draft.baselineSessionId), .text(draft.targetSessionId), .text(try definitions.canonicalString(draft.regressions)),
          .text(policyColumn(draft.policy)), .text(draft.status.rawValue), .text(draft.createdActor.kind.rawValue),
          .optionalText(draft.createdActor.id), .text(timestamp), .text(timestamp)])
      guard let row = try tx.query("SELECT * FROM definition_rollback_proposals WHERE workflow_name=? AND regressed_version_id=?",
        bindings: [.text(draft.workflowName), .text(draft.regressedVersionId)]).first else { throw notPending() }
      return (try map(row), changed == 1)
    }
  }

  public func proposal(workflowName: String, regressedVersionId: String) throws -> WorkflowRollbackProposal? {
    try definitions.openDatabase().query(
      "SELECT * FROM definition_rollback_proposals WHERE workflow_name=? AND regressed_version_id=?",
      bindings: [.text(workflowName), .text(regressedVersionId)]).first.map(map)
  }

  public func proposal(id: String) throws -> WorkflowRollbackProposal? {
    try definitions.openDatabase().query("SELECT * FROM definition_rollback_proposals WHERE proposal_id=?",
      bindings: [.text(id)]).first.map(map)
  }

  public func list(workflowName: String, status: WorkflowRollbackProposalStatus?, limit: Int) throws -> [WorkflowRollbackProposal] {
    guard (1...500).contains(limit) else { throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "limit must be 1...500") }
    let db = try definitions.openDatabase()
    let rows = try db.query("SELECT * FROM definition_rollback_proposals WHERE workflow_name=? AND (? IS NULL OR status=?) ORDER BY created_at DESC, rowid DESC LIMIT ?",
      bindings: [.text(workflowName), .optionalText(status?.rawValue), .optionalText(status?.rawValue), .int(Int64(limit))])
    return try rows.map(map)
  }

  public func appendAppliedDiagnostic(proposalId: String, expectedAppliedVersionId: String,
                                      diagnostic: String) throws -> WorkflowRollbackProposal {
    let db = try definitions.openDatabase()
    return try db.transaction { tx in
      guard let row = try tx.query("SELECT * FROM definition_rollback_proposals WHERE proposal_id=? AND status='applied' AND applied_version_id=?",
        bindings: [.text(proposalId), .text(expectedAppliedVersionId)]).first else { throw notPending() }
      var proposal = try map(row)
      guard !proposal.diagnostics.contains(diagnostic) else { return proposal }
      proposal.diagnostics.append(diagnostic)
      let updatedAt = now()
      try tx.execute("UPDATE definition_rollback_proposals SET diagnostics_json=?,updated_at=? WHERE proposal_id=?",
        bindings: [.text(try definitions.canonicalString(proposal.diagnostics)), .text(try dateString(updatedAt)), .text(proposalId)])
      guard let updated = try tx.query("SELECT * FROM definition_rollback_proposals WHERE proposal_id=?",
        bindings: [.text(proposalId)]).first else { throw notPending() }
      return try map(updated)
    }
  }

  public func transition(proposalId: String, from: Set<WorkflowRollbackProposalStatus>, to: WorkflowRollbackProposalStatus,
                         decidedActor: WorkflowDefinitionActor?, decisionReason: String?, failureCode: String?, diagnostics: [String],
                         expectedClaimTransactionId: String? = nil) throws -> WorkflowRollbackProposal {
    let allowed: [WorkflowRollbackProposalStatus: Set<WorkflowRollbackProposalStatus>] = [
      .pending: [.applied, .rejected, .superseded, .failed], .applying: [.applied, .pending, .failed]
    ]
    guard !from.isEmpty, from.allSatisfy({ allowed[$0]?.contains(to) == true }) else { throw notPending() }
    if from.contains(.applying), expectedClaimTransactionId?.isEmpty != false { throw notPending() }
    let db = try definitions.openDatabase()
    return try db.transaction { tx in
      let placeholders = Array(repeating: "?", count: from.count).joined(separator: ",")
      let bindings: [SQLiteValue] = [.text(to.rawValue), .optionalText(decidedActor?.kind.rawValue), .optionalText(decidedActor?.id),
        .optionalText(decisionReason), .optionalText(failureCode), .text(try definitions.canonicalString(diagnostics)),
        .text(try dateString(now())), .text(proposalId)] + from.map { .text($0.rawValue) }
        + [.optionalText(expectedClaimTransactionId), .optionalText(expectedClaimTransactionId)]
      let changed = try tx.executeAndReturnChangedRowCount("""
        UPDATE definition_rollback_proposals SET status=?,decided_actor_kind=?,decided_actor_id=?,decision_reason=?,
          failure_code=?,diagnostics_json=?,updated_at=? WHERE proposal_id=? AND status IN (\(placeholders))
          AND (? IS NULL OR claim_transaction_id=?)
        """, bindings: bindings)
      guard changed == 1, let row = try tx.query("SELECT * FROM definition_rollback_proposals WHERE proposal_id=?", bindings: [.text(proposalId)]).first else { throw notPending() }
      return try map(row)
    }
  }

  public func claim(proposalId: String, expectedHeadVersionId: String, claimTransactionId: String) throws -> WorkflowRollbackProposal {
    let db = try definitions.openDatabase()
    let result: WorkflowRollbackProposal? = try db.transaction { tx in
      guard let row = try tx.query("SELECT * FROM definition_rollback_proposals WHERE proposal_id=? AND status='pending'", bindings: [.text(proposalId)]).first else { throw notPending() }
      let head = try tx.query("SELECT current_version_id FROM definition_heads WHERE workflow_name=?", bindings: [.text(row.string("workflow_name"))]).first?["current_version_id"]
      let timestamp = try dateString(now())
      guard head == expectedHeadVersionId else {
        try tx.execute("UPDATE definition_rollback_proposals SET status='superseded',updated_at=? WHERE proposal_id=?", bindings: [.text(timestamp), .text(proposalId)])
        return nil
      }
      try tx.execute("""
        UPDATE definition_rollback_proposals SET status='applying',claim_transaction_id=?,claimed_at=?,updated_at=?
        WHERE proposal_id=?
        """, bindings: [.text(claimTransactionId), .text(timestamp), .text(timestamp), .text(proposalId)])
      guard let updated = try tx.query("SELECT * FROM definition_rollback_proposals WHERE proposal_id=?", bindings: [.text(proposalId)]).first else { throw notPending() }
      return try map(updated)
    }
    guard let result else { throw WorkflowDefinitionStoreError(code: .staleHead, message: "definition head changed") }
    return result
  }

  private func policyColumn(_ policy: WorkflowRegressionRollbackPolicy) -> String {
    policy == .approvalRequired ? "approvalRequired" : policy.rawValue
  }
  private func notPending() -> WorkflowDefinitionStoreError {
    WorkflowDefinitionStoreError(code: .rollbackProposalNotPending, message: "rollback proposal is not pending")
  }
  private func dateString(_ date: Date) throws -> String { try JSONDecoder().decode(String.self, from: JSONCanonical.encode(date)) }
  private func map(_ row: SQLiteRow) throws -> WorkflowRollbackProposal {
    guard let mode = WorkflowRollbackMode(rawValue: row.string("mode")),
          let status = WorkflowRollbackProposalStatus(rawValue: row.string("status")),
          let policy = WorkflowRegressionRollbackPolicy(rawValue: row.string("policy") == "approvalRequired" ? "approval-required" : row.string("policy")),
          let actor = WorkflowDefinitionActorKind(rawValue: row.string("created_actor_kind")) else {
      throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "invalid rollback proposal")
    }
    func date(_ value: String) throws -> Date { try JSONCanonical.decoder().decode(Date.self, from: JSONEncoder().encode(value)) }
    let decided = row["decided_actor_kind"].flatMap(WorkflowDefinitionActorKind.init(rawValue:)).map { WorkflowDefinitionActor(kind: $0, id: row["decided_actor_id"]) }
    return try WorkflowRollbackProposal(proposalId: row.string("proposal_id"), workflowName: row.string("workflow_name"),
      regressedVersionId: row.string("regressed_version_id"), rollbackToVersionId: row.string("rollback_to_version_id"),
      mode: mode, bundleSnapshotId: row["bundle_snapshot_id"], baselineSessionId: row.string("baseline_session_id"),
      targetSessionId: row.string("target_session_id"), regressions: JSONCanonical.decoder().decode([WorkflowRollbackRegressionEntry].self, from: Data(row.string("regressions_json").utf8)),
      policy: policy, status: status, claimTransactionId: row["claim_transaction_id"], claimedAt: row["claimed_at"].map(date),
      createdActor: .init(kind: actor, id: row["created_actor_id"]), decidedActor: decided, decisionReason: row["decision_reason"],
      appliedVersionId: row["applied_version_id"], appliedAuditId: row["applied_audit_id"], failureCode: row["failure_code"],
      diagnostics: JSONCanonical.decoder().decode([String].self, from: Data(row.string("diagnostics_json").utf8)),
      createdAt: date(row.string("created_at")), updatedAt: date(row.string("updated_at")))
  }
}
