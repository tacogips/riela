import Foundation
import SQLite3

public enum RielaMemoryError: Error, Equatable, Sendable {
  case invalidMemoryId(String)
  case invalidWorkflowId(String)
  case invalidLimit(Int)
  case invalidPattern(String)
  case invalidOffset(Int)
  case tooManyTags(Int)
  case duplicateTag(String)
  case tooManyRelatedRecordIds(Int)
  case duplicateRelatedRecordId(Int64)
  case invalidRelatedRecordId(Int64)
  case missingRelatedRecordId(Int64)
  case missingRecordId(Int64)
  case openFailed(String)
  case sqliteFailed(String)
  case jsonBUnavailable
  case invalidJSON(String)
}

public enum MemoryValueSortOrder: String, Codable, Equatable, Sendable {
  case valueAsc = "value-asc"
  case valueDesc = "value-desc"
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
  public var tags: [String]
  public var relatedRecordIds: [Int64]
  public var payload: MemoryJSONValue

  public init(
    recordId: Int64,
    memoryId: String,
    workflowId: String,
    nodeId: String? = nil,
    registeredAt: String,
    tags: [String] = [],
    relatedRecordIds: [Int64] = [],
    payload: MemoryJSONValue
  ) {
    self.recordId = recordId
    self.memoryId = memoryId
    self.workflowId = workflowId
    self.nodeId = nodeId
    self.registeredAt = registeredAt
    self.tags = tags
    self.relatedRecordIds = relatedRecordIds
    self.payload = payload
  }
}

public struct MemoryMetadata: Codable, Equatable, Sendable {
  public var memoryId: String
  public var description: String?
  public var purpose: String?
  public var dataSchema: MemoryJSONValue?
  public var updatedAt: String

  public init(
    memoryId: String,
    description: String? = nil,
    purpose: String? = nil,
    dataSchema: MemoryJSONValue? = nil,
    updatedAt: String
  ) {
    self.memoryId = memoryId
    self.description = description
    self.purpose = purpose
    self.dataSchema = dataSchema
    self.updatedAt = updatedAt
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
  public static let defaultMaxPayloadBytes = 1_000_000

  public var workflowId: String
  public var includeAllWorkflows: Bool
  public var nodeId: String?
  public var matchPatterns: [String]
  public var tags: [String]
  public var relatedRecordIds: [Int64]
  public var sortOrder: MemorySortOrder
  public var limit: Int
  public var maxPayloadBytes: Int

  public init(
    workflowId: String,
    includeAllWorkflows: Bool = false,
    nodeId: String? = nil,
    matchPatterns: [String] = [],
    tags: [String] = [],
    relatedRecordIds: [Int64] = [],
    sortOrder: MemorySortOrder = .registeredDesc,
    limit: Int = 30,
    maxPayloadBytes: Int = MemorySearchOptions.defaultMaxPayloadBytes
  ) {
    self.workflowId = workflowId
    self.includeAllWorkflows = includeAllWorkflows
    self.nodeId = nodeId
    self.matchPatterns = matchPatterns
    self.tags = tags
    self.relatedRecordIds = relatedRecordIds
    self.sortOrder = sortOrder
    self.limit = limit
    self.maxPayloadBytes = maxPayloadBytes
  }
}

public struct MemoryValueListOptions: Equatable, Sendable {
  public var workflowId: String?
  public var includeAllWorkflows: Bool
  public var sortOrder: MemoryValueSortOrder
  public var limit: Int
  public var offset: Int

