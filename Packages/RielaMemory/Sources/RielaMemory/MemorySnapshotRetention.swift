import Foundation
import SQLite3

func ensureMemorySnapshotRetentionSchema(_ db: OpaquePointer?) throws {
  try execute(db, """
    CREATE TABLE IF NOT EXISTS memory_snapshot_retention (
      scope TEXT NOT NULL, label TEXT NOT NULL,
      record_id INTEGER NOT NULL REFERENCES memory_entries(record_id),
      version INTEGER NOT NULL CHECK(version>0), expires_at INTEGER NOT NULL,
      PRIMARY KEY(scope,label)
    )
    """)
}

func snapshotRetentionNow() -> Int64 { Int64(Date().timeIntervalSince1970) }

extension RielaMemoryStore {
  /// Retain an exact current revision before a producer advances its head. Only
  /// metadata is written: cache bodies, provider cursors and the head never move.
  /// A label cannot be rebound to a different active revision. Expired labels
  /// are removed on retain; their history is left to explicit SDK retirement.
  @discardableResult
  public func retainSnapshot(
    memoryId: String, workflowId: String, nodeId: String?, tag: String,
    label: String, expectedHead: MemorySnapshotHead, expiresInSeconds: Int = 86_400,
    maxPayloadBytes: Int = 8_000_000
  ) throws -> MemorySnapshot {
    try validateSnapshotScope(memoryId: memoryId, workflowId: workflowId, nodeId: nodeId, tag: tag, limit: maxPayloadBytes)
    try validateSnapshotLabel(label)
    guard (60...604_800).contains(expiresInSeconds) else { throw MemorySnapshotError.invalidScope }
    guard FileManager.default.fileExists(atPath: try databasePath(memoryId: memoryId)) else { throw MemorySnapshotError.conflict }
    try prepareSnapshotDirectory()
    let db = try openDatabase(memoryId: memoryId)
    defer { sqlite3_close(db) }
    try secureSnapshotFiles(memoryId: memoryId); try ensureSchema(db)
    try execute(db, "BEGIN IMMEDIATE")
    defer { try? execute(db, "ROLLBACK") }
    guard let selected = try selectedSnapshot(memoryId: memoryId, workflowId: workflowId, nodeId: nodeId,
      tag: tag, maxPayloadBytes: maxPayloadBytes, db: db), selected.head == expectedHead else { throw MemorySnapshotError.conflict }
    let now = snapshotRetentionNow()
    try execute(db, "DELETE FROM memory_snapshot_retention WHERE expires_at<=?", bindings: [.int64(now)])
    let existing = try retainedSnapshotHead(scope: expectedHead.scope, label: label, db: db, includeExpired: true)
    guard existing == nil || existing == expectedHead else { throw MemorySnapshotError.conflict }
    let count = try queryRows(db, sql: "SELECT COUNT(*) AS count FROM memory_snapshot_retention", bindings: [])
      .first?.columns["count"].flatMap(Int.init) ?? 256
    guard existing != nil || count < 256 else { throw MemorySnapshotError.invalidScope }
    try execute(db, """
      INSERT INTO memory_snapshot_retention(scope,label,record_id,version,expires_at) VALUES(?,?,?,?,?)
      ON CONFLICT(scope,label) DO UPDATE SET expires_at=excluded.expires_at
      """, bindings: [.text(expectedHead.scope), .text(label), .int64(expectedHead.recordId),
        .int64(expectedHead.version), .int64(now + Int64(expiresInSeconds))])
    try execute(db, "COMMIT")
    return selected
  }

