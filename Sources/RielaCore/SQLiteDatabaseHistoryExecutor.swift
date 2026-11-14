import Foundation
import RielaSQLite
import RielaMemory

struct SQLiteDatabaseHistoryExecutor: VersionedHistorySQL {
  let database: SQLiteDatabase

  func execute(_ sql: String, _ values: [VersionedHistorySQLValue]) throws {
    try database.execute(sql, bindings: values.map(sqliteValue))
  }

  func query(_ sql: String, _ values: [VersionedHistorySQLValue]) throws -> [[String: VersionedHistorySQLValue]] {
    try database.query(sql, bindings: values.map(sqliteValue)).map { row in
      var result: [String: VersionedHistorySQLValue] = [:]
      for key in ["key", "revision", "head_version", "retained_generations", "version", "created_at", "content_sha256", "byte_count", "encoding", "anchor_version", "codec", "detached", "blob", "stored_bytes"] {
        if key == "blob", let data = row.data(key) {
          result[key] = .blob(data)
        } else if let value = row[key] {
          if let integer = Int64(value), ["revision", "head_version", "retained_generations", "version", "byte_count", "anchor_version", "detached", "stored_bytes"].contains(key) {
            result[key] = .int(integer)
          } else {
            result[key] = .text(value)
          }
        } else {
          result[key] = .null
        }
      }
      return result
    }
  }

  private func sqliteValue(_ value: VersionedHistorySQLValue) -> SQLiteValue {
    switch value {
    case let .text(value): .text(value)
    case let .int(value): .int(value)
    case let .blob(value): .blob(value)
    case .null: .null
    }
  }
}
