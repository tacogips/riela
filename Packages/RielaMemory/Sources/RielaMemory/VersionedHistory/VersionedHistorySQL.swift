import Foundation
import SQLite3

struct RawSQLiteHistoryExecutor: VersionedHistorySQL {
  let db: OpaquePointer

  func execute(_ sql: String, _ values: [VersionedHistorySQLValue] = []) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure(sql) }
    defer { sqlite3_finalize(statement) }
    try bind(values, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(sql) }
  }

  func query(_ sql: String, _ values: [VersionedHistorySQLValue] = []) throws -> [[String: VersionedHistorySQLValue]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure(sql) }
    defer { sqlite3_finalize(statement) }
    try bind(values, to: statement)
    var rows: [[String: VersionedHistorySQLValue]] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return rows }
      guard result == SQLITE_ROW else { throw failure(sql) }
      var row: [String: VersionedHistorySQLValue] = [:]
      for index in 0..<sqlite3_column_count(statement) {
        guard let rawName = sqlite3_column_name(statement, index) else { continue }
        let name = String(cString: rawName)
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(statement, index))
        case SQLITE_BLOB:
          let size = Int(sqlite3_column_bytes(statement, index))
          row[name] = .blob(size == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, index)!, count: size))
        case SQLITE_TEXT:
          if let text = sqlite3_column_text(statement, index) { row[name] = .text(String(cString: text)) }
        default: row[name] = .null
        }
      }
      rows.append(row)
    }
  }

  private func bind(_ values: [VersionedHistorySQLValue], to statement: OpaquePointer?) throws {
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch value {
      case let .text(text): result = sqlite3_bind_text(statement, index, text, -1, historySQLiteTransientDestructor)
      case let .int(number): result = sqlite3_bind_int64(statement, index, number)
      case let .blob(data):
        result = data.isEmpty ? sqlite3_bind_zeroblob(statement, index, 0) : data.withUnsafeBytes {
          sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), historySQLiteTransientDestructor)
        }
      case .null: result = sqlite3_bind_null(statement, index)
      }
      guard result == SQLITE_OK else { throw failure("sqlite bind parameter \(index)") }
    }
  }

  private func failure(_ context: String) -> VersionedHistoryError {
    .historyCorrupt("\(context): \(String(cString: sqlite3_errmsg(db)))")
  }
}

private let historySQLiteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
