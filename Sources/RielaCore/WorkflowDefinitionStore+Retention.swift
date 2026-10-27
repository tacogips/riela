import Foundation
import RielaSQLite

public enum WorkflowDefinitionRetentionMode: String, Codable, Equatable, Sendable {
  /// Keep the newest N versions plus every protected version.
  case prune
  /// Keep only protected versions (the current head at minimum) and replace
  /// the whole audit trail with one record of the purge.
  case purgeHistory
}

public struct WorkflowDefinitionProtectedVersion: Codable, Equatable, Sendable {
  public var versionId: String
  public var reason: String

  public init(versionId: String, reason: String) {
    self.versionId = versionId
    self.reason = reason
  }
}

public struct WorkflowDefinitionRetentionResult: Codable, Equatable, Sendable {
  public var workflowName: String
  public var mode: WorkflowDefinitionRetentionMode
  public var dryRun: Bool
  public var keepVersions: Int?
  public var keptVersionIds: [String]
  public var protectedVersions: [WorkflowDefinitionProtectedVersion]
  public var removedVersionIds: [String]
  public var removedAuditCount: Int
  public var removedBlobCount: Int
  public var removedBlobBytes: Int64
  /// The audit record that documents this removal; nil for a dry run or when
  /// nothing was removed.
  public var audit: WorkflowDefinitionAuditRecord?
}

extension WorkflowDefinitionStore {
  /// Session statuses that may still resume or rerun against a pinned version.
  static let activeSessionStatuses = ["created", "running", "suspended"]

  public func workflowNames() throws -> [String] {
    let database = try openDatabase()
    return try database.query("SELECT workflow_name FROM definition_heads ORDER BY workflow_name").map { $0.string("workflow_name") }
  }

  /// Removes all but the newest `keepVersions` versions of one workflow. The
  /// current head, the last file import and versions pinned by active sessions
  /// are always kept. Earlier prune records stay in the audit trail.
  public func prune(
    workflowName: String,
    keepVersions: Int,
    reason: String,
    actor: WorkflowDefinitionActor,
    dryRun: Bool = false
  ) throws -> WorkflowDefinitionRetentionResult {
    guard keepVersions >= 1 else {
      throw WorkflowDefinitionStoreError(code: .invalidRetention, message: "keepVersions must be at least 1")
    }
    return try retain(workflowName: workflowName, mode: .prune, keepVersions: keepVersions, reason: reason, actor: actor, dryRun: dryRun)
  }

  /// Removes every version except protected ones and replaces the audit trail
  /// with a single purgeHistory record.
  public func purgeHistory(
    workflowName: String,
    reason: String,
    actor: WorkflowDefinitionActor,
    dryRun: Bool = false
  ) throws -> WorkflowDefinitionRetentionResult {
    try retain(workflowName: workflowName, mode: .purgeHistory, keepVersions: nil, reason: reason, actor: actor, dryRun: dryRun)
  }

