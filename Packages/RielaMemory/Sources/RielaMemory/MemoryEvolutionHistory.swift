import Foundation
import SQLite3

public struct MemoryEvolutionRevision: Codable, Equatable, Sendable {
  public let version: Int64
  public let recordedAt: String
  public let reverseDelta: EvolutionReverseDelta?
  public let isHead: Bool?
  public let revision: Int64?
  public let storage: VersionedHistoryVersionInfo?

  public init(version: Int64, recordedAt: String, reverseDelta: EvolutionReverseDelta?, isHead: Bool? = nil,
              revision: Int64? = nil, storage: VersionedHistoryVersionInfo? = nil) {
    self.version = version; self.recordedAt = recordedAt; self.reverseDelta = reverseDelta
    self.isHead = isHead; self.revision = revision; self.storage = storage
  }
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
    if try memoryHistoryExists(recordId: recordId, db: db) {
      let store = try memoryHistoryStore(db: db)
      let head = try store.head(key: String(recordId))
      return try store.versions(key: String(recordId), limit: limit, beforeVersion: beforeVersion).map { info in
        MemoryEvolutionRevision(version: info.version, recordedAt: info.createdAt, reverseDelta: nil,
          isHead: info.isHead, revision: info.isHead ? head?.revision : nil, storage: info)
      }
    }
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
    memoryId: String, recordId: Int64, version: Int64, expectedHeadVersion: Int64, historyRetention: Int? = nil
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
    let historyResult = try historyWrite(previous: previous, next: restored, db: db, force: true, historyRetention: historyRetention)
    try execute(db, "COMMIT")
    reclaimHistoryPages(db, freedBytes: historyResult.freedBytes)
    return restored
  }

  func evolutionHead(recordId: Int64, db: OpaquePointer?) throws -> Int64 {
    if try memoryHistoryExists(recordId: recordId, db: db),
      let revision = try memoryHistoryStore(db: db).head(key: String(recordId))?.revision { return revision }
    let rows = try queryRows(db, sql: "SELECT MAX(version) AS version FROM memory_evolution WHERE record_id = ?",
      bindings: [.int64(recordId)])
    guard let head = rows.first?.columns["version"].flatMap(Int64.init) else {
      throw EvolutionReverseDelta.ValidationError.invalidVersion
    }
    return head
  }

  func recordVersion(memoryId: String, recordId: Int64, version: Int64, db: OpaquePointer?) throws -> MemoryRecord {
    let current = try record(memoryId: memoryId, recordId: recordId, db: db)
    if try memoryHistoryExists(recordId: recordId, db: db) {
      let bytes = try memoryHistoryStore(db: db).value(key: String(recordId), version: version,
        currentHeadValue: memoryHistoryHeadBytes(current))
      let restored = try JSONDecoder().decode(MemoryRecord.self, from: bytes)
      try verifyEvolutionAttachments(restored.files, db: db, recordMissing: false)
      return restored
    }
    let head = try evolutionHead(recordId: recordId, db: db)
    let hasFloor = try !queryRows(db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='memory_retirement'", bindings: []).isEmpty
    let floor = try hasFloor ? queryRows(db, sql: "SELECT retained_floor FROM memory_retirement WHERE record_id = ?",
      bindings: [.int64(recordId)]).first?.columns["retained_floor"].flatMap(Int64.init) ?? 1 : 1
    guard version >= floor else { throw MemoryHistoryRetirementError.retiredVersion }
    guard version > 0, version <= head else {
      throw EvolutionReverseDelta.ValidationError.invalidVersion
    }
    let bytes = try walkReverseChain(current: current, head: head, floor: version, db: db) { _, _ in true }.bytes
    let restored = try JSONDecoder().decode(MemoryRecord.self, from: bytes)
    try verifyEvolutionAttachments(restored.files, db: db, recordMissing: false)
    return restored
  }

  // Visit each historical snapshot once, following the reverse chain from the
  // current head. Reconstructing each version independently repeats every edge.
  func walkHistoricalRecords(current: MemoryRecord, head: Int64, floor: Int64, db: OpaquePointer?,
                             onEdge: ((Int64) -> Void)? = nil,
                             visit: (MemoryRecord) throws -> Bool) throws -> Bool {
    try walkReverseChain(current: current, head: head, floor: floor, db: db, onEdge: onEdge) { bytes, _ in
      let restored = try JSONDecoder().decode(MemoryRecord.self, from: bytes)
      try verifyEvolutionAttachments(restored.files, db: db, recordMissing: false)
      return try visit(restored)
    }.completed
  }

  /// The single reverse-delta walker: applies each edge from `head` down to
  /// `floor + 1` exactly once, in descending order, handing every reconstructed
  /// snapshot (and the version it now represents) to `visit`. A gap in the chain
  /// throws; stopping early (visit returns false) skips the final floor check.
  func walkReverseChain(current: MemoryRecord, head: Int64, floor: Int64, db: OpaquePointer?,
                        onEdge: ((Int64) -> Void)? = nil,
                        visit: (Data, Int64) throws -> Bool) throws -> (bytes: Data, completed: Bool) {
    var bytes = Data(try encodedJSONString(current).utf8)
    var expected = head
    var completed = true
    try streamRows(db, sql: """
      SELECT version, reverse_delta_json FROM memory_evolution
      WHERE record_id = ? AND version > ? ORDER BY version DESC
      """, bindings: [.int64(current.recordId), .int64(floor)]) { row in
      guard row.columns["version"].flatMap(Int64.init) == expected,
        let encoded = row.columns["reverse_delta_json"] else {
        throw RielaMemoryError.sqliteFailed("evolution history has a missing edge")
      }
      let delta = try JSONDecoder().decode(EvolutionReverseDelta.self, from: Data(encoded.utf8))
      bytes = try delta.reconstructPrevious(from: bytes, version: expected)
      onEdge?(expected)
      expected -= 1
      if try !visit(bytes, expected) { completed = false; return false }
      return true
    }
    if completed && expected != floor { throw EvolutionReverseDelta.ValidationError.invalidVersion }
    return (bytes, completed)
  }

  func recordEvolution(previous: MemoryRecord?, next: MemoryRecord, db: OpaquePointer?, forceRevision: Bool = false) throws {
    _ = try historyWrite(previous: previous, next: next, db: db, force: forceRevision)
  }

  public func undoRecord(memoryId: String, recordId: Int64, expectedHeadVersion: Int64) throws -> MemoryHeadMoveResult {
    try moveMemoryHead(memoryId: memoryId, recordId: recordId, expectedRevision: expectedHeadVersion, redo: false)
  }

  public func redoRecord(memoryId: String, recordId: Int64, expectedHeadVersion: Int64) throws -> MemoryHeadMoveResult {
    try moveMemoryHead(memoryId: memoryId, recordId: recordId, expectedRevision: expectedHeadVersion, redo: true)
  }

  private func moveMemoryHead(memoryId: String, recordId: Int64, expectedRevision: Int64, redo: Bool) throws -> MemoryHeadMoveResult {
    let db = try openDatabase(memoryId: memoryId)
    defer { sqlite3_close(db) }
    try ensureSchema(db)
    try execute(db, "BEGIN IMMEDIATE")
    defer { try? execute(db, "ROLLBACK") }
    let current = try record(memoryId: memoryId, recordId: recordId, db: db)
    let engine = try memoryHistoryStore(db: db)
    let moved = try (redo
      ? engine.redo(key: String(recordId), currentHeadValue: memoryHistoryHeadBytes(current), expectedRevision: expectedRevision)
      : engine.undo(key: String(recordId), currentHeadValue: memoryHistoryHeadBytes(current), expectedRevision: expectedRevision))
    let restored = try JSONDecoder().decode(MemoryRecord.self, from: moved.value)
    try verifyEvolutionAttachments(restored.files, db: db, recordMissing: false)
    try validateRelatedRecordIdsExist(restored.relatedRecordIds, db: db)
    try execute(db, """
      UPDATE memory_entries SET tags_json=jsonb(?), related_record_ids_json=jsonb(?), payload_json=jsonb(?) WHERE record_id=?
      """, bindings: [.text(try encodedJSONString(restored.tags)), .text(try encodedJSONString(restored.relatedRecordIds)),
        .text(try encodedJSONString(restored.payload)), .int64(recordId)])
    _ = try replaceFiles(restored.files, recordId: recordId, db: db)
    try execute(db, "COMMIT")
    reclaimHistoryPages(db, freedBytes: 0)
    return MemoryHeadMoveResult(record: restored, revision: moved.revision, headVersion: moved.toVersion, fromVersion: moved.fromVersion)
  }

  public func recordDiff(memoryId: String, recordId: Int64, fromVersion: Int64, toVersion: Int64?) throws -> [VersionedHistoryDiffEntry] {
    let db = try openDatabase(memoryId: memoryId)
    defer { sqlite3_close(db) }
    try ensureSchema(db)
    try execute(db, "BEGIN")
    defer { try? execute(db, "ROLLBACK") }
    let current = try record(memoryId: memoryId, recordId: recordId, db: db)
    let headBytes = try memoryHistoryHeadBytes(current)
    let before: Data
    let after: Data
    if try memoryHistoryExists(recordId: recordId, db: db) {
      let engine = try memoryHistoryStore(db: db)
      let head = try engine.head(key: String(recordId))
      before = try engine.value(key: String(recordId), version: fromVersion, currentHeadValue: headBytes)
      after = try toVersion.map { try engine.value(key: String(recordId), version: $0, currentHeadValue: headBytes) }
        ?? engine.value(key: String(recordId), version: head?.headVersion ?? fromVersion, currentHeadValue: headBytes)
    } else {
      let headVersion = try evolutionHead(recordId: recordId, db: db)
      before = try memoryHistoryHeadBytes(recordVersion(memoryId: memoryId, recordId: recordId, version: fromVersion, db: db))
      after = try memoryHistoryHeadBytes(recordVersion(memoryId: memoryId, recordId: recordId, version: toVersion ?? headVersion, db: db))
    }
    return VersionedHistoryDiff.diff(before: before, after: after)
  }

  public func convertLegacyHistory(memoryId: String, maxRecords: Int) throws -> MemoryHistoryConversionReport {
    guard maxRecords > 0, maxRecords <= 10_000 else { throw RielaMemoryError.invalidLimit(maxRecords) }
    let db = try openDatabase(memoryId: memoryId)
    defer { sqlite3_close(db) }
    try ensureSchema(db)
    try execute(db, "BEGIN IMMEDIATE")
    defer { try? execute(db, "ROLLBACK") }
    let rows = try queryRows(db, sql: """
      SELECT DISTINCT e.record_id FROM memory_evolution e LEFT JOIN memory_history_heads h ON h.key=CAST(e.record_id AS TEXT)
      WHERE h.key IS NULL ORDER BY e.record_id LIMIT ?
      """, bindings: [.int(maxRecords)])
    var converted = 0
    var freedBytes: Int64 = 0
    for row in rows {
      guard let id = row.columns["record_id"].flatMap(Int64.init) else { continue }
      let record = try self.record(memoryId: memoryId, recordId: id, db: db)
      freedBytes += try queryRows(db, sql: "SELECT COALESCE(SUM(length(CAST(reverse_delta_json AS BLOB))),0) AS bytes FROM memory_evolution WHERE record_id=?",
        bindings: [.int64(id)]).first?.columns["bytes"].flatMap(Int64.init) ?? 0
      _ = try historyWrite(previous: record, next: record, db: db)
      converted += 1
    }
    let remaining = try queryRows(db, sql: """
      SELECT COUNT(DISTINCT e.record_id) AS count FROM memory_evolution e LEFT JOIN memory_history_heads h ON h.key=CAST(e.record_id AS TEXT)
      WHERE h.key IS NULL
      """, bindings: []).first?.columns["count"].flatMap(Int.init) ?? 0
    try execute(db, "COMMIT")
    reclaimHistoryPages(db, freedBytes: freedBytes)
    return MemoryHistoryConversionReport(converted: converted, remaining: remaining, freedBytes: freedBytes)
  }
}