  /// Read an immutable retained revision in one transaction without restoring it
  /// over a newer head. Missing/expired references return nil; no fallback to the
  /// latest revision can silently acknowledge newly acquired items.
  public func loadRetainedSnapshot(
    memoryId: String, workflowId: String, nodeId: String?, tag: String,
    label: String, maxPayloadBytes: Int = 8_000_000
  ) throws -> MemorySnapshot? {
    try validateSnapshotScope(memoryId: memoryId, workflowId: workflowId, nodeId: nodeId, tag: tag, limit: maxPayloadBytes)
    try validateSnapshotLabel(label)
    guard FileManager.default.fileExists(atPath: try databasePath(memoryId: memoryId)) else { return nil }
    try prepareSnapshotDirectory()
    let db = try openDatabase(memoryId: memoryId)
    defer { sqlite3_close(db) }
    try secureSnapshotFiles(memoryId: memoryId); try ensureSchema(db)
    try execute(db, "BEGIN")
    defer { try? execute(db, "ROLLBACK") }
    let scope = try snapshotScope(memoryId: memoryId, workflowId: workflowId, nodeId: nodeId, tag: tag)
    guard let head = try retainedSnapshotHead(scope: scope, label: label, db: db) else { return nil }
    let record = try recordVersion(memoryId: memoryId, recordId: head.recordId, version: head.version, db: db)
    guard record.workflowId == workflowId, nodeId == nil || record.nodeId == nodeId, record.tags.contains(tag) else {
      throw MemorySnapshotError.invalidScope
    }
    guard try encodedJSONString(record.payload).utf8.count <= maxPayloadBytes else {
      throw RielaMemoryError.payloadTooLarge(recordId: head.recordId, limit: maxPayloadBytes)
    }
    return MemorySnapshot(record: record, head: head)
  }

  /// Exact revision comparison also fences release against an expired label
  /// reused by another producer generation. A missing reference is idempotent.
  @discardableResult
  public func releaseSnapshot(
    memoryId: String, workflowId: String, nodeId: String?, tag: String,
    label: String, expectedHead: MemorySnapshotHead
  ) throws -> Bool {
    try validateSnapshotScope(memoryId: memoryId, workflowId: workflowId, nodeId: nodeId, tag: tag, limit: 1)
    try validateSnapshotLabel(label)
    let scope = try snapshotScope(memoryId: memoryId, workflowId: workflowId, nodeId: nodeId, tag: tag)
    guard expectedHead.scope == scope else { throw MemorySnapshotError.invalidScope }
    guard FileManager.default.fileExists(atPath: try databasePath(memoryId: memoryId)) else { return false }
    try prepareSnapshotDirectory()
    let db = try openDatabase(memoryId: memoryId)
    defer { sqlite3_close(db) }
    try secureSnapshotFiles(memoryId: memoryId); try ensureSchema(db)
    try execute(db, "BEGIN IMMEDIATE")
    defer { try? execute(db, "ROLLBACK") }
    let existing = try retainedSnapshotHead(scope: scope, label: label, db: db, includeExpired: true)
    guard let existing else { return false }
    guard existing == expectedHead else { throw MemorySnapshotError.conflict }
    try execute(db, "DELETE FROM memory_snapshot_retention WHERE scope=? AND label=?", bindings: [.text(scope), .text(label)])
    try execute(db, "COMMIT")
    return true
  }

  private func validateSnapshotLabel(_ label: String) throws {
    guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      label.utf8.count <= 512, !label.utf8.contains(0) else { throw MemorySnapshotError.invalidScope }
  }

  private func retainedSnapshotHead(scope: String, label: String, db: OpaquePointer?, includeExpired: Bool = false) throws -> MemorySnapshotHead? {
    let rows = try queryRows(db, sql: "SELECT record_id,version FROM memory_snapshot_retention WHERE scope=? AND label=?" +
      (includeExpired ? "" : " AND expires_at>\(snapshotRetentionNow())"), bindings: [.text(scope), .text(label)])
    guard let row = rows.first else { return nil }
    guard let id = row.columns["record_id"].flatMap(Int64.init), let version = row.columns["version"].flatMap(Int64.init) else {
      throw MemorySnapshotError.invalidHead
    }
    return .init(recordId: id, version: version, scope: scope)
  }
}