  public init(
    workflowId: String? = nil,
    includeAllWorkflows: Bool = false,
    sortOrder: MemoryValueSortOrder = .valueAsc,
    limit: Int = 30,
    offset: Int = 0
  ) {
    self.workflowId = workflowId
    self.includeAllWorkflows = includeAllWorkflows
    self.sortOrder = sortOrder
    self.limit = limit
    self.offset = offset
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
    tags: [String] = [],
    relatedRecordIds: [Int64] = [],
    payload: MemoryJSONValue
  ) throws -> MemoryRecord {
    try validateMemoryId(memoryId)
    try validateWorkflowId(workflowId)
    try validateTags(tags)
    try validateRelatedRecordIds(relatedRecordIds)
    let storedRegisteredAt: String
    if let providedRegisteredAt = registeredAt?.trimmingCharacters(in: .whitespacesAndNewlines),
      !providedRegisteredAt.isEmpty {
      storedRegisteredAt = providedRegisteredAt
    } else {
      storedRegisteredAt = currentTimestamp()
    }
    let payloadJSON = try encodedJSONString(payload)
    let tagsJSON = try encodedJSONString(tags)
    let relatedRecordIdsJSON = try encodedJSONString(relatedRecordIds)

    let db = try openDatabase(memoryId: memoryId)
    defer {
      sqlite3_close(db)
    }
    try ensureSchema(db)
    try validateRelatedRecordIdsExist(relatedRecordIds, db: db)
    try execute(
      db,
      """
      INSERT INTO memory_entries (workflow_id, node_id, registered_at, tags_json, related_record_ids_json, payload_json)
      VALUES (?, ?, ?, jsonb(?), jsonb(?), jsonb(?))
      """,
      bindings: [
        .text(workflowId),
        .optionalText(nodeId),
        .text(storedRegisteredAt),
        .text(tagsJSON),
        .text(relatedRecordIdsJSON),
        .text(payloadJSON)
      ]
    )
    let recordId = sqlite3_last_insert_rowid(db)
    return MemoryRecord(
      recordId: recordId,
      memoryId: memoryId,
      workflowId: workflowId,
      nodeId: nodeId,
      registeredAt: storedRegisteredAt,
      tags: tags,
      relatedRecordIds: relatedRecordIds,
      payload: payload
    )
  }

  @discardableResult
  public func update(
    memoryId: String,
    recordId: Int64,
    workflowId: String? = nil,
    nodeId: String? = nil,
    tags: [String] = [],
    relatedRecordIds: [Int64] = [],
    payload: MemoryJSONValue
  ) throws -> MemoryRecord {
    try validateMemoryId(memoryId)
    guard recordId > 0 else {
      throw RielaMemoryError.missingRecordId(recordId)
    }
    if let workflowId {
      try validateWorkflowId(workflowId)
    }
    try validateTags(tags)
    try validateRelatedRecordIds(relatedRecordIds)
    let payloadJSON = try encodedJSONString(payload)
    let tagsJSON = try encodedJSONString(tags)
    let relatedRecordIdsJSON = try encodedJSONString(relatedRecordIds)

    let db = try openDatabase(memoryId: memoryId)
    defer {
      sqlite3_close(db)
    }
    try ensureSchema(db)
    try validateRelatedRecordIdsExist(relatedRecordIds, db: db)
    var sql = """
      UPDATE memory_entries
      SET tags_json = jsonb(?),
        related_record_ids_json = jsonb(?),
        payload_json = jsonb(?)
      WHERE record_id = ?
      """
    var bindings: [SQLiteBinding] = [
      .text(tagsJSON),
      .text(relatedRecordIdsJSON),
      .text(payloadJSON),
      .int64(recordId)
    ]
    if let workflowId {
      sql += " AND workflow_id = ?"
      bindings.append(.text(workflowId))
    }
    if let nodeId {
      sql += " AND node_id = ?"
      bindings.append(.text(nodeId))
    }
    try execute(db, sql, bindings: bindings)
    guard sqlite3_changes(db) > 0 else {
      throw RielaMemoryError.missingRecordId(recordId)
    }
    return try record(memoryId: memoryId, recordId: recordId, db: db)
  }

  public func registerMetadata(
    memoryId: String,
    description: String? = nil,
    purpose: String? = nil,
    dataSchema: MemoryJSONValue? = nil,
    updatedAt: String? = nil
  ) throws -> MemoryMetadata {
    try validateMemoryId(memoryId)
    let storedUpdatedAt = nonEmpty(updatedAt) ?? currentTimestamp()
    let schemaJSON = try dataSchema.map { try encodedJSONString($0) }

    let db = try openDatabase(memoryId: memoryId)
    defer {
      sqlite3_close(db)
    }
    try ensureSchema(db)
    try execute(
      db,
      """
      INSERT INTO memory_metadata (metadata_id, memory_id, description, purpose, data_schema_json, updated_at)
      VALUES (1, ?, ?, ?, CASE WHEN ? IS NULL THEN NULL ELSE jsonb(?) END, ?)
      ON CONFLICT(metadata_id) DO UPDATE SET
        memory_id = excluded.memory_id,
        description = excluded.description,
        purpose = excluded.purpose,
        data_schema_json = excluded.data_schema_json,
        updated_at = excluded.updated_at
      """,
      bindings: [
        .text(memoryId),
        .optionalText(nonEmpty(description)),
        .optionalText(nonEmpty(purpose)),
        .optionalText(schemaJSON),
        .optionalText(schemaJSON),
        .text(storedUpdatedAt)
      ]
    )
    return MemoryMetadata(
      memoryId: memoryId,
      description: nonEmpty(description),
      purpose: nonEmpty(purpose),
      dataSchema: dataSchema,
      updatedAt: storedUpdatedAt
    )
  }

