import Foundation
import SQLite3

struct SQLiteRow {
  var columns: [String: String]
  var db: OpaquePointer?

  var payloadJSON: String {
    columns["payload_json"] ?? "null"
  }
}

let currentSchemaVersion = 3

/// One in-place memory-store schema upgrade: brings a database stamped
/// `fromVersion` to `fromVersion + 1`. Append a step here for every future
/// `currentSchemaVersion` bump; memory data is not regenerable, so an older
/// store without a complete migration chain is a hard error.
struct RielaMemorySchemaMigration: Sendable {
  var fromVersion: Int
  var migrate: @Sendable (OpaquePointer?) throws -> Void
}

let memorySchemaMigrations: [RielaMemorySchemaMigration] = []
let maximumMemoryTags = 10
let maximumRelatedRecordIds = 10
let maximumMemoryFiles = 10

enum SQLiteBinding {
  case text(String)
  case optionalText(String?)
  case int(Int)
  case int64(Int64)
  case optionalInt64(Int64?)
}

func execute(_ db: OpaquePointer?, _ sql: String, bindings: [SQLiteBinding] = []) throws {
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
    throw RielaMemoryError.sqliteFailed(sqliteErrorMessage(db))
  }
  defer {
    sqlite3_finalize(statement)
  }
  try bind(bindings, to: statement)
  guard sqlite3_step(statement) == SQLITE_DONE else {
    throw RielaMemoryError.sqliteFailed(sqliteErrorMessage(db))
  }
}

func queryRows(_ db: OpaquePointer?, sql: String, bindings: [SQLiteBinding]) throws -> [SQLiteRow] {
  var rows: [SQLiteRow] = []
  try streamRows(db, sql: sql, bindings: bindings) { row in
    rows.append(row)
    return true
  }
  return rows
}

/// Steps the statement one row at a time and hands each row to `handleRow`,
/// stopping as soon as it returns false. Swift-side filters (regex payload
/// matching) use this so an unbounded scan never materializes the whole table.
func streamRows(
  _ db: OpaquePointer?,
  sql: String,
  bindings: [SQLiteBinding],
  handleRow: (SQLiteRow) throws -> Bool
) throws {
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
    throw RielaMemoryError.sqliteFailed(sqliteErrorMessage(db))
  }
  defer {
    sqlite3_finalize(statement)
  }
  try bind(bindings, to: statement)

  while true {
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE {
      return
    }
    if result == SQLITE_ROW {
      var row: [String: String] = [:]
      for index in 0..<sqlite3_column_count(statement) {
        guard let name = sqlite3_column_name(statement, index) else {
          continue
        }
        if sqlite3_column_type(statement, index) == SQLITE_NULL {
          continue
        }
        if let text = sqlite3_column_text(statement, index) {
          row[String(cString: name)] = String(cString: text)
        }
      }
      if try !handleRow(SQLiteRow(columns: row, db: db)) {
        return
      }
      continue
    }
    throw RielaMemoryError.sqliteFailed(sqliteErrorMessage(db))
  }
}

func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer?) throws {
  for (offset, binding) in bindings.enumerated() {
    let index = Int32(offset + 1)
    let result: Int32
    switch binding {
    case let .text(value):
      result = sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor)
    case let .optionalText(value):
      if let value {
        result = sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor)
      } else {
        result = sqlite3_bind_null(statement, index)
      }
    case let .int(value):
      result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
    case let .int64(value):
      result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
    case let .optionalInt64(value):
      if let value {
        result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
      } else {
        result = sqlite3_bind_null(statement, index)
      }
    }
    if result != SQLITE_OK {
      throw RielaMemoryError.sqliteFailed("sqlite bind failed at parameter \(index)")
    }
  }
}

let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func sqliteErrorMessage(_ db: OpaquePointer?) -> String {
  guard let message = sqlite3_errmsg(db) else {
    return "unknown sqlite error"
  }
  return String(cString: message)
}
