import Foundation
import RielaSQLite
import RielaMemory

public enum WorkflowDefinitionRetentionMode: String, Codable, Equatable, Sendable {
  case prune
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
  public var audit: WorkflowDefinitionAuditRecord?
}

extension WorkflowDefinitionStore {
  private static let activeSessionStatuses = ["created", "running", "suspended"]

  public func workflowNames() throws -> [String] {
    let database = try openDatabase()
    return try database.query("SELECT workflow_name FROM definition_heads ORDER BY workflow_name").map { $0.string("workflow_name") }
  }

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
      if dryRun { try transaction.execute("SAVEPOINT definition_retention_preview") }
      guard let head = try readHead(workflowName: workflowName, in: transaction) else {
        throw WorkflowDefinitionStoreError(code: .headMissing, message: "definition head does not exist")
      }
      try releaseStalePins(workflowName: workflowName, in: transaction)
      let cutoff = canonicalDate(now().addingTimeInterval(-24 * 60 * 60))
      let protectedNumbers = try WorkflowDefinitionHistorySchema.protectedHistoryVersions(
        in: transaction, workflowName: workflowName, currentVersionId: head.currentVersionId,
        lastFileVersionId: head.lastFileVersionId, cutoff: cutoff
      )
      let protectedVersions = try protectedVersionDetails(
        workflowName: workflowName, head: head, protectedNumbers: protectedNumbers, in: transaction
      )
      let metadata = try transaction.query(
        "SELECT version_id, history_version, document_digest, operation, created_at FROM definition_versions WHERE workflow_name = ? ORDER BY history_version DESC",
        bindings: [.text(workflowName)]
      )
      let engine = try history(in: transaction)
      let droppedNumbers: [Int64]
      if mode == .prune {
        droppedNumbers = try engine.applyRetention(
          key: workflowName, currentHeadValue: nil, retainedGenerations: keepVersions ?? 1, pins: protectedNumbers
        ).dropped
      } else {
        droppedNumbers = try engine.retainVersions(key: workflowName, currentHeadValue: nil, versions: protectedNumbers).dropped
      }
      let droppedSet = Set(droppedNumbers)
      let removedRows = metadata.filter { row in
        guard let number = row["history_version"].flatMap(Int64.init) else { return false }
        return droppedSet.contains(number)
      }
      let removedIds = removedRows.map { $0.string("version_id") }
      let keptIds = metadata.filter { row in
        guard let number = row["history_version"].flatMap(Int64.init) else { return false }
        return !droppedSet.contains(number)
      }.map { $0.string("version_id") }
      let blobsBefore = try transaction.query(
        "SELECT COUNT(*) AS count, COALESCE(SUM(length(blob)), 0) AS bytes FROM definition_history_versions WHERE key = ? AND version IN (\(sqlPlaceholders(droppedNumbers.count)))",
        bindings: [.text(workflowName)] + droppedNumbers.map(SQLiteValue.int)
      ).first
      let blobCount = blobsBefore?["count"].flatMap(Int.init) ?? 0
      let blobBytes = blobsBefore?["bytes"].flatMap(Int64.init) ?? 0
      let auditCountBefore = try countAudit(workflowName: workflowName, in: transaction)