  public func metadata(memoryId: String) throws -> MemoryMetadata? {
    try validateMemoryId(memoryId)
    let path = try databasePath(memoryId: memoryId)
    guard FileManager.default.fileExists(atPath: path) else {
      return nil
    }

    let db = try openDatabase(memoryId: memoryId)
    defer {
      sqlite3_close(db)
    }
    try ensureSchema(db)
    let rows = try queryRows(
      db,
      sql: """
        SELECT memory_id, description, purpose, json(data_schema_json) AS data_schema_json, updated_at
        FROM memory_metadata
        WHERE metadata_id = 1
        """,
      bindings: []
    )
    guard let row = rows.first else {
      return nil
    }
    guard let storedMemoryId = row.columns["memory_id"], let updatedAt = row.columns["updated_at"] else {
      throw RielaMemoryError.sqliteFailed("memory metadata row is missing required fields")
    }
    let dataSchema = try row.columns["data_schema_json"].map {
      try JSONDecoder().decode(MemoryJSONValue.self, from: Data($0.utf8))
    }
    return MemoryMetadata(
      memoryId: storedMemoryId,
      description: row.columns["description"],
      purpose: row.columns["purpose"],
      dataSchema: dataSchema,
      updatedAt: updatedAt
    )
  }

  public func load(memoryId: String, workflowId: String, nodeId: String? = nil, limit: Int = 30) throws -> [MemoryRecord] {
    try search(memoryId: memoryId, options: MemorySearchOptions(workflowId: workflowId, nodeId: nodeId, limit: limit))
  }

  public func loadAllWorkflows(memoryId: String, workflowId: String, nodeId: String? = nil, limit: Int = 30) throws -> [MemoryRecord] {
    try search(
      memoryId: memoryId,
      options: MemorySearchOptions(workflowId: workflowId, includeAllWorkflows: true, nodeId: nodeId, limit: limit)
    )
  }

  public func search(memoryId: String, options: MemorySearchOptions) throws -> [MemoryRecord] {
    try validateMemoryId(memoryId)
    try validateWorkflowId(options.workflowId)
    guard options.limit > 0 else {
      throw RielaMemoryError.invalidLimit(options.limit)
    }
    guard options.maxPayloadBytes > 0 else {
      throw RielaMemoryError.invalidLimit(options.maxPayloadBytes)
    }
    try validateTags(options.tags)
    try validateRelatedRecordIds(options.relatedRecordIds)
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
      SELECT record_id, workflow_id, node_id, registered_at,
        json(tags_json) AS tags_json,
        json(related_record_ids_json) AS related_record_ids_json,
        json(payload_json) AS payload_json
      FROM memory_entries
      """
    var bindings: [SQLiteBinding] = []
    var whereClauses: [String] = ["length(payload_json) <= ?"]
    bindings.append(.int(options.maxPayloadBytes))
    if !options.includeAllWorkflows {
      whereClauses.append("workflow_id = ?")
      bindings.append(.text(options.workflowId))
    }
    if let nodeId = options.nodeId {
      whereClauses.append("node_id = ?")
      bindings.append(.text(nodeId))
    }
    if !options.tags.isEmpty {
      whereClauses.append(
        "EXISTS (SELECT 1 FROM json_each(json(tags_json)) WHERE json_each.value IN (\(placeholders(options.tags.count))))"
      )
      bindings.append(contentsOf: options.tags.map(SQLiteBinding.text))
    }
    if !options.relatedRecordIds.isEmpty {
      whereClauses.append(
        "EXISTS (SELECT 1 FROM json_each(json(related_record_ids_json)) WHERE json_each.value IN (\(placeholders(options.relatedRecordIds.count))))"
      )
      bindings.append(contentsOf: options.relatedRecordIds.map(SQLiteBinding.int64))
    }
    if !whereClauses.isEmpty {
      sql += " WHERE " + whereClauses.joined(separator: " AND ")
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

  public func uniqueTags(memoryId: String, options: MemoryValueListOptions = MemoryValueListOptions()) throws -> [String] {
    try validateValueList(memoryId: memoryId, options: options)
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
      SELECT DISTINCT json_each.value AS value
      FROM memory_entries, json_each(json(memory_entries.tags_json))
      """
    var bindings: [SQLiteBinding] = []
    appendWorkflowFilter(options, sql: &sql, bindings: &bindings)
    sql += options.sortOrder == .valueDesc ? " ORDER BY value DESC" : " ORDER BY value ASC"
    sql += " LIMIT ? OFFSET ?"
    bindings.append(.int(options.limit))
    bindings.append(.int(options.offset))

    return try queryRows(db, sql: sql, bindings: bindings).compactMap { $0.columns["value"] }
  }

