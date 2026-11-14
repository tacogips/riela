import Foundation
import SQLite3

public enum SQLiteOpenMode: Sendable {
  case readOnly
  case readWriteCreate
}

public struct SQLiteOpenOptions: Sendable {
  public var enableWAL: Bool
  public var busyTimeoutMilliseconds: Int32?
  public var requireJSONB: Bool

  public init(
    enableWAL: Bool = true,
    busyTimeoutMilliseconds: Int32? = 3_000,
    requireJSONB: Bool = true
  ) {
    self.enableWAL = enableWAL
    self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
    self.requireJSONB = requireJSONB
  }

  public static let writableDefault = SQLiteOpenOptions()
  public static let readOnlyDefault = SQLiteOpenOptions(enableWAL: false)
}

public enum SQLiteErrorOperation: String, Sendable {
  case open
  case execute
  case query
  case bind
  case jsonBUnavailable
}

public struct SQLiteError: Error, Equatable, Sendable {
  public var operation: SQLiteErrorOperation
  public var code: Int32?
  public var message: String
  public var sql: String?

  public init(operation: SQLiteErrorOperation, code: Int32?, message: String, sql: String? = nil) {
    self.operation = operation
    self.code = code
    self.message = message
    self.sql = sql
  }
}

public enum SQLiteValue: Sendable {
  case text(String)
  case int(Int64)
  case double(Double)
  case null

  public static func optionalText(_ value: String?) -> SQLiteValue {
    value.map(SQLiteValue.text) ?? .null
  }

  public static func optionalInt(_ value: Int?) -> SQLiteValue {
    value.map { .int(Int64($0)) } ?? .null
  }

  public static func optionalDouble(_ value: Double?) -> SQLiteValue {
    value.map(SQLiteValue.double) ?? .null
  }
}

public struct SQLiteRow: Equatable, Sendable {
  private var values: [String: String?]

  public init(values: [String: String?]) {
    self.values = values
  }

  public subscript(_ column: String) -> String? {
    values[column] ?? nil
  }

  public func string(_ column: String, nullValue: String = "") -> String {
    self[column] ?? nullValue
  }
}

public final class SQLiteDatabase: @unchecked Sendable {
  public let path: String?
  private let handle: OpaquePointer?
  private let ownsHandle: Bool

  private init(path: String?, handle: OpaquePointer?, ownsHandle: Bool) {
    self.path = path
    self.handle = handle
    self.ownsHandle = ownsHandle
  }

  deinit {
    if ownsHandle {
      sqlite3_close(handle)
    }
  }

  public static func open(
    path: String,
    mode: SQLiteOpenMode = .readWriteCreate,
    options: SQLiteOpenOptions = .writableDefault
  ) throws -> SQLiteDatabase {
    if case .readWriteCreate = mode {
      let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    var db: OpaquePointer?
    let flags: Int32
    switch mode {
    case .readOnly:
      flags = SQLITE_OPEN_READONLY
    case .readWriteCreate:
      flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
    }
    guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let opened = db else {
      let message = db.map(errorMessage) ?? "sqlite open failed"
      let code = db.map(sqlite3_errcode)
      if let db {
        sqlite3_close(db)
      }
      throw SQLiteError(
        operation: .open,
        code: code,
        message: "failed to open sqlite database at \(path): \(message)"
      )
    }
    let database = SQLiteDatabase(path: path, handle: opened, ownsHandle: true)
    try database.configure(options)
    return database
  }

  public static func borrowing(_ handle: OpaquePointer?, path: String? = nil) -> SQLiteDatabase {
    SQLiteDatabase(path: path, handle: handle, ownsHandle: false)
  }

  public func transaction<T>(
    begin: String = "BEGIN IMMEDIATE",
    _ body: (SQLiteDatabase) throws -> T
  ) throws -> T {
    try execute(begin)
    do {
      let value = try body(self)
      try execute("COMMIT")
      return value
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  public func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw sqliteError(operation: .execute, sql: sql)
    }
    defer {
      sqlite3_finalize(statement)
    }
    try bind(bindings, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw sqliteError(operation: .execute, sql: sql)
    }
  }

  public func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw sqliteError(operation: .query, sql: sql)
    }
    defer {
      sqlite3_finalize(statement)
    }
    try bind(bindings, to: statement)

    var rows: [SQLiteRow] = []
    while true {
      let result = sqlite3_step(statement)
      switch result {
      case SQLITE_ROW:
        rows.append(row(from: statement))
      case SQLITE_DONE:
        return rows
      default:
        throw sqliteError(operation: .query, sql: sql)
      }
    }
  }

  public func requireJSONBAvailable() throws {
    let rows = try query("SELECT typeof(jsonb('{}')) AS storage_type, json_valid(jsonb('{}'), 8) AS valid_jsonb")
    guard rows.first?["storage_type"] == "blob", rows.first?["valid_jsonb"] == "1" else {
      throw SQLiteError(
        operation: .jsonBUnavailable,
        code: nil,
        message: "sqlite JSONB support is unavailable"
      )
    }
  }

  public func tableExists(_ name: String) throws -> Bool {
    let rows = try query(
      "SELECT 1 AS present FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
      bindings: [.text(name)]
    )
    return rows.first?["present"] != nil
  }

  public func tableColumnNames(_ tableName: String) throws -> Set<String> {
    let rows = try query("PRAGMA table_info(\(tableName))")
    return Set(rows.compactMap { $0["name"] })
  }

  private func configure(_ options: SQLiteOpenOptions) throws {
    if let busyTimeoutMilliseconds = options.busyTimeoutMilliseconds {
      sqlite3_busy_timeout(handle, busyTimeoutMilliseconds)
    }
    if options.enableWAL {
      _ = try query("PRAGMA journal_mode=WAL")
    }
    if options.requireJSONB {
      try requireJSONBAvailable()
    }
  }

  private func bind(_ bindings: [SQLiteValue], to statement: OpaquePointer?) throws {
    for (offset, binding) in bindings.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch binding {
      case let .text(value):
        result = sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor)
      case let .int(value):
        result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
      case let .double(value):
        result = sqlite3_bind_double(statement, index, value)
      case .null:
        result = sqlite3_bind_null(statement, index)
      }
      guard result == SQLITE_OK else {
        throw SQLiteError(
          operation: .bind,
          code: result,
          message: "sqlite bind failed at parameter \(index)"
        )
      }
    }
  }

  private func row(from statement: OpaquePointer?) -> SQLiteRow {
    var values: [String: String?] = [:]
    for index in 0..<sqlite3_column_count(statement) {
      guard let name = sqlite3_column_name(statement, index) else {
        continue
      }
      let key = String(cString: name)
      if sqlite3_column_type(statement, index) == SQLITE_NULL {
        values[key] = nil
      } else if let text = sqlite3_column_text(statement, index) {
        values[key] = String(cString: text)
      } else {
        values[key] = nil
      }
    }
    return SQLiteRow(values: values)
  }

  private func sqliteError(operation: SQLiteErrorOperation, sql: String?) -> SQLiteError {
    SQLiteError(
      operation: operation,
      code: sqlite3_errcode(handle),
      message: Self.errorMessage(handle),
      sql: sql
    )
  }

  private static func errorMessage(_ handle: OpaquePointer?) -> String {
    guard let message = sqlite3_errmsg(handle) else {
      return "unknown sqlite error"
    }
    return String(cString: message)
  }
}

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