      if mode == .prune {
        try WorkflowDefinitionHistorySchema.deleteDroppedVersionsAndOrphanAudit(droppedNumbers, workflowName: workflowName, in: transaction)
      } else {
        try WorkflowDefinitionHistorySchema.deleteDroppedVersionsAndOrphanAudit(droppedNumbers, workflowName: workflowName, in: transaction)
        try WorkflowDefinitionHistorySchema.withGuardedDelete(transaction) {
          try transaction.execute("DELETE FROM definition_change_audit WHERE workflow_name = ?", bindings: [.text(workflowName)])
        }
      }
      let auditCountAfterRemoval = try countAudit(workflowName: workflowName, in: transaction)
      let removedAuditCount = max(0, auditCountBefore - auditCountAfterRemoval)
      let shouldRecord = mode == .purgeHistory || !removedIds.isEmpty || removedAuditCount > 0
      let result = WorkflowDefinitionRetentionResult(
        workflowName: workflowName, mode: mode, dryRun: dryRun, keepVersions: keepVersions,
        keptVersionIds: keptIds, protectedVersions: protectedVersions, removedVersionIds: removedIds,
        removedAuditCount: removedAuditCount, removedBlobCount: blobCount, removedBlobBytes: blobBytes, audit: nil
      )
      var finalResult = result
      if shouldRecord && !dryRun {
        finalResult.audit = try insertRetentionAudit(
          head: head, result: result, removedRows: removedRows, reason: reason, actor: actor, in: transaction
        )
      }
      if dryRun {
        try transaction.execute("ROLLBACK TO SAVEPOINT definition_retention_preview")
        try transaction.execute("RELEASE SAVEPOINT definition_retention_preview")
      }
      return finalResult
    }
  }

  private func protectedVersionDetails(
    workflowName: String,
    head: WorkflowDefinitionHead,
    protectedNumbers: Set<Int64>,
    in database: SQLiteDatabase
  ) throws -> [WorkflowDefinitionProtectedVersion] {
    let rows = try database.query("SELECT version_id, history_version FROM definition_versions WHERE workflow_name = ?", bindings: [.text(workflowName)])
    let ids = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (Int64, String)? in
      guard let number = row["history_version"].flatMap(Int64.init) else { return nil }
      return (number, row.string("version_id"))
    })
    var values: [WorkflowDefinitionProtectedVersion] = [
      .init(versionId: head.currentVersionId, reason: "current")
    ]
    if head.lastFileVersionId != head.currentVersionId {
      values.append(.init(versionId: head.lastFileVersionId, reason: "lastFileImport"))
    }
    let pinnedNumbers = Set(try database.query(
      "SELECT history_version FROM definition_version_pins WHERE workflow_name = ?",
      bindings: [.text(workflowName)]
    ).compactMap { $0["history_version"].flatMap(Int64.init) })
    for number in protectedNumbers.sorted() where number != idsFor(head.currentVersionId, in: ids) && number != idsFor(head.lastFileVersionId, in: ids) {
      guard let id = ids[number] else { continue }
      values.append(.init(versionId: id, reason: pinnedNumbers.contains(number) ? "activeSession" : "formerHead24h"))
    }
    return values
  }

  private func idsFor(_ versionId: String, in versions: [Int64: String]) -> Int64? {
    versions.first(where: { $0.value == versionId })?.key
  }

  private func countAudit(workflowName: String, in database: SQLiteDatabase) throws -> Int {
    try database.query("SELECT COUNT(*) AS count FROM definition_change_audit WHERE workflow_name = ?", bindings: [.text(workflowName)])
      .first?["count"].flatMap(Int.init) ?? 0
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
      WorkflowDefinitionDiffEntry(path: "/versions/\(row.string("version_id"))", op: .remove, before: .object([
        "documentDigest": .string(row.string("document_digest")), "operation": .string(row.string("operation")),
        "createdAt": .string(row.string("created_at"))
      ]))
    }
    if let keep = result.keepVersions {
      diff.append(.init(path: "/retention/keepVersions", op: .add, after: .integer(Int64(keep))))
    }
    diff.append(.init(path: "/audit", op: .remove, before: .object(["removedCount": .integer(Int64(result.removedAuditCount))])))
    diff.append(.init(path: "/blobs", op: .remove, before: .object([
      "removedCount": .integer(Int64(result.removedBlobCount)), "removedBytes": .integer(result.removedBlobBytes)
    ])))
    let timestamp = canonicalDate(now())
    let auditId = "defa-\(UUID().uuidString.lowercased())"
    try transaction.execute(
      """
      INSERT INTO definition_change_audit(
        audit_id, workflow_name, operation, version_id, previous_version_id, target_node_id, target_field,
        before_digest, after_digest, diff_json, reason, evidence_refs_json, actor_kind, actor_id,
        approval_state, overwritten_changes_json, created_at
      ) VALUES (?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, ?, '[]', ?, ?, 'applied', NULL, ?)
      """,
      bindings: [.text(auditId), .text(head.workflowName), .text(operation.rawValue), .text(current.versionId),
        .text(current.versionId), .text(current.documentDigest), .text(current.documentDigest),
        .text(try canonicalString(diff)), .text(reason.trimmingCharacters(in: .whitespacesAndNewlines)),
        .text(actor.kind.rawValue), .optionalText(actor.id), .text(timestamp)]
    )
    guard let row = try transaction.query("SELECT * FROM definition_change_audit WHERE audit_id = ?", bindings: [.text(auditId)]).first else {
      throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "definition retention audit was not recorded")
    }
    return try mapAudit(row)
  }

  private func sqlPlaceholders(_ count: Int) -> String {
    count == 0 ? "NULL" : Array(repeating: "?", count: count).joined(separator: ",")
  }

  private func canonicalDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