  public func uniqueRelatedRecordIds(
    memoryId: String,
    options: MemoryValueListOptions = MemoryValueListOptions()
  ) throws -> [Int64] {
    try validateValueList(memoryId: memoryId, options: options)
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
      SELECT DISTINCT CAST(json_each.value AS INTEGER) AS value
      FROM memory_entries, json_each(json(memory_entries.related_record_ids_json))
      """
    var bindings: [SQLiteBinding] = []
    appendWorkflowFilter(options, sql: &sql, bindings: &bindings)
    sql += options.sortOrder == .valueDesc ? " ORDER BY value DESC" : " ORDER BY value ASC"
    sql += " LIMIT ? OFFSET ?"
    bindings.append(.int(options.limit))
    bindings.append(.int(options.offset))

    return try queryRows(db, sql: sql, bindings: bindings).compactMap { row in
      row.columns["value"].flatMap(Int64.init)
    }
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
    sqlite3_busy_timeout(opened, 5_000)
    return opened
  }

  private func ensureSchema(_ db: OpaquePointer?) throws {
    try ensureJSONBAvailable(db)
    try execute(db, "BEGIN IMMEDIATE")
    var committed = false
    defer {
      if !committed {
        try? execute(db, "ROLLBACK")
      }
    }
    try execute(
      db,
      """
      CREATE TABLE IF NOT EXISTS memory_metadata (
        metadata_id INTEGER PRIMARY KEY CHECK (metadata_id = 1),
        memory_id TEXT NOT NULL,
        description TEXT,
        purpose TEXT,
        data_schema_json BLOB CHECK (data_schema_json IS NULL OR json_valid(data_schema_json, 8)),
        updated_at TEXT NOT NULL
      )
      """
    )
    try ensureMemoryEntriesSchema(db)
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
    try execute(db, "PRAGMA user_version = \(currentSchemaVersion)")
    try execute(db, "COMMIT")
    committed = true
  }

  private func ensureMemoryEntriesSchema(_ db: OpaquePointer?) throws {
    guard try tableExists("memory_entries", db: db) else {
      try createMemoryEntriesTable(db)
      return
    }
    let columns = try tableColumns("memory_entries", db: db)
    guard !columns.contains("tags_json") || !columns.contains("related_record_ids_json") else {
      return
    }
    try createMemoryEntriesTable(db, tableName: "memory_entries_migration")
    try execute(
      db,
      """
      INSERT INTO memory_entries_migration (
        record_id, workflow_id, node_id, registered_at, tags_json, related_record_ids_json, payload_json
      )
      SELECT record_id, workflow_id, node_id, registered_at, jsonb('[]'), jsonb('[]'), payload_json
      FROM memory_entries
      ORDER BY record_id ASC
      """
    )
    try execute(db, "DROP TABLE memory_entries")
    try execute(db, "ALTER TABLE memory_entries_migration RENAME TO memory_entries")
  }

  private func createMemoryEntriesTable(_ db: OpaquePointer?, tableName: String = "memory_entries") throws {
    try execute(
      db,
      """
      CREATE TABLE IF NOT EXISTS \(tableName) (
        record_id INTEGER PRIMARY KEY AUTOINCREMENT,
        workflow_id TEXT NOT NULL,
        node_id TEXT,
        registered_at TEXT NOT NULL,
        tags_json BLOB NOT NULL CHECK (json_valid(tags_json, 8)),
        related_record_ids_json BLOB NOT NULL CHECK (json_valid(related_record_ids_json, 8)),
        payload_json BLOB NOT NULL CHECK (json_valid(payload_json, 8))
      )
      """
    )
  }

  private func tableExists(_ tableName: String, db: OpaquePointer?) throws -> Bool {
    let rows = try queryRows(
      db,
      sql: "SELECT 1 AS found FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
      bindings: [.text(tableName)]
    )
    return !rows.isEmpty
  }

  private func tableColumns(_ tableName: String, db: OpaquePointer?) throws -> Set<String> {
    let rows = try queryRows(db, sql: "PRAGMA table_info(\(tableName))", bindings: [])
    return Set(rows.compactMap { $0.columns["name"] })
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
    let tags = try JSONDecoder().decode([String].self, from: Data((row.columns["tags_json"] ?? "[]").utf8))
    let relatedRecordIds = try JSONDecoder().decode(
      [Int64].self,
      from: Data((row.columns["related_record_ids_json"] ?? "[]").utf8)
    )
    return MemoryRecord(
      recordId: recordId,
      memoryId: memoryId,
      workflowId: workflowId,
      nodeId: row.columns["node_id"],
      registeredAt: registeredAt,
      tags: tags,
      relatedRecordIds: relatedRecordIds,
      payload: payload
    )
  }

  private func record(memoryId: String, recordId: Int64, db: OpaquePointer?) throws -> MemoryRecord {
    let rows = try queryRows(
      db,
      sql: """
        SELECT record_id, workflow_id, node_id, registered_at,
          json(tags_json) AS tags_json,
          json(related_record_ids_json) AS related_record_ids_json,
          json(payload_json) AS payload_json
        FROM memory_entries
        WHERE record_id = ?
        LIMIT 1
        """,
      bindings: [.int64(recordId)]
    )
    guard let row = rows.first else {
      throw RielaMemoryError.missingRecordId(recordId)
    }
    return try memoryRecord(from: row, memoryId: memoryId)
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

  private func validateTags(_ tags: [String]) throws {
    guard tags.count <= maximumMemoryTags else {
      throw RielaMemoryError.tooManyTags(tags.count)
    }
    var seen: Set<String> = []
    for tag in tags {
      guard !seen.contains(tag) else {
        throw RielaMemoryError.duplicateTag(tag)
      }
      seen.insert(tag)
    }
  }

  private func validateRelatedRecordIds(_ relatedRecordIds: [Int64]) throws {
    guard relatedRecordIds.count <= maximumRelatedRecordIds else {
      throw RielaMemoryError.tooManyRelatedRecordIds(relatedRecordIds.count)
    }
    var seen: Set<Int64> = []
    for relatedRecordId in relatedRecordIds {
      guard relatedRecordId > 0 else {
        throw RielaMemoryError.invalidRelatedRecordId(relatedRecordId)
      }
      guard !seen.contains(relatedRecordId) else {
        throw RielaMemoryError.duplicateRelatedRecordId(relatedRecordId)
      }
      seen.insert(relatedRecordId)
    }
  }

  private func validateRelatedRecordIdsExist(_ relatedRecordIds: [Int64], db: OpaquePointer?) throws {
    for relatedRecordId in relatedRecordIds {
      let rows = try queryRows(
        db,
        sql: "SELECT 1 AS found FROM memory_entries WHERE record_id = ? LIMIT 1",
        bindings: [.int64(relatedRecordId)]
      )
      guard !rows.isEmpty else {
        throw RielaMemoryError.missingRelatedRecordId(relatedRecordId)
      }
    }
  }

  private func validateValueList(memoryId: String, options: MemoryValueListOptions) throws {
    try validateMemoryId(memoryId)
    if let workflowId = options.workflowId, !options.includeAllWorkflows {
      try validateWorkflowId(workflowId)
    }
    guard options.limit > 0 else {
      throw RielaMemoryError.invalidLimit(options.limit)
    }
    guard options.offset >= 0 else {
      throw RielaMemoryError.invalidOffset(options.offset)
    }
  }

  private func appendWorkflowFilter(
    _ options: MemoryValueListOptions,
    sql: inout String,
    bindings: inout [SQLiteBinding]
  ) {
    guard let workflowId = options.workflowId, !options.includeAllWorkflows else {
      return
    }
    sql += " WHERE workflow_id = ?"
    bindings.append(.text(workflowId))
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

private let currentSchemaVersion = 2
private let maximumMemoryTags = 10
private let maximumRelatedRecordIds = 10

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

private func encodedJSONString<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let data = try encoder.encode(value)
  guard let string = String(data: data, encoding: .utf8) else {
    throw RielaMemoryError.invalidJSON("encoded JSON is not UTF-8")
  }
  return string
}

private func placeholders(_ count: Int) -> String {
  Array(repeating: "?", count: count).joined(separator: ", ")
}

private func nonEmpty(_ value: String?) -> String? {
  guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
    return nil
  }
  return trimmed
}

private func currentTimestamp() -> String {
  ISO8601DateFormatter().string(from: Date())
}
