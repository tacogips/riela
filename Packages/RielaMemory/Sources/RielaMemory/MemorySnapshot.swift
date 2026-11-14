import Crypto
import Foundation
import SQLite3

/// A revision belongs to the selected workflow/node/tag head, not just a row ID.
public struct MemorySnapshotHead: Codable, Equatable, Sendable {
  public var recordId: Int64
  public var version: Int64
  public var scope: String

  public init(recordId: Int64, version: Int64, scope: String) {
    self.recordId = recordId; self.version = version; self.scope = scope
  }
}

public struct MemorySnapshot: Sendable {
  public let record: MemoryRecord
  public let head: MemorySnapshotHead
}

public enum MemorySnapshotError: Error, Equatable, Sendable {
  case conflict
  case invalidScope
  case invalidHead
  case readbackMismatch
}

extension RielaMemoryStore {
  /// Read payload and its exact revision in one transaction. Existing memory
  /// records remain readable; no second history query can race the payload.
  public func loadSnapshot(
    memoryId: String, workflowId: String, nodeId: String?, tag: String,
    maxPayloadBytes: Int = 8_000_000
  ) throws -> MemorySnapshot? {
    try validateSnapshotScope(memoryId: memoryId, workflowId: workflowId, nodeId: nodeId, tag: tag, limit: maxPayloadBytes)
    guard FileManager.default.fileExists(atPath: try databasePath(memoryId: memoryId)) else { return nil }
    try prepareSnapshotDirectory()
    let db = try openDatabase(memoryId: memoryId)
    defer { sqlite3_close(db) }
    try secureSnapshotFiles(memoryId: memoryId)
    try ensureSchema(db)
    // Old schema-3 rows may not have evolution metadata. Installing their
    // baseline revision is atomic with the read and never changes the payload.
    try execute(db, "BEGIN IMMEDIATE")
    defer { try? execute(db, "ROLLBACK") }
    let result = try selectedSnapshot(memoryId: memoryId, workflowId: workflowId, nodeId: nodeId,
      tag: tag, maxPayloadBytes: maxPayloadBytes, db: db)
    try execute(db, "COMMIT")
    return result
  }

  /// Compare the selected head and commit under one SQLite write transaction.
  /// nil explicitly means "create only if no matching head exists".
  @discardableResult
  public func commitSnapshot(
    memoryId: String, workflowId: String, nodeId: String?, tag: String,
    expectedHead: MemorySnapshotHead?, payload: MemoryJSONValue,
    maxPayloadBytes: Int = 8_000_000
  ) throws -> MemorySnapshot {
    try validateSnapshotScope(memoryId: memoryId, workflowId: workflowId, nodeId: nodeId, tag: tag, limit: maxPayloadBytes)
    if let expectedHead {
      guard expectedHead.recordId > 0, expectedHead.version > 0,
        expectedHead.scope.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else { throw MemorySnapshotError.invalidHead }
    }
    let encoded = try encodedJSONString(payload)
    guard encoded.utf8.count <= maxPayloadBytes else { throw RielaMemoryError.payloadTooLarge(recordId: expectedHead?.recordId ?? 0, limit: maxPayloadBytes) }
    try prepareSnapshotDirectory()
    let db = try openDatabase(memoryId: memoryId)
    defer { sqlite3_close(db) }
    try secureSnapshotFiles(memoryId: memoryId)
    try ensureSchema(db)
    try execute(db, "BEGIN IMMEDIATE")
    defer { try? execute(db, "ROLLBACK") }
    let previous = try selectedSnapshot(memoryId: memoryId, workflowId: workflowId, nodeId: nodeId,
      tag: tag, maxPayloadBytes: maxPayloadBytes, db: db)
    guard previous?.head == expectedHead else { throw MemorySnapshotError.conflict }
    let id: Int64
    if let previous {
      id = previous.head.recordId
      try execute(db, "UPDATE memory_entries SET payload_json = jsonb(?) WHERE record_id = ?",
        bindings: [.text(encoded), .int64(id)])
    } else {
      try execute(db, """
        INSERT INTO memory_entries (workflow_id, node_id, registered_at, tags_json, related_record_ids_json, payload_json)
        VALUES (?, ?, ?, jsonb(?), jsonb('[]'), jsonb(?))
        """, bindings: [.text(workflowId), .optionalText(nodeId), .text(currentTimestamp()),
          .text(try encodedJSONString([tag])), .text(encoded)])
      id = sqlite3_last_insert_rowid(db)
    }
    let updated = try record(memoryId: memoryId, recordId: id, db: db)
    guard updated.payload == payload else { throw MemorySnapshotError.readbackMismatch }
    let historyResult = try historyWrite(previous: previous?.record, next: updated, db: db, historyRetention: 1)
    let result = try snapshot(record: updated, scope: snapshotScope(memoryId: memoryId, workflowId: workflowId, nodeId: nodeId, tag: tag), db: db)
    try execute(db, "COMMIT")
    reclaimHistoryPages(db, freedBytes: historyResult.freedBytes)
    return result
  }

