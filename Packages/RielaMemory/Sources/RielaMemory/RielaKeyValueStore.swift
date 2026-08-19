import Foundation
import SQLite3

public struct KeyValueEntry: Codable, Equatable, Sendable {
  public var storeId: String
  public var scope: String
  public var key: String
  public var value: MemoryJSONValue
  public var createdAt: String
  public var updatedAt: String

  public init(
    storeId: String,
    scope: String,
    key: String,
    value: MemoryJSONValue,
    createdAt: String,
    updatedAt: String
  ) {
    self.storeId = storeId
    self.scope = scope
    self.key = key
    self.value = value
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct KeyValueListOptions: Equatable, Sendable {
  public var keyPrefix: String?
  public var limit: Int
  public var offset: Int

  public init(keyPrefix: String? = nil, limit: Int = 100, offset: Int = 0) {
    self.keyPrefix = keyPrefix
    self.limit = limit
    self.offset = offset
  }
}

/// Durable-object-style persistent key-value store: one SQLite database per
/// store id, JSON values addressed by (scope, key). Scopes namespace entries so
/// successive runs of the same workflow share state without colliding with
/// other workflows.
public struct RielaKeyValueStore: Sendable {
  public var rootDirectory: String

  public init(rootDirectory: String) {
    self.rootDirectory = rootDirectory
  }

  public static func defaultRootDirectory(workingDirectory: String = FileManager.default.currentDirectoryPath) -> String {
    URL(fileURLWithPath: workingDirectory, isDirectory: true)
      .appendingPathComponent(".riela/kv", isDirectory: true)
      .path
  }

  public func databasePath(storeId: String) throws -> String {
    try validateStoreId(storeId)
    return URL(fileURLWithPath: rootDirectory, isDirectory: true)
      .appendingPathComponent("\(storeId).sqlite")
      .path
  }

  @discardableResult
  public func set(
    storeId: String,
    scope: String,
    key: String,
    value: MemoryJSONValue,
    updatedAt: String? = nil
  ) throws -> KeyValueEntry {
    try validateStoreId(storeId)
    try validateScope(scope)
    try validateKey(key)
    let timestamp = nonEmpty(updatedAt) ?? currentTimestamp()
    let valueJSON = try encodedJSONString(value)

    let db = try openDatabase(storeId: storeId)
    defer {
      sqlite3_close(db)
    }
    try ensureSchema(db)
    try execute(
      db,
      """
      INSERT INTO kv_entries (scope, key, value_json, created_at, updated_at)
      VALUES (?, ?, jsonb(?), ?, ?)
      ON CONFLICT(scope, key) DO UPDATE SET
        value_json = excluded.value_json,
        updated_at = excluded.updated_at
      """,
      bindings: [
        .text(scope),
        .text(key),
        .text(valueJSON),
        .text(timestamp),
        .text(timestamp)
      ]
    )
    guard let entry = try entry(storeId: storeId, scope: scope, key: key, db: db) else {
      throw RielaMemoryError.sqliteFailed("kv entry missing after upsert")
    }
    return entry
  }

  public func get(storeId: String, scope: String, key: String) throws -> KeyValueEntry? {
    try validateStoreId(storeId)
    try validateScope(scope)
    try validateKey(key)
    guard FileManager.default.fileExists(atPath: try databasePath(storeId: storeId)) else {
      return nil
    }

    let db = try openDatabase(storeId: storeId)
    defer {
      sqlite3_close(db)
    }
    try ensureSchema(db)
    return try entry(storeId: storeId, scope: scope, key: key, db: db)
  }

  @discardableResult
  public func delete(storeId: String, scope: String, key: String) throws -> Bool {
    try validateStoreId(storeId)
    try validateScope(scope)
    try validateKey(key)
    guard FileManager.default.fileExists(atPath: try databasePath(storeId: storeId)) else {
      return false
    }

    let db = try openDatabase(storeId: storeId)
    defer {
      sqlite3_close(db)
    }
    try ensureSchema(db)
    try execute(
      db,
      "DELETE FROM kv_entries WHERE scope = ? AND key = ?",
      bindings: [.text(scope), .text(key)]
    )
    return sqlite3_changes(db) > 0
  }

  public func list(
    storeId: String,
    scope: String,
    options: KeyValueListOptions = KeyValueListOptions()
  ) throws -> [KeyValueEntry] {
    try validateStoreId(storeId)
    try validateScope(scope)
    guard options.limit > 0 else {
      throw RielaMemoryError.invalidLimit(options.limit)
    }
    guard options.offset >= 0 else {
      throw RielaMemoryError.invalidOffset(options.offset)
    }
    guard FileManager.default.fileExists(atPath: try databasePath(storeId: storeId)) else {
      return []
    }

    let db = try openDatabase(storeId: storeId)
    defer {
      sqlite3_close(db)
    }
    try ensureSchema(db)

    var sql = """
      SELECT scope, key, json(value_json) AS value_json, created_at, updated_at
      FROM kv_entries
      WHERE scope = ?
      """
    var bindings: [SQLiteBinding] = [.text(scope)]
    if let keyPrefix = nonEmpty(options.keyPrefix) {
      sql += " AND key >= ? AND key < ?"
      bindings.append(.text(keyPrefix))
      bindings.append(.text(keyPrefix + "\u{10FFFF}"))
    }
    sql += " ORDER BY key ASC LIMIT ? OFFSET ?"
    bindings.append(.int(options.limit))
    bindings.append(.int(options.offset))

    return try queryRows(db, sql: sql, bindings: bindings).map {
      try keyValueEntry(from: $0, storeId: storeId)
    }
  }

  private func entry(storeId: String, scope: String, key: String, db: OpaquePointer?) throws -> KeyValueEntry? {
    let rows = try queryRows(
      db,
      sql: """
        SELECT scope, key, json(value_json) AS value_json, created_at, updated_at
        FROM kv_entries
        WHERE scope = ? AND key = ?
        LIMIT 1
        """,
      bindings: [.text(scope), .text(key)]
    )
    return try rows.first.map { try keyValueEntry(from: $0, storeId: storeId) }
  }

  private func keyValueEntry(from row: SQLiteRow, storeId: String) throws -> KeyValueEntry {
    guard
      let scope = row.columns["scope"],
      let key = row.columns["key"],
      let createdAt = row.columns["created_at"],
      let updatedAt = row.columns["updated_at"]
    else {
      throw RielaMemoryError.sqliteFailed("kv row is missing required fields")
    }
    let value = try JSONDecoder().decode(MemoryJSONValue.self, from: Data((row.columns["value_json"] ?? "null").utf8))
    return KeyValueEntry(
      storeId: storeId,
      scope: scope,
      key: key,
      value: value,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }

  private func openDatabase(storeId: String) throws -> OpaquePointer? {
    let path = try databasePath(storeId: storeId)
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard
      sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
      let opened = db
    else {
      let message = db.map(sqliteErrorMessage) ?? "sqlite open failed"
      if let db {
        sqlite3_close(db)
      }
      throw RielaMemoryError.openFailed(message)
    }
    sqlite3_busy_timeout(opened, 5_000)
    return opened
  }

  private func ensureSchema(_ db: OpaquePointer?) throws {
    try ensureJSONBAvailable(db)
    try execute(
      db,
      """
      CREATE TABLE IF NOT EXISTS kv_entries (
        scope TEXT NOT NULL,
        key TEXT NOT NULL,
        value_json BLOB NOT NULL CHECK (json_valid(value_json, 8)),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (scope, key)
      )
      """
    )
  }

  private func ensureJSONBAvailable(_ db: OpaquePointer?) throws {
    let rows = try queryRows(
      db,
      sql: "SELECT typeof(jsonb('{}')) AS storage_type, json_valid(jsonb('{}'), 8) AS valid_jsonb",
      bindings: []
    )
    guard rows.first?.columns["storage_type"] == "blob", rows.first?.columns["valid_jsonb"] == "1" else {
      throw RielaMemoryError.jsonBUnavailable
    }
  }

  private func validateStoreId(_ storeId: String) throws {
    let pattern = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#
    guard storeId.range(of: pattern, options: .regularExpression) != nil else {
      throw RielaMemoryError.invalidStoreId(storeId)
    }
  }

  private func validateScope(_ scope: String) throws {
    let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed == scope, scope.utf8.count <= 512 else {
      throw RielaMemoryError.invalidStoreScope(scope)
    }
  }

  private func validateKey(_ key: String) throws {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed == key, key.utf8.count <= 1024 else {
      throw RielaMemoryError.invalidStoreKey(key)
    }
  }
}
