import Foundation
import SQLite3

public struct MemoryEvolutionRevision: Codable, Equatable, Sendable {
  public let version: Int64
  public let recordedAt: String
  public let reverseDelta: EvolutionReverseDelta?
}

public enum MemoryEvolutionError: Error, Equatable, Sendable {
  case staleHead(expected: Int64, actual: Int64)
  case missingAttachment(String)
}

func ensureMemoryEvolutionSchema(_ db: OpaquePointer?) throws {
  try ensureMemoryRetirementSchema(db)
  try execute(db, """
    CREATE TABLE IF NOT EXISTS memory_evolution_attachments (
      path TEXT PRIMARY KEY NOT NULL,
      content_sha256 TEXT NOT NULL
    )
    """)
  try execute(db, """
    CREATE TABLE IF NOT EXISTS memory_evolution (
      record_id INTEGER NOT NULL REFERENCES memory_entries(record_id),
      version INTEGER NOT NULL CHECK(version > 0),
      recorded_at TEXT NOT NULL,
      reverse_delta_json TEXT,
      PRIMARY KEY(record_id, version),
      CHECK((version = 1 AND reverse_delta_json IS NULL) OR
            (version > 1 AND reverse_delta_json IS NOT NULL))
    )
    """)
}

extension RielaMemoryStore {
  /// Lists newest first, without reconstructing historical record values.
  public func evolutionHistory(
    memoryId: String, recordId: Int64, limit: Int = 30, beforeVersion: Int64? = nil
  ) throws -> [MemoryEvolutionRevision] {
    guard limit > 0, limit <= 1_000 else { throw RielaMemoryError.invalidLimit(limit) }
    let db = try openDatabase(memoryId: memoryId)
    defer { sqlite3_close(db) }
    try ensureSchema(db)
    let rows = try queryRows(db, sql: """
      SELECT version, recorded_at, CASE WHEN version = COALESCE((SELECT retained_floor FROM memory_retirement WHERE record_id = ?), 1) THEN NULL ELSE reverse_delta_json END AS reverse_delta_json FROM memory_evolution
      WHERE record_id = ? AND version < ? AND version >= COALESCE((SELECT retained_floor FROM memory_retirement WHERE record_id = ?), 1) ORDER BY version DESC LIMIT ?
      """, bindings: [.int64(recordId), .int64(recordId), .int64(beforeVersion ?? Int64.max), .int64(recordId), .int(limit)])
    return try rows.map { row in
      guard let version = row.columns["version"].flatMap(Int64.init),
        let timestamp = row.columns["recorded_at"] else {
        throw RielaMemoryError.sqliteFailed("malformed evolution revision")
      }
      return MemoryEvolutionRevision(
        version: version, recordedAt: timestamp,
        reverseDelta: try row.columns["reverse_delta_json"].map {
          try JSONDecoder().decode(EvolutionReverseDelta.self, from: Data($0.utf8))
        }
      )
    }
  }

  /// Reads head and deltas in one SQLite transaction. Historical file references
  /// point to retained attachments; they are not copied for every version.
  public func recordVersion(memoryId: String, recordId: Int64, version: Int64) throws -> MemoryRecord {
    guard version > 0 else { throw EvolutionReverseDelta.ValidationError.invalidVersion }
    let db = try openDatabase(memoryId: memoryId)
    defer { sqlite3_close(db) }
    try ensureSchema(db)
    try execute(db, "BEGIN")
    defer { try? execute(db, "ROLLBACK") }
    return try recordVersion(memoryId: memoryId, recordId: recordId, version: version, db: db)
  }

  /// Restoration appends a revision under the same write lock used by updates.
  /// The expected head prevents restoring over an intervening improvement.
  @discardableResult
  public func restoreRecordVersion(
    memoryId: String, recordId: Int64, version: Int64, expectedHeadVersion: Int64
  ) throws -> MemoryRecord {
    let db = try openDatabase(memoryId: memoryId)
    defer { sqlite3_close(db) }
    try ensureSchema(db)
    try execute(db, "BEGIN IMMEDIATE")
    defer { try? execute(db, "ROLLBACK") }
    let head = try evolutionHead(recordId: recordId, db: db)
    guard head == expectedHeadVersion else {
      throw MemoryEvolutionError.staleHead(expected: expectedHeadVersion, actual: head)
    }
    let previous = try record(memoryId: memoryId, recordId: recordId, db: db)
    let restored = try recordVersion(memoryId: memoryId, recordId: recordId, version: version, db: db)
    for file in restored.files where !FileManager.default.fileExists(atPath: file.path) {
      throw MemoryEvolutionError.missingAttachment(file.path)
    }
    try validateRelatedRecordIdsExist(restored.relatedRecordIds, db: db)
    try execute(db, """
      UPDATE memory_entries SET tags_json = jsonb(?), related_record_ids_json = jsonb(?), payload_json = jsonb(?)
      WHERE record_id = ?
      """, bindings: [.text(try encodedJSONString(restored.tags)), .text(try encodedJSONString(restored.relatedRecordIds)),
        .text(try encodedJSONString(restored.payload)), .int64(recordId)])
    _ = try replaceFiles(restored.files, recordId: recordId, db: db)
    try recordEvolution(previous: previous, next: restored, db: db, forceRevision: true)
    try execute(db, "COMMIT")
    return restored
  }