  func prepareSnapshotDirectory() throws {
    try FileManager.default.createDirectory(atPath: rootDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDirectory)
  }

  func secureSnapshotFiles(memoryId: String) throws {
    let path = try databasePath(memoryId: memoryId)
    for suffix in ["", "-wal", "-shm", "-journal"] where FileManager.default.fileExists(atPath: path + suffix) {
      do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path + suffix) } catch {
        // Another SQLite connection can remove a sidecar after fileExists.
        // Only an absent sidecar is benign; the main DB and other errors fail.
        guard !suffix.isEmpty, !FileManager.default.fileExists(atPath: path + suffix) else { throw error }
      }
    }
  }

  func validateSnapshotScope(memoryId: String, workflowId: String, nodeId: String?, tag: String, limit: Int) throws {
    try validateMemoryId(memoryId); try validateWorkflowId(workflowId); try validateTags([tag])
    guard !tag.isEmpty, nodeId == nil || !(nodeId?.isEmpty ?? true), (1...64 * 1024 * 1024).contains(limit) else {
      throw MemorySnapshotError.invalidScope
    }
  }

  func selectedSnapshot(
    memoryId: String, workflowId: String, nodeId: String?, tag: String,
    maxPayloadBytes: Int, db: OpaquePointer?
  ) throws -> MemorySnapshot? {
    var sql = """
      SELECT record_id, length(CAST(json(payload_json) AS BLOB)) AS bytes FROM memory_entries
      WHERE workflow_id = ? AND EXISTS (SELECT 1 FROM json_each(json(tags_json)) WHERE value = ?)
      """
    var bindings: [SQLiteBinding] = [.text(workflowId), .text(tag)]
    if let nodeId { sql += " AND node_id = ?"; bindings.append(.text(nodeId)) }
    sql += " ORDER BY registered_at DESC, record_id DESC LIMIT 1"
    let rows = try queryRows(db, sql: sql, bindings: bindings)
    guard let row = rows.first, let id = row.columns["record_id"].flatMap(Int64.init) else { return nil }
    guard let bytes = row.columns["bytes"].flatMap(Int.init), bytes <= maxPayloadBytes else {
      throw RielaMemoryError.payloadTooLarge(recordId: id, limit: maxPayloadBytes)
    }
    return try snapshot(record: record(memoryId: memoryId, recordId: id, db: db),
      scope: snapshotScope(memoryId: memoryId, workflowId: workflowId, nodeId: nodeId, tag: tag), db: db)
  }

  func snapshotScope(memoryId: String, workflowId: String, nodeId: String?, tag: String) throws -> String {
    let root = URL(fileURLWithPath: rootDirectory).standardizedFileURL.resolvingSymlinksInPath().path
    let identity: [MemoryJSONValue] = [.string(root), .string(memoryId), .string(workflowId), nodeId.map(MemoryJSONValue.string) ?? .null, .string(tag)]
    return SHA256.hash(data: try JSONEncoder().encode(identity)).map { String(format: "%02x", $0) }.joined()
  }

  private func snapshot(record: MemoryRecord, scope: String, db: OpaquePointer?) throws -> MemorySnapshot {
    if try memoryHistoryExists(recordId: record.recordId, db: db),
      let head = try memoryHistoryStore(db: db).head(key: String(record.recordId)) {
      return MemorySnapshot(record: record, head: .init(recordId: record.recordId, version: head.revision, scope: scope))
    }
    let rows = try queryRows(db, sql: "SELECT MAX(version) AS version FROM memory_evolution WHERE record_id = ?",
      bindings: [.int64(record.recordId)])
    let version: Int64
    if let existing = rows.first?.columns["version"].flatMap(Int64.init) {
      guard existing > 0 else { throw MemorySnapshotError.invalidHead }; version = existing
    } else {
      let floor = try queryRows(db, sql: "SELECT retained_floor FROM memory_retirement WHERE record_id = ?",
        bindings: [.int64(record.recordId)]).first?.columns["retained_floor"].flatMap(Int64.init) ?? 1
      guard floor == 1 else { throw MemorySnapshotError.invalidHead }
      _ = try historyWrite(previous: nil, next: record, db: db, historyRetention: 1)
      version = 1
    }
    return MemorySnapshot(record: record, head: .init(recordId: record.recordId, version: version, scope: scope))
  }
}