  private func retain(
    workflowName: String,
    mode: WorkflowDefinitionRetentionMode,
    keepVersions: Int?,
    reason: String,
    actor: WorkflowDefinitionActor,
    dryRun: Bool
  ) throws -> WorkflowDefinitionRetentionResult {
    if !dryRun, reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw WorkflowDefinitionStoreError(code: .missingReason, message: "definition history removal requires a non-empty reason")
    }
    let database = try openDatabase()
    return try database.transaction { transaction in
      guard let head = try readHead(workflowName: workflowName, in: transaction) else {
        throw WorkflowDefinitionStoreError(code: .headMissing, message: "definition head does not exist")
      }
      let versions = try transaction.query(
        "SELECT version_id, document_digest, operation, created_at FROM definition_versions WHERE workflow_name = ? ORDER BY rowid DESC",
        bindings: [.text(workflowName)]
      )
      let protected = try protectedVersions(head: head, in: transaction)
      let protectedIds = Set(protected.map(\.versionId))
      let newestIds = Set(versions.prefix(keepVersions ?? 0).map { $0.string("version_id") })
      let removedRows = versions.filter {
        let id = $0.string("version_id")
        return !protectedIds.contains(id) && !newestIds.contains(id)
      }
      let removedIds = removedRows.map { $0.string("version_id") }
      let keptIds = versions.map { $0.string("version_id") }.filter { !Set(removedIds).contains($0) }

      try transaction.execute("CREATE TEMP TABLE IF NOT EXISTS definition_retention_removed(version_id TEXT PRIMARY KEY)")
      try transaction.execute("DELETE FROM temp.definition_retention_removed")
      for id in removedIds {
        try transaction.execute("INSERT INTO temp.definition_retention_removed(version_id) VALUES (?)", bindings: [.text(id)])
      }
      defer { try? transaction.execute("DROP TABLE IF EXISTS temp.definition_retention_removed") }

      let retentionOperations: [SQLiteValue] = [
        .text(WorkflowDefinitionOperation.prune.rawValue), .text(WorkflowDefinitionOperation.purgeHistory.rawValue)
      ]
      let auditScope = mode == .purgeHistory
        ? ("WHERE workflow_name = ?", [SQLiteValue.text(workflowName)])
        : ("""
          WHERE workflow_name = ? AND operation NOT IN (?, ?)
            AND version_id IN (SELECT version_id FROM temp.definition_retention_removed)
          """, [SQLiteValue.text(workflowName)] + retentionOperations)
      let auditCount = try transaction.query("SELECT COUNT(*) AS count FROM definition_change_audit \(auditScope.0)", bindings: auditScope.1)
        .first?["count"].flatMap(Int.init) ?? 0
      // Blobs referenced only by removed versions, captured before any delete.
      try transaction.execute(
        """
        CREATE TEMP TABLE definition_retention_blobs AS
        SELECT blob.digest AS digest, blob.size AS size FROM definition_blobs AS blob
        WHERE blob.digest IN (
          SELECT version.document_digest FROM definition_versions AS version
          JOIN temp.definition_retention_removed AS removed ON removed.version_id = version.version_id
        )
        AND NOT EXISTS (
          SELECT 1 FROM definition_versions AS other
          WHERE other.document_digest = blob.digest
            AND other.version_id NOT IN (SELECT version_id FROM temp.definition_retention_removed)
        )
        """
      )
      defer { try? transaction.execute("DROP TABLE IF EXISTS temp.definition_retention_blobs") }
      let blobRow = try transaction.query("SELECT COUNT(*) AS count, COALESCE(SUM(size), 0) AS bytes FROM temp.definition_retention_blobs").first
      let blobCount = blobRow?["count"].flatMap(Int.init) ?? 0
      let blobBytes = blobRow?["bytes"].flatMap(Int64.init) ?? 0

      var result = WorkflowDefinitionRetentionResult(
        workflowName: workflowName, mode: mode, dryRun: dryRun, keepVersions: keepVersions,
        keptVersionIds: keptIds, protectedVersions: protected, removedVersionIds: removedIds,
        removedAuditCount: auditCount, removedBlobCount: blobCount, removedBlobBytes: blobBytes, audit: nil
      )
      // A prune that removes nothing leaves no trace; a purge always records itself.
      guard !dryRun, mode == .purgeHistory || !removedIds.isEmpty || auditCount > 0 else { return result }

      try WorkflowDefinitionStoreSchema.withRetentionDeletes(in: transaction) {
        try transaction.execute("DELETE FROM definition_change_audit \(auditScope.0)", bindings: auditScope.1)
        try transaction.execute("DELETE FROM definition_versions WHERE version_id IN (SELECT version_id FROM temp.definition_retention_removed)")
        try transaction.execute("DELETE FROM definition_blobs WHERE digest IN (SELECT digest FROM temp.definition_retention_blobs)")
      }
      result.audit = try insertRetentionAudit(
        head: head, result: result, removedRows: removedRows, reason: reason, actor: actor, in: transaction
      )
      return result
    }
  }

  private func protectedVersions(head: WorkflowDefinitionHead, in database: SQLiteDatabase) throws -> [WorkflowDefinitionProtectedVersion] {
    var protected = [WorkflowDefinitionProtectedVersion(versionId: head.currentVersionId, reason: "current")]
    if head.lastFileVersionId != head.currentVersionId {
      protected.append(.init(versionId: head.lastFileVersionId, reason: "lastFileImport"))
    }
    guard try database.tableExists("workflow_runtime_snapshots") else { return protected }
    let placeholders = Self.activeSessionStatuses.map { _ in "?" }.joined(separator: ", ")
    let rows = try database.query(
      """
      SELECT DISTINCT json_extract(session_json, '$.definitionSource.versionId') AS version_id
      FROM workflow_runtime_snapshots
      WHERE session_status IN (\(placeholders))
        AND json_extract(session_json, '$.definitionSource.workflowName') = ?
        AND json_extract(session_json, '$.definitionSource.versionId') IS NOT NULL
      """,
      bindings: Self.activeSessionStatuses.map { .text($0) } + [.text(head.workflowName)]
    )
    let known = Set(protected.map(\.versionId))
    for id in rows.compactMap({ $0["version_id"] }).sorted() where !known.contains(id) {
      protected.append(.init(versionId: id, reason: "activeSession"))
    }
    return protected
  }

  private func insertRetentionAudit(
    head: WorkflowDefinitionHead,
    result: WorkflowDefinitionRetentionResult,
    removedRows: [SQLiteRow],
    reason: String,
    actor: WorkflowDefinitionActor,
    in transaction: SQLiteDatabase
  ) throws -> WorkflowDefinitionAuditRecord {
    guard let current = try readVersion(versionId: head.currentVersionId, in: transaction) else {
      throw WorkflowDefinitionStoreError(code: .versionNotFound, message: "current definition version is missing")
    }
    let operation: WorkflowDefinitionOperation = result.mode == .prune ? .prune : .purgeHistory
    var diff = removedRows.map { row in
      WorkflowDefinitionDiffEntry(
        path: "/versions/\(row.string("version_id"))",
        op: .remove,
        before: .object([
          "documentDigest": .string(row.string("document_digest")),
          "operation": .string(row.string("operation")),
          "createdAt": .string(row.string("created_at"))
        ])
      )
    }
    if let keep = result.keepVersions {
      diff.append(.init(path: "/retention/keepVersions", op: .add, after: .integer(Int64(keep))))
    }
    diff.append(.init(path: "/audit", op: .remove, before: .object(["removedCount": .integer(Int64(result.removedAuditCount))])))
    diff.append(.init(path: "/blobs", op: .remove, before: .object([
      "removedCount": .integer(Int64(result.removedBlobCount)),
      "removedBytes": .integer(result.removedBlobBytes)
    ])))
    let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1_000).rounded() / 1_000)
    let timestamp = try canonicalDate(now)
    let auditId = "defa-\(UUID().uuidString.lowercased())"
    try transaction.execute(
      """
      INSERT INTO definition_change_audit(
        audit_id, workflow_name, operation, version_id, previous_version_id,
        target_node_id, target_field, before_digest, after_digest, diff_json,
        reason, evidence_refs_json, actor_kind, actor_id, approval_state,
        overwritten_changes_json, created_at
      ) VALUES (?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, ?, '[]', ?, ?, ?, NULL, ?)
      """,
      bindings: [.text(auditId), .text(head.workflowName), .text(operation.rawValue), .text(current.versionId),
                 .text(current.versionId), .text(current.documentDigest), .text(current.documentDigest),
                 .text(try canonicalString(diff)), .text(reason), .text(actor.kind.rawValue), .optionalText(actor.id),
                 .text(WorkflowDefinitionApprovalState.applied.rawValue), .text(timestamp)]
    )
    guard let row = try transaction.query("SELECT * FROM definition_change_audit WHERE audit_id = ?", bindings: [.text(auditId)]).first else {
      throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "definition retention audit was not recorded")
    }
    return try mapAudit(row)
  }
}
