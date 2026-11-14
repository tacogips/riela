import Foundation
import SQLite3

private struct MemoryLegacyHistoryVersion {
  let version: Int64
  let createdAt: String
  let value: Data
}

func ensureMemoryHistorySchema(_ db: OpaquePointer?) throws {
  guard let db else { throw RielaMemoryError.sqliteFailed("missing memory database") }
  try VersionedHistoryStore(tablePrefix: "memory", headStorage: .external, sql: RawSQLiteHistoryExecutor(db: db)).ensureSchema()
}

public struct MemoryHeadMoveResult: Codable, Equatable, Sendable {
  public let record: MemoryRecord
  public let revision: Int64
  public let headVersion: Int64
  public let fromVersion: Int64
}

public struct MemoryHistoryConversionReport: Codable, Equatable, Sendable {
  public let converted: Int
  public let remaining: Int
  public let freedBytes: Int64
}

extension RielaMemoryStore {
  public static let memoryDefaultHistoryRetention = 2

  func memoryHistoryStore(db: OpaquePointer?) throws -> VersionedHistoryStore {
    guard let db else { throw RielaMemoryError.sqliteFailed("missing memory database") }
    return VersionedHistoryStore(tablePrefix: "memory", headStorage: .external, sql: RawSQLiteHistoryExecutor(db: db))
  }

  func memoryHistoryPins(recordId: Int64, db: OpaquePointer?) throws -> Set<Int64> {
    let now = snapshotRetentionNow()
    let rows = try queryRows(db, sql: "SELECT version FROM memory_snapshot_retention WHERE record_id=? AND expires_at>?",
      bindings: [.int64(recordId), .int64(now)])
    return Set(rows.compactMap { $0.columns["version"].flatMap(Int64.init) })
  }

  func memoryHistoryHeadBytes(_ record: MemoryRecord) throws -> Data {
    Data(try encodedJSONString(record).utf8)
  }

  func memoryHistoryExists(recordId: Int64, db: OpaquePointer?) throws -> Bool {
    try !queryRows(db, sql: "SELECT 1 FROM memory_history_heads WHERE key=?", bindings: [.text(String(recordId))]).isEmpty
  }

  @discardableResult
  func historyWrite(previous: MemoryRecord?, next: MemoryRecord, db: OpaquePointer?, force: Bool = false,
                    historyRetention: Int? = nil) throws -> VersionedHistoryWriteResult {
    if let historyRetention, !(1...1_000).contains(historyRetention) {
      throw RielaMemoryError.invalidHistoryRetention(historyRetention)
    }
    if let previous { try verifyEvolutionAttachments(previous.files, db: db, recordMissing: true) }
    try verifyEvolutionAttachments(next.files, db: db, recordMissing: true)
    let store = try memoryHistoryStore(db: db)
    let key = String(next.recordId)
    let newBytes = try memoryHistoryHeadBytes(next)
    var oldBytes = try previous.map(memoryHistoryHeadBytes)
    if try !memoryHistoryExists(recordId: next.recordId, db: db) {
      let legacyHead = try queryRows(db, sql: "SELECT MAX(version) AS version FROM memory_evolution WHERE record_id=?",
        bindings: [.int64(next.recordId)]).first?.columns["version"].flatMap(Int64.init)
      if let legacyHead, let previous {
        let legacyFloor = try queryRows(db, sql: "SELECT retained_floor FROM memory_retirement WHERE record_id=?",
          bindings: [.int64(next.recordId)]).first?.columns["retained_floor"].flatMap(Int64.init) ?? 1
        let retention = historyRetention ?? Self.memoryDefaultHistoryRetention
        let windowFloor = legacyHead - Int64(max(retention - 1, 0))
        let pins = try memoryHistoryPins(recordId: next.recordId, db: db)
        let floor = max(legacyFloor, min(windowFloor, pins.min() ?? windowFloor))
        var prior: [MemoryLegacyHistoryVersion] = []
        _ = try walkReverseChain(current: previous, head: legacyHead, floor: floor, db: db) { bytes, version in
          let timestamp = try queryRows(db, sql: "SELECT recorded_at FROM memory_evolution WHERE record_id=? AND version=?",
            bindings: [.int64(next.recordId), .int64(version)]).first?.columns["recorded_at"] ?? currentTimestamp()
          prior.append(MemoryLegacyHistoryVersion(version: version, createdAt: timestamp, value: bytes))
          return true
        }
        try store.importChain(key: key, revision: legacyHead, headVersion: legacyHead,
          headValue: oldBytes ?? Data(), previous: prior.map { ($0.version, $0.createdAt, $0.value) })
        try execute(db, "DELETE FROM memory_evolution WHERE record_id=?", bindings: [.int64(next.recordId)])
        try execute(db, "DELETE FROM memory_retirement WHERE record_id=?", bindings: [.int64(next.recordId)])
      } else if legacyHead == nil {
        oldBytes = nil
      }
    }
    let result = try store.write(key: key, value: newBytes, currentHeadValue: oldBytes, expectedRevision: nil,
      force: force, retainedGenerations: historyRetention, defaultRetainedGenerations: Self.memoryDefaultHistoryRetention,
      pins: try memoryHistoryPins(recordId: next.recordId, db: db))
    if result.outcome == .unchanged, let historyRetention {
      _ = try store.applyRetention(key: key, currentHeadValue: oldBytes, retainedGenerations: historyRetention,
        pins: try memoryHistoryPins(recordId: next.recordId, db: db))
    }
    return result
  }

  func retainedHeadVersion(recordId: Int64, db: OpaquePointer?) throws -> Int64? {
    try memoryHistoryStore(db: db).head(key: String(recordId))?.headVersion
  }

  func reclaimHistoryPages(_ db: OpaquePointer?, freedBytes: Int64) {
    guard freedBytes > 0,
      (try? queryRows(db, sql: "PRAGMA auto_vacuum", bindings: []).first?.columns["auto_vacuum"]) == "2" else { return }
    let pageSize = (try? queryRows(db, sql: "PRAGMA page_size", bindings: []).first?.columns["page_size"].flatMap(Int64.init)) ?? 0
    guard pageSize > 0 else { return }
    let pages = min(max(freedBytes / pageSize, 1), 4_096)
    _ = try? queryRows(db, sql: "PRAGMA incremental_vacuum(\(pages))", bindings: [])
  }
}
