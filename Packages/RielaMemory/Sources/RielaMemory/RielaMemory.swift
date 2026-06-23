import Foundation
import SQLite3

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
    files: [MemoryFileReference] = [],
    payload: MemoryJSONValue
  ) throws -> MemoryRecord {
    try validateMemoryId(memoryId)
    try validateWorkflowId(workflowId)
    try validateTags(tags)
    try validateRelatedRecordIds(relatedRecordIds)
    try validateFiles(files)
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
    var copiedPaths: [String] = []
    try execute(db, "BEGIN IMMEDIATE")
    var committed = false
    defer {
      if !committed {
        try? execute(db, "ROLLBACK")
        removeCopiedFiles(copiedPaths)
      }
    }
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
    let storedFiles = try storeFiles(files, memoryId: memoryId, recordId: recordId, copiedPaths: &copiedPaths)
    _ = try replaceFiles(storedFiles, recordId: recordId, db: db)
    try execute(db, "COMMIT")
    committed = true
    return MemoryRecord(
      recordId: recordId,
      memoryId: memoryId,
      workflowId: workflowId,
      nodeId: nodeId,
      registeredAt: storedRegisteredAt,
      tags: tags,
      relatedRecordIds: relatedRecordIds,
      files: storedFiles,
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
    files: [MemoryFileReference]? = nil,
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
    try validateFiles(files)
    let payloadJSON = try encodedJSONString(payload)
    let tagsJSON = try encodedJSONString(tags)
    let relatedRecordIdsJSON = try encodedJSONString(relatedRecordIds)

    let db = try openDatabase(memoryId: memoryId)
    defer {
      sqlite3_close(db)
    }
    try ensureSchema(db)
    var copiedPaths: [String] = []
    var replacedFilePaths: [String] = []
    try execute(db, "BEGIN IMMEDIATE")
    var committed = false
    defer {
      if !committed {
        try? execute(db, "ROLLBACK")
        removeCopiedFiles(copiedPaths)
      }
    }
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
    if let files {
      let storedFiles = try storeFiles(files, memoryId: memoryId, recordId: recordId, copiedPaths: &copiedPaths)
      replacedFilePaths = try replaceFiles(storedFiles, recordId: recordId, db: db)
    }
    try execute(db, "COMMIT")
    committed = true
    removeStoredFiles(replacedFilePaths)
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
    try execute(
      db,
      """
      CREATE TABLE IF NOT EXISTS memory_files (
        file_id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_id INTEGER NOT NULL,
        path TEXT NOT NULL,
        media_type TEXT,
        kind TEXT,
        name TEXT,
        size_bytes INTEGER,
        created_at TEXT NOT NULL
      )
      """
    )
    try execute(
      db,
      "CREATE INDEX IF NOT EXISTS idx_memory_files_record ON memory_files (record_id, file_id ASC)"
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
      files: try memoryFiles(recordId: recordId, db: row.db),
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

  private func validateFiles(_ files: [MemoryFileReference]?) throws {
    guard let files else {
      return
    }
    guard files.count <= maximumMemoryFiles else {
      throw RielaMemoryError.tooManyFiles(files.count)
    }
    var seen: Set<String> = []
    for file in files {
      let path = normalizedSourceFilePath(file.path)
      guard !path.isEmpty else {
        throw RielaMemoryError.invalidFilePath(file.path)
      }
      guard !seen.contains(path) else {
        throw RielaMemoryError.duplicateFilePath(path)
      }
      seen.insert(path)
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

  private func storeFiles(
    _ files: [MemoryFileReference],
    memoryId: String,
    recordId: Int64,
    copiedPaths: inout [String]
  ) throws -> [MemoryFileReference] {
    guard !files.isEmpty else {
      return []
    }
    let destinationDirectory = URL(fileURLWithPath: rootDirectory, isDirectory: true)
      .appendingPathComponent("files", isDirectory: true)
      .appendingPathComponent(memoryId, isDirectory: true)
      .appendingPathComponent(String(recordId), isDirectory: true)
    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    return try files.enumerated().map { index, file in
      let sourceURL = URL(fileURLWithPath: normalizedSourceFilePath(file.path))
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
        throw RielaMemoryError.invalidFilePath(file.path)
      }
      let destinationURL = uniqueDestinationURL(
        in: destinationDirectory,
        sourceURL: sourceURL,
        index: index,
        preferredName: file.name
      )
      try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
      copiedPaths.append(destinationURL.path)
      let storedMediaType = normalizedMediaType(file.mediaType) ?? inferredMediaType(path: destinationURL.path)
      return MemoryFileReference(
        path: destinationURL.path,
        mediaType: storedMediaType,
        kind: normalizedFileKind(provided: file.kind, mediaType: storedMediaType, path: destinationURL.path),
        name: nonEmpty(file.name) ?? sourceURL.lastPathComponent,
        sizeBytes: file.sizeBytes ?? fileSize(path: destinationURL.path)
      )
    }
  }

  private func replaceFiles(_ files: [MemoryFileReference], recordId: Int64, db: OpaquePointer?) throws -> [String] {
    let oldPaths = try memoryFiles(recordId: recordId, db: db).map(\.path)
    try execute(db, "DELETE FROM memory_files WHERE record_id = ?", bindings: [.int64(recordId)])
    let createdAt = currentTimestamp()
    for file in files {
      try execute(
        db,
        """
        INSERT INTO memory_files (record_id, path, media_type, kind, name, size_bytes, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        bindings: [
          .int64(recordId),
          .text(file.path),
          .optionalText(nonEmpty(file.mediaType)),
          .optionalText(nonEmpty(file.kind)),
          .optionalText(nonEmpty(file.name)),
          .optionalInt64(file.sizeBytes),
          .text(createdAt)
        ]
      )
    }
    let newPaths = Set(files.map(\.path))
    return oldPaths.filter { !newPaths.contains($0) }
  }

  private func memoryFiles(recordId: Int64, db: OpaquePointer?) throws -> [MemoryFileReference] {
    try queryRows(
      db,
      sql: """
        SELECT path, media_type, kind, name, size_bytes
        FROM memory_files
        WHERE record_id = ?
        ORDER BY file_id ASC
        """,
      bindings: [.int64(recordId)]
    ).map { row in
      MemoryFileReference(
        path: row.columns["path"] ?? "",
        mediaType: row.columns["media_type"],
        kind: row.columns["kind"],
        name: row.columns["name"],
        sizeBytes: row.columns["size_bytes"].flatMap(Int64.init)
      )
    }
  }
}
