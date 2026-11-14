import Foundation
import SQLite3

public enum MemoryHistoryRetirementError: Error, Equatable, Sendable {
  case retiredVersion
  case invalidRequest
}

public struct MemoryHistoryRetirementReport: Codable, Equatable, Sendable {
  public var dryRun: Bool
  public var status: String
  public var headVersion: Int64
  public var retainedFloor: Int64
  public var retiredRevisionCount: Int
  public var retiredDeltaBytes: Int64
  public var reclaimed: Bool
}

func ensureMemoryRetirementSchema(_ db: OpaquePointer?) throws {
  try execute(db, """
    CREATE TABLE IF NOT EXISTS memory_retirement (
      record_id INTEGER PRIMARY KEY REFERENCES memory_entries(record_id),
      retained_floor INTEGER NOT NULL CHECK(retained_floor > 0)
    )
    """)
}

extension RielaMemoryStore {
  /// Irreversibly retires revisions before the exact current head. No head data,
  /// record identifiers, ownership, references, or attachments are modified.
  /// Callers must quiesce their application: SQLite cannot recall values already
  /// loaded into another process's ordinary heap or external exported copies.
  public func retireHistory(
    memoryId: String, recordId: Int64, workflowId: String, nodeId: String,
    requiredTags: [String], expectedHeadVersion: Int64, throughVersion: Int64,
    dryRun: Bool = true
  ) throws -> MemoryHistoryRetirementReport {
    guard rootDirectory.hasPrefix("/"), recordId > 0, expectedHeadVersion > 1, throughVersion == expectedHeadVersion - 1,
      !workflowId.isEmpty, !nodeId.isEmpty, !requiredTags.isEmpty else {
      throw MemoryHistoryRetirementError.invalidRequest
    }
    let path = try databasePath(memoryId: memoryId)
    let url = URL(fileURLWithPath: path)
    guard url.path == url.resolvingSymlinksInPath().path,
      FileManager.default.fileExists(atPath: path) else {
      throw MemoryHistoryRetirementError.invalidRequest
    }
    for suffix in ["", "-wal", "-shm", "-journal"] {
      let sibling = path + suffix
      if FileManager.default.fileExists(atPath: sibling) ||
        (try? FileManager.default.destinationOfSymbolicLink(atPath: sibling)) != nil {
        let attributes = try FileManager.default.attributesOfItem(atPath: sibling)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
          (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
          URL(fileURLWithPath: sibling).resolvingSymlinksInPath().path == sibling else {
          throw MemoryHistoryRetirementError.invalidRequest
        }
      }
    }
    let db = try openDatabase(memoryId: memoryId, readOnly: dryRun)
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 0)
    var report = MemoryHistoryRetirementReport(dryRun: dryRun, status: "blocked",
      headVersion: 0, retainedFloor: 1, retiredRevisionCount: 0, retiredDeltaBytes: 0, reclaimed: false)
    // Exclusive locking mode holds database admission through COMMIT, VACUUM,
    // checkpoint and close. In WAL mode it also excludes concurrent readers.
    if !dryRun {
      do {
        _ = try queryRows(db, sql: "PRAGMA locking_mode = EXCLUSIVE", bindings: [])
        try execute(db, "BEGIN EXCLUSIVE")
      } catch { report.status = "busy"; return report }
    } else { try execute(db, "BEGIN") }
    var committed = false
    defer { if !committed { try? execute(db, "ROLLBACK") } }
    let schema = try queryRows(db, sql: "PRAGMA user_version", bindings: []).first?
      .columns["user_version"].flatMap(Int.init) ?? 0
    guard schema == 4 || schema == currentSchemaVersion else {
      report.status = "unsupported_schema"; return report
    }
    let row = try record(memoryId: memoryId, recordId: recordId, db: db)
    guard row.workflowId == workflowId, row.nodeId == nodeId,
      Set(requiredTags).isSubset(of: Set(row.tags)) else {
      report.status = "ownership_mismatch"; return report
    }
    let headRow = try queryRows(db,
      sql: "SELECT version AS head,recorded_at FROM memory_evolution WHERE record_id=? ORDER BY version DESC LIMIT 1",
      bindings: [.int64(recordId)]).first?.columns ?? [:]
    let head = headRow["head"].flatMap(Int64.init) ?? 0
    report.headVersion = head
    guard head == expectedHeadVersion else { report.status = "stale_head"; return report }
    if schema >= 5 {
      report.retainedFloor = try queryRows(db, sql: "SELECT retained_floor FROM memory_retirement WHERE record_id=?",
        bindings: [.int64(recordId)]).first?.columns["retained_floor"].flatMap(Int64.init) ?? 1
    }
    guard report.retainedFloor >= 1, report.retainedFloor <= head else {
      report.status = "invalid_floor"; return report
    }
    // Load/search reference rows are immutable access audit, not version pins.
    // Preserve them; only actual related-record links protect this record.
    let referenced = try queryRows(db, sql: """
      SELECT 1 FROM memory_entries e, json_each(e.related_record_ids_json) r WHERE r.value=? LIMIT 1
      """, bindings: [.int64(recordId)])
    guard referenced.isEmpty, row.relatedRecordIds.isEmpty else {
      report.status = "referenced"; return report
    }
    let attachments = try queryRows(db, sql: "SELECT 1 FROM memory_evolution_attachments LIMIT 1", bindings: [])
    guard row.files.isEmpty, attachments.isEmpty else { report.status = "attachments"; return report }
    // Other reverse deltas may contain a related-record reference or an exact
    // version reference unknown to this schema. Conservatively protect them.
    let otherFloor = schema >= 5
      ? "COALESCE((SELECT retained_floor FROM memory_retirement f WHERE f.record_id=v.record_id),1)" : "1"
    let otherHistory = try queryRows(db,
      sql: "SELECT 1 FROM memory_evolution v WHERE record_id<>? AND version>\(otherFloor) LIMIT 1",
      bindings: [.int64(recordId)])
    guard otherHistory.isEmpty else { report.status = "other_history"; return report }
    // Validate the entire retained chain and its typed references before discard.
    // A malformed/gapped chain is an error, never permission to discard history.
    guard head - report.retainedFloor <= 1000 else {
      report.status = "history_too_large"; return report
    }
    let chainRows = try queryRows(db,
      sql: "SELECT COUNT(*) AS count FROM memory_evolution WHERE record_id=? AND version>=?",
      bindings: [.int64(recordId), .int64(report.retainedFloor)]).first?.columns["count"].flatMap(Int64.init) ?? 0
    guard chainRows == head - report.retainedFloor + 1 else {
      report.status = "invalid_chain"; return report
    }
    for version in report.retainedFloor..<head {
      let historical = try recordVersion(memoryId: memoryId, recordId: recordId, version: version, db: db)
      guard historical.relatedRecordIds.isEmpty, historical.files.isEmpty else {
        report.status = "historical_references"; return report
      }
    }
    let count = try queryRows(db, sql: """
      SELECT COUNT(*) AS count, COALESCE(SUM(length(CAST(reverse_delta_json AS BLOB))),0) AS bytes
      FROM memory_evolution WHERE record_id=? AND version> ?
      """, bindings: [.int64(recordId), .int64(report.retainedFloor)]).first?.columns ?? [:]
    report.retiredRevisionCount = Int(count["count"] ?? "0") ?? 0
    report.retiredDeltaBytes = Int64(count["bytes"] ?? "0") ?? 0
    guard !dryRun else { report.status = "planned"; return report }
    // Migration 4->5 only adds the floor table, inside this exclusive transaction.
    try ensureMemoryRetirementSchema(db)
    try execute(db, "PRAGMA user_version = \(currentSchemaVersion)")
    _ = try queryRows(db, sql: "PRAGMA secure_delete = ON", bindings: [])
    // PERSIST rollback journals otherwise retain pre-retirement page images.
    // Native SQLite truncates the journal at commit; do not unlink sidecars.
    _ = try queryRows(db, sql: "PRAGMA journal_size_limit = 0", bindings: [])
    // Keep the monotonic head marker. Its identity edge contains no old payload
    // bytes and cannot be followed below the retained floor.
    let bytes = Data(try encodedJSONString(row).utf8)
    let marker = try EvolutionReverseDelta(previous: bytes, next: bytes, nextVersion: head)
    try execute(db, "DELETE FROM memory_evolution WHERE record_id=?", bindings: [.int64(recordId)])
    try execute(db, """
      INSERT INTO memory_evolution(record_id,version,recorded_at,reverse_delta_json) VALUES(?,?,?,?)
      """, bindings: [.int64(recordId), .int64(head), .text(headRow["recorded_at"] ?? ""), .text(try encodedJSONString(marker))])
    try execute(db, """
      INSERT INTO memory_retirement(record_id,retained_floor) VALUES(?,?)
      ON CONFLICT(record_id) DO UPDATE SET retained_floor=excluded.retained_floor
      """, bindings: [.int64(recordId), .int64(head)])
    try execute(db, "COMMIT"); committed = true
    report.retainedFloor = head
    do {
      try execute(db, "VACUUM")
      let checkpoint = try queryRows(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)", bindings: [])
      guard checkpoint.first?.columns["busy"] != "1" else {
        report.status = "pending_reclaim"; return report
      }
      report.reclaimed = true; report.status = "retired"
    } catch { report.status = "pending_reclaim" }
    return report
  }
}