  private func evolutionHead(recordId: Int64, db: OpaquePointer?) throws -> Int64 {
    let rows = try queryRows(db, sql: "SELECT MAX(version) AS version FROM memory_evolution WHERE record_id = ?",
      bindings: [.int64(recordId)])
    guard let head = rows.first?.columns["version"].flatMap(Int64.init) else {
      throw EvolutionReverseDelta.ValidationError.invalidVersion
    }
    return head
  }

  func recordVersion(memoryId: String, recordId: Int64, version: Int64, db: OpaquePointer?) throws -> MemoryRecord {
    let current = try record(memoryId: memoryId, recordId: recordId, db: db)
    let head = try evolutionHead(recordId: recordId, db: db)
    let hasFloor = try !queryRows(db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='memory_retirement'", bindings: []).isEmpty
    let floor = try hasFloor ? queryRows(db, sql: "SELECT retained_floor FROM memory_retirement WHERE record_id = ?",
      bindings: [.int64(recordId)]).first?.columns["retained_floor"].flatMap(Int64.init) ?? 1 : 1
    guard version >= floor else { throw MemoryHistoryRetirementError.retiredVersion }
    guard version > 0, version <= head else {
      throw EvolutionReverseDelta.ValidationError.invalidVersion
    }
    var bytes = Data(try encodedJSONString(current).utf8)
    var expected = head
    try streamRows(db, sql: """
      SELECT version, reverse_delta_json FROM memory_evolution
      WHERE record_id = ? AND version > ? ORDER BY version DESC
      """, bindings: [.int64(recordId), .int64(version)]) { row in
      guard row.columns["version"].flatMap(Int64.init) == expected,
        let encoded = row.columns["reverse_delta_json"] else {
        throw RielaMemoryError.sqliteFailed("evolution history has a missing edge")
      }
      let delta = try JSONDecoder().decode(EvolutionReverseDelta.self, from: Data(encoded.utf8))
      bytes = try delta.reconstructPrevious(from: bytes, version: expected)
      expected -= 1
      return true
    }
    guard expected == version else { throw EvolutionReverseDelta.ValidationError.invalidVersion }
    let restored = try JSONDecoder().decode(MemoryRecord.self, from: bytes)
    try verifyEvolutionAttachments(restored.files, db: db, recordMissing: false)
    return restored
  }

  func recordEvolution(previous: MemoryRecord?, next: MemoryRecord, db: OpaquePointer?, forceRevision: Bool = false) throws {
    if let previous { try verifyEvolutionAttachments(previous.files, db: db, recordMissing: true) }
    try verifyEvolutionAttachments(next.files, db: db, recordMissing: true)
    let rows = try queryRows(db, sql: "SELECT MAX(version) AS version FROM memory_evolution WHERE record_id = ?",
      bindings: [.int64(next.recordId)])
    var head = rows.first?.columns["version"].flatMap(Int64.init)
    if head == nil {
      try execute(db, """
        INSERT INTO memory_evolution(record_id, version, recorded_at, reverse_delta_json)
        VALUES (?, 1, ?, NULL)
        """, bindings: [.int64(next.recordId), .text(currentTimestamp())])
      head = 1
    }
    guard let previous, let head else { return }
    let oldBytes = Data(try encodedJSONString(previous).utf8)
    let newBytes = Data(try encodedJSONString(next).utf8)
    guard forceRevision || oldBytes != newBytes else { return }
    guard head < Int64.max else { throw EvolutionReverseDelta.ValidationError.invalidVersion }
    let delta = try EvolutionReverseDelta(previous: oldBytes, next: newBytes, nextVersion: head + 1)
    try execute(db, """
      INSERT INTO memory_evolution(record_id, version, recorded_at, reverse_delta_json)
      VALUES (?, ?, ?, ?)
      """, bindings: [.int64(next.recordId), .int64(head + 1), .text(currentTimestamp()), .text(try encodedJSONString(delta))])
  }
}
