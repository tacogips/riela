import Foundation
import SQLite3

public enum RielaMemoryError: Error, Equatable, Sendable {
  case invalidMemoryId(String)
  case invalidWorkflowId(String)
  case invalidLimit(Int)
  case invalidPattern(String)
  case openFailed(String)
  case sqliteFailed(String)
  case jsonBUnavailable
  case invalidJSON(String)
}

public enum MemorySortOrder: String, Codable, Equatable, Sendable {
  case registeredDesc = "registered-desc"
  case registeredAsc = "registered-asc"
}

public enum MemoryJSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([MemoryJSONValue])
  case object([String: MemoryJSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([MemoryJSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: MemoryJSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case let .bool(value):
      try container.encode(value)
    case let .number(value):
      try container.encode(value)
    case let .string(value):
      try container.encode(value)
    case let .array(value):
      try container.encode(value)
    case let .object(value):
      try container.encode(value)
    }
  }
}

public struct MemoryRecord: Codable, Equatable, Sendable {
  public var recordId: Int64
  public var memoryId: String
  public var workflowId: String
  public var nodeId: String?
  public var registeredAt: String
  public var payload: MemoryJSONValue

  public init(
    recordId: Int64,
    memoryId: String,
    workflowId: String,
    nodeId: String? = nil,
    registeredAt: String,
    payload: MemoryJSONValue
  ) {
    self.recordId = recordId
    self.memoryId = memoryId
    self.workflowId = workflowId
    self.nodeId = nodeId
    self.registeredAt = registeredAt
    self.payload = payload
  }
}

public struct MemoryRecordReference: Codable, Equatable, Sendable {
  public var referenceId: Int64
  public var memoryId: String
  public var recordId: Int64
  public var referencedAt: String

  public init(referenceId: Int64, memoryId: String, recordId: Int64, referencedAt: String) {
    self.referenceId = referenceId
    self.memoryId = memoryId
    self.recordId = recordId
    self.referencedAt = referencedAt
  }
}

public struct MemorySearchOptions: Equatable, Sendable {
  public var workflowId: String
  public var nodeId: String?
  public var matchPatterns: [String]
  public var sortOrder: MemorySortOrder
  public var limit: Int

  public init(
    workflowId: String,
    nodeId: String? = nil,
    matchPatterns: [String] = [],
    sortOrder: MemorySortOrder = .registeredDesc,
    limit: Int = 30
  ) {
    self.workflowId = workflowId
    self.nodeId = nodeId
    self.matchPatterns = matchPatterns
    self.sortOrder = sortOrder
    self.limit = limit
  }
}

public struct RielaMemoryStore: Sendable {
  public var rootDirectory: String

  public init(rootDirectory: String) {
    self.rootDirectory = rootDirectory
  }

  public static func defaultRootDirectory(workingDirectory: String = FileManager.default.currentDirectoryPath) -> String {
    URL(fileURLWithPath: workingDirectory, isDirectory: true)
      .appendingPathComponent(".riela/memory", isDirectory: true)
      .path
  }

  public func databasePath(memoryId: String) throws -> String {
    try validateMemoryId(memoryId)
    return URL(fileURLWithPath: rootDirectory, isDirectory: true)
      .appendingPathComponent("\(memoryId).sqlite")
      .path
  }

  @discardableResult
  public func save(
    memoryId: String,
    workflowId: String,
    nodeId: String? = nil,
    registeredAt: String? = nil,
    payload: MemoryJSONValue
  ) throws -> MemoryRecord {
    try validateMemoryId(memoryId)
    try validateWorkflowId(workflowId)
    let storedRegisteredAt: String
    if let providedRegisteredAt = registeredAt?.trimmingCharacters(in: .whitespacesAndNewlines),
      !providedRegisteredAt.isEmpty {
      storedRegisteredAt = providedRegisteredAt
    } else {
      storedRegisteredAt = currentTimestamp()
    }
    let payloadJSON = try encodedJSONString(payload)

    let db = try openDatabase(memoryId: memoryId)
    defer {
      sqlite3_close(db)
    }
    try ensureSchema(db)
    try execute(
      db,
      """
      INSERT INTO memory_entries (workflow_id, node_id, registered_at, payload_json)
      VALUES (?, ?, ?, jsonb(?))
      """,
      bindings: [.text(workflowId), .optionalText(nodeId), .text(storedRegisteredAt), .text(payloadJSON)]
    )
    let recordId = sqlite3_last_insert_rowid(db)
    return MemoryRecord(
      recordId: recordId,
      memoryId: memoryId,
      workflowId: workflowId,
      nodeId: nodeId,
      registeredAt: storedRegisteredAt,
      payload: payload
    )
  }

  public func load(memoryId: String, workflowId: String, nodeId: String? = nil, limit: Int = 30) throws -> [MemoryRecord] {
    try search(memoryId: memoryId, options: MemorySearchOptions(workflowId: workflowId, nodeId: nodeId, limit: limit))
  }

  public func search(memoryId: String, options: MemorySearchOptions) throws -> [MemoryRecord] {
    try validateMemoryId(memoryId)
    try validateWorkflowId(options.workflowId)
    guard options.limit > 0 else {
      throw RielaMemoryError.invalidLimit(options.limit)
    }
    let regexes = try options.matchPatterns.map(compileRegex)
    let path = try databasePath(memoryId: memoryId)
    guard FileManager.default.fileExists(atPath: path) else {
      return []
    }

    let db = try openDatabase(memoryId: memoryId)
    defer {
      sqlite3_close(db)
    }
    try ensureSchema(db)

    var sql = """
      SELECT record_id, workflow_id, node_id, registered_at, json(payload_json) AS payload_json
      FROM memory_entries
      WHERE workflow_id = ?
      """
    var bindings: [SQLiteBinding] = [.text(options.workflowId)]
    if let nodeId = options.nodeId {
      sql += " AND node_id = ?"
      bindings.append(.text(nodeId))
    }
    sql += options.sortOrder == .registeredAsc
      ? " ORDER BY registered_at ASC, record_id ASC"
      : " ORDER BY registered_at DESC, record_id DESC"
    if regexes.isEmpty {
      sql += " LIMIT ?"
      bindings.append(.int(options.limit))
    }

    var records: [MemoryRecord] = []
    for row in try queryRows(db, sql: sql, bindings: bindings) {
      let record = try memoryRecord(from: row, memoryId: memoryId)
      let fullPayloadRange = NSRange(row.payloadJSON.startIndex..., in: row.payloadJSON)
      guard regexes.isEmpty || regexes.contains(where: { regex in
        regex.firstMatch(in: row.payloadJSON, range: fullPayloadRange) != nil
      }) else {
        continue
      }
      records.append(record)
      if records.count >= options.limit {
        break
      }
    }
    try recordReferences(records, db: db)
    return records
  }

  public func referenceHistory(memoryId: String, recordId: Int64? = nil, limit: Int = 30) throws -> [MemoryRecordReference] {
    try validateMemoryId(memoryId)
    guard limit > 0 else {
      throw RielaMemoryError.invalidLimit(limit)
    }
    let path = try databasePath(memoryId: memoryId)
    guard FileManager.default.fileExists(atPath: path) else {
      return []
    }

    let db = try openDatabase(memoryId: memoryId)
    defer {
      sqlite3_close(db)
    }
    try ensureSchema(db)

    var sql = """
      SELECT reference_id, record_id, referenced_at
      FROM memory_entry_references
      """
    var bindings: [SQLiteBinding] = []
    if let recordId {
      sql += " WHERE record_id = ?"
      bindings.append(.int64(recordId))
    }
    sql += " ORDER BY referenced_at DESC, reference_id DESC LIMIT ?"
    bindings.append(.int(limit))

    return try queryRows(db, sql: sql, bindings: bindings).map { row in
      guard
        let referenceId = Int64(row.columns["reference_id"] ?? ""),
        let rowRecordId = Int64(row.columns["record_id"] ?? ""),
        let referencedAt = row.columns["referenced_at"]
      else {
        throw RielaMemoryError.sqliteFailed("memory reference row is missing required fields")
      }
      return MemoryRecordReference(
        referenceId: referenceId,
        memoryId: memoryId,
        recordId: rowRecordId,
        referencedAt: referencedAt
      )
    }
  }

  private func openDatabase(memoryId: String, readOnly: Bool = false) throws -> OpaquePointer? {
    let path = try databasePath(memoryId: memoryId)
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    if !readOnly {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    var db: OpaquePointer?
    let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
    guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let opened = db else {
      let message = db.map(sqliteErrorMessage) ?? "sqlite open failed"
      if let db {
        sqlite3_close(db)
      }
      throw RielaMemoryError.openFailed(message)
    }
    return opened
  }

  private func ensureSchema(_ db: OpaquePointer?) throws {
    try ensureJSONBAvailable(db)
    try execute(
      db,
      """
      CREATE TABLE IF NOT EXISTS memory_entries (
        record_id INTEGER PRIMARY KEY AUTOINCREMENT,
        workflow_id TEXT NOT NULL,
        node_id TEXT,
        registered_at TEXT NOT NULL,
        payload_json BLOB NOT NULL CHECK (json_valid(payload_json, 8))
      )
      """
    )
    try execute(
      db,
      "CREATE INDEX IF NOT EXISTS idx_memory_entries_workflow_registered ON memory_entries (workflow_id, registered_at DESC, record_id DESC)"
    )
    try execute(
      db,
      "CREATE INDEX IF NOT EXISTS idx_memory_entries_node_registered ON memory_entries (workflow_id, node_id, registered_at DESC, record_id DESC)"
    )
    try execute(
      db,
      """
      CREATE TABLE IF NOT EXISTS memory_entry_references (
        reference_id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_id INTEGER NOT NULL,
        referenced_at TEXT NOT NULL
      )
      """
    )
    try execute(
      db,
      "CREATE INDEX IF NOT EXISTS idx_memory_entry_references_record ON memory_entry_references (record_id, referenced_at DESC, reference_id DESC)"
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

  private func memoryRecord(from row: SQLiteRow, memoryId: String) throws -> MemoryRecord {
    guard
      let recordId = Int64(row.columns["record_id"] ?? ""),
      let workflowId = row.columns["workflow_id"],
      let registeredAt = row.columns["registered_at"]
    else {
      throw RielaMemoryError.sqliteFailed("memory row is missing required fields")
    }
    let payload = try JSONDecoder().decode(MemoryJSONValue.self, from: Data(row.payloadJSON.utf8))
    return MemoryRecord(
      recordId: recordId,
      memoryId: memoryId,
      workflowId: workflowId,
      nodeId: row.columns["node_id"],
      registeredAt: registeredAt,
      payload: payload
    )
  }

  private func validateMemoryId(_ memoryId: String) throws {
    let pattern = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#
    guard memoryId.range(of: pattern, options: .regularExpression) != nil else {
      throw RielaMemoryError.invalidMemoryId(memoryId)
    }
  }

  private func validateWorkflowId(_ workflowId: String) throws {
    let trimmed = workflowId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw RielaMemoryError.invalidWorkflowId(workflowId)
    }
  }

  private func compileRegex(_ pattern: String) throws -> NSRegularExpression {
    do {
      return try NSRegularExpression(pattern: pattern)
    } catch {
      throw RielaMemoryError.invalidPattern(pattern)
    }
  }

  private func recordReferences(_ records: [MemoryRecord], db: OpaquePointer?) throws {
    guard !records.isEmpty else {
      return
    }
    let referencedAt = currentTimestamp()
    for record in records {
      try execute(
        db,
        """
        INSERT INTO memory_entry_references (record_id, referenced_at)
        VALUES (?, ?)
        """,
        bindings: [.int64(record.recordId), .text(referencedAt)]
      )
    }
  }
}

private struct SQLiteRow {
  var columns: [String: String]

  var payloadJSON: String {
    columns["payload_json"] ?? "null"
  }
}

private enum SQLiteBinding {
  case text(String)
  case optionalText(String?)
  case int(Int)
  case int64(Int64)
}

private func execute(_ db: OpaquePointer?, _ sql: String, bindings: [SQLiteBinding] = []) throws {
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

private func queryRows(_ db: OpaquePointer?, sql: String, bindings: [SQLiteBinding]) throws -> [SQLiteRow] {
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
      rows.append(SQLiteRow(columns: row))
      continue
    }
    throw RielaMemoryError.sqliteFailed(sqliteErrorMessage(db))
  }
}

private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer?) throws {
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
    }
    if result != SQLITE_OK {
      throw RielaMemoryError.sqliteFailed("sqlite bind failed at parameter \(index)")
    }
  }
}

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func sqliteErrorMessage(_ db: OpaquePointer?) -> String {
  guard let message = sqlite3_errmsg(db) else {
    return "unknown sqlite error"
  }
  return String(cString: message)
}

private func encodedJSONString(_ value: MemoryJSONValue) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let data = try encoder.encode(value)
  guard let string = String(data: data, encoding: .utf8) else {
    throw RielaMemoryError.invalidJSON("encoded JSON is not UTF-8")
  }
  return string
}

private func currentTimestamp() -> String {
  ISO8601DateFormatter().string(from: Date())
}
