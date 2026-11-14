import Foundation
import RielaSQLite

public enum WorkflowDefinitionAuditOnlyOutcome: Equatable, Sendable {
  case recorded(WorkflowDefinitionAuditRecord)
  case collapsed(auditId: String)
  case noHead
}

extension WorkflowDefinitionStore {
  public func isChangeComplete(workflowName: String, operation: WorkflowDefinitionOperation,
                               transactionId: String, documentDigest: String?) throws -> Bool {
    let database = try openDatabase()
    return try database.transaction(begin: "BEGIN DEFERRED") { transaction in
      let rows = try transaction.query("""
        SELECT 1 FROM definition_change_audit WHERE workflow_name=? AND operation=?
          AND EXISTS(SELECT 1 FROM json_each(evidence_refs_json)
                     WHERE json_extract(value,'$.kind')='fileTransaction' AND json_extract(value,'$.id')=?) LIMIT 1
        """, bindings: [.text(workflowName), .text(operation.rawValue), .text(transactionId)])
      if !rows.isEmpty { return true }
      guard operation != .rollback, let documentDigest,
            let head = try readHead(workflowName: workflowName, in: transaction),
            let version = try readVersion(versionId: head.currentVersionId, in: transaction) else { return false }
      return version.documentDigest == documentDigest
    }
  }

  public func recordAuditOnlyChange(workflowName: String, operation: WorkflowDefinitionOperation, reason: String,
                                    evidence: [WorkflowDefinitionEvidenceRef], actor: WorkflowDefinitionActor,
                                    expectedHeadVersionId: String? = nil) throws -> WorkflowDefinitionAuditOnlyOutcome {
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw WorkflowDefinitionStoreError(code: .missingReason, message: "definition changes require a non-empty reason")
    }
    guard evidence.allSatisfy({ !$0.id.isEmpty }) else {
      throw WorkflowDefinitionStoreError(code: .invalidEvidence, message: "definition evidence ids must not be empty")
    }
    let database = try openDatabase()
    return try database.transaction { transaction in
      guard let head = try readHead(workflowName: workflowName, in: transaction) else { return .noHead }
      if let expectedHeadVersionId, head.currentVersionId != expectedHeadVersionId {
        throw WorkflowDefinitionStoreError(code: .staleHead, message: "definition head changed")
      }
      if let id = try transaction.query("""
        SELECT audit_id FROM definition_change_audit WHERE workflow_name=? AND operation=?
          AND version_id=? AND previous_version_id=version_id ORDER BY created_order DESC LIMIT 1
        """, bindings: [.text(workflowName), .text(operation.rawValue), .text(head.currentVersionId)]).first?["audit_id"] {
        return .collapsed(auditId: id)
      }
      guard let version = try readVersion(versionId: head.currentVersionId, in: transaction) else {
        throw WorkflowDefinitionStoreError(code: .versionNotFound, message: "current definition version is missing")
      }
      let auditId = "defa-\(UUID().uuidString.lowercased())"
      let timestamp = try JSONDecoder().decode(String.self, from: JSONCanonical.encode(now()))
      try transaction.execute("""
        INSERT INTO definition_change_audit(audit_id,workflow_name,operation,version_id,previous_version_id,
          target_node_id,target_field,before_digest,after_digest,diff_json,reason,evidence_refs_json,
          actor_kind,actor_id,approval_state,overwritten_changes_json,created_at)
        VALUES(?,?,?,?,?,NULL,NULL,?,?,'[]',?,?,?,?,'applied',NULL,?)
        """, bindings: [.text(auditId), .text(workflowName), .text(operation.rawValue), .text(version.versionId),
          .text(version.versionId), .text(version.documentDigest), .text(version.documentDigest), .text(trimmed),
          .text(try canonicalString(evidence)), .text(actor.kind.rawValue), .optionalText(actor.id), .text(timestamp)])
      guard let row = try transaction.query("SELECT * FROM definition_change_audit WHERE audit_id=?",
                                             bindings: [.text(auditId)]).first else {
        throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "definition audit was not recorded")
      }
      return .recorded(try mapAudit(row))
    }
  }

  public func latestVersion(workflowName: String, documentDigest: String) throws -> WorkflowDefinitionVersion? {
    let database = try openDatabase()
    return try database.query("""
      SELECT * FROM definition_versions WHERE workflow_name=? AND document_digest=? ORDER BY history_version DESC LIMIT 1
      """, bindings: [.text(workflowName), .text(documentDigest)]).first.map(mapVersion)
  }

  public func audit(forVersionId versionId: String) throws -> WorkflowDefinitionAuditRecord? {
    let database = try openDatabase()
    return try database.query("""
      SELECT * FROM definition_change_audit WHERE version_id=?
        AND (previous_version_id IS NULL OR previous_version_id != version_id) ORDER BY created_order ASC LIMIT 1
      """, bindings: [.text(versionId)]).first.map(mapAudit)
  }
}
