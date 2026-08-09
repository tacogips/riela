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
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
    throw RielaMemoryError.sqliteFailed(sqliteErrorMessage(db))
  }
  defer {
    sqlite3_finalize(statement)
  }
  try bind(bindings, to: statement)

  var rows: [SQLiteRow] = []
  while true {
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE {
      return rows
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
      rows.append(SQLiteRow(columns: row, db: db))
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
