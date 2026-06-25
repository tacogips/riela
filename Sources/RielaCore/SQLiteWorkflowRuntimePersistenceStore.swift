import Foundation
import SQLite3

public struct SQLiteWorkflowRuntimePersistenceStore: Sendable {
  public var rootDirectory: String

  public init(rootDirectory: String) {
    self.rootDirectory = rootDirectory
  }

  public static func defaultDatabasePath(rootDirectory: String) -> String {
    SQLiteWorkflowMessageLog.defaultDatabasePath(rootDirectory: rootDirectory)
  }

  public func save(_ snapshot: WorkflowRuntimePersistenceSnapshot) throws {
    guard isSafeId(snapshot.session.sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(snapshot.session.sessionId)
    }
    let db = try openDatabase()
    defer {
      sqlite3_close(db)
    }
    try ensureSchema(db)
    try execute(db, "BEGIN IMMEDIATE")
    do {
      try save(snapshot, in: db)
      try execute(db, "COMMIT")
    } catch {
      try? execute(db, "ROLLBACK")
      throw error
    }
  }

  public func save(_ snapshot: WorkflowRuntimePersistenceSnapshot, in db: OpaquePointer?) throws {
    guard isSafeId(snapshot.session.sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(snapshot.session.sessionId)
    }
    try ensureSchema(db)
    try upsertSnapshot(db, snapshot)
    try SQLiteWorkflowMessageLog(databasePath: Self.defaultDatabasePath(rootDirectory: rootDirectory))
      .replaceMessages(for: snapshot.session.sessionId, with: snapshot.workflowMessages, in: db)
  }

  public func load(sessionId: String) throws -> WorkflowRuntimePersistenceSnapshot {
    guard isSafeId(sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(sessionId)
    }
    let db = try openDatabase(readOnly: true)
    defer {
      sqlite3_close(db)
    }
    let loopEvidenceSelect = try loopEvidenceSelectExpression(db)
    let rows = try queryRows(
      db,
      sql: """
        SELECT json(session_json) AS session_json,
          CASE WHEN root_output_json IS NULL THEN NULL ELSE json(root_output_json) END AS root_output_json,
          json(diagnostics_json) AS diagnostics_json,
          \(loopEvidenceSelect)
        FROM workflow_runtime_snapshots
        WHERE workflow_execution_id = ?
        LIMIT 1
        """,
      bindings: [.text(sessionId)]
    )
    guard let row = rows.first else {
      throw WorkflowRuntimePersistenceStoreError.notFound("runtime snapshot not found: \(sessionId)")
    }
    return try snapshot(from: row)
  }

  public func loadAll() throws -> [WorkflowRuntimePersistenceSnapshot] {
    guard FileManager.default.fileExists(atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)) else {
      return []
    }
    let db = try openDatabase(readOnly: true)
    defer {
      sqlite3_close(db)
    }
    let loopEvidenceSelect = try loopEvidenceSelectExpression(db)
    return try queryRows(
      db,
      sql: """
        SELECT json(session_json) AS session_json,
          CASE WHEN root_output_json IS NULL THEN NULL ELSE json(root_output_json) END AS root_output_json,
          json(diagnostics_json) AS diagnostics_json,
          \(loopEvidenceSelect)
        FROM workflow_runtime_snapshots
        ORDER BY updated_at DESC, workflow_execution_id
        """,
      bindings: []
    ).map(snapshot(from:))
  }

  private func openDatabase(readOnly: Bool = false) throws -> OpaquePointer? {
    let databasePath = Self.defaultDatabasePath(rootDirectory: rootDirectory)
    let directory = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
    if !readOnly {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    var db: OpaquePointer?
    let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
    guard sqlite3_open_v2(databasePath, &db, flags, nil) == SQLITE_OK, let opened = db else {
      let message = db.map(sqliteErrorMessage) ?? "sqlite open failed"
      if let db {
        sqlite3_close(db)
      }
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed(message)
    }
    return opened
  }

  private func ensureSchema(_ db: OpaquePointer?) throws {
    try ensureJSONBAvailable(db)
    try execute(
      db,
      """
      CREATE TABLE IF NOT EXISTS workflow_runtime_snapshots (
        workflow_execution_id TEXT PRIMARY KEY,
        session_json BLOB NOT NULL CHECK (json_valid(session_json, 8)),
        root_output_json BLOB CHECK (root_output_json IS NULL OR json_valid(root_output_json, 8)),
        diagnostics_json BLOB NOT NULL CHECK (json_valid(diagnostics_json, 8)),
        loop_evidence_json BLOB CHECK (loop_evidence_json IS NULL OR json_valid(loop_evidence_json, 8)),
        updated_at TEXT NOT NULL
      )
      """
    )
    if try !tableColumnNames(db, tableName: "workflow_runtime_snapshots").contains("loop_evidence_json") {
      try execute(
        db,
        """
        ALTER TABLE workflow_runtime_snapshots
        ADD COLUMN loop_evidence_json BLOB CHECK (loop_evidence_json IS NULL OR json_valid(loop_evidence_json, 8))
        """
      )
    }
    try execute(db, "CREATE INDEX IF NOT EXISTS idx_workflow_runtime_snapshots_updated ON workflow_runtime_snapshots (updated_at DESC, workflow_execution_id)")
  }

  private func upsertSnapshot(_ db: OpaquePointer?, _ snapshot: WorkflowRuntimePersistenceSnapshot) throws {
    try execute(
      db,
      """
      INSERT INTO workflow_runtime_snapshots (
        workflow_execution_id, session_json, root_output_json, diagnostics_json, loop_evidence_json, updated_at
      ) VALUES (?, jsonb(?), CASE WHEN ? IS NULL THEN NULL ELSE jsonb(?) END, jsonb(?),
        CASE WHEN ? IS NULL THEN NULL ELSE jsonb(?) END, ?)
      ON CONFLICT(workflow_execution_id) DO UPDATE SET
        session_json = excluded.session_json,
        root_output_json = excluded.root_output_json,
        diagnostics_json = excluded.diagnostics_json,
        loop_evidence_json = excluded.loop_evidence_json,
        updated_at = excluded.updated_at
      """,
      bindings: [
        .text(snapshot.session.sessionId),
        .text(try jsonString(snapshot.session)),
        .nullableText(try snapshot.rootOutput.map(jsonString)),
        .nullableText(try snapshot.rootOutput.map(jsonString)),
        .text(try jsonString(snapshot.diagnostics)),
        .nullableText(try snapshot.loopEvidence.map(jsonString)),
        .nullableText(try snapshot.loopEvidence.map(jsonString)),
        .text(Self.dateString(snapshot.session.updatedAt))
      ]
    )
  }

  private func snapshot(from row: [String: String?]) throws -> WorkflowRuntimePersistenceSnapshot {
    guard let sessionText = row["session_json"] ?? nil,
          let diagnosticsText = row["diagnostics_json"] ?? nil,
          let sessionData = sessionText.data(using: .utf8),
          let diagnosticsData = diagnosticsText.data(using: .utf8) else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("runtime snapshot row is missing required fields")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let session = try decoder.decode(WorkflowSession.self, from: sessionData)
    let diagnostics = try decoder.decode([String].self, from: diagnosticsData)
    let rootOutput: JSONObject?
    if let rootOutputText = row["root_output_json"] ?? nil, let data = rootOutputText.data(using: .utf8) {
      rootOutput = try decoder.decode(JSONObject.self, from: data)
    } else {
      rootOutput = nil
    }
    let loopEvidence: LoopEvidenceManifest?
    if let loopEvidenceText = row["loop_evidence_json"] ?? nil, let data = loopEvidenceText.data(using: .utf8) {
      loopEvidence = try decoder.decode(LoopEvidenceManifest.self, from: data)
    } else {
      loopEvidence = nil
    }
    let messages = try SQLiteWorkflowMessageLog(databasePath: Self.defaultDatabasePath(rootDirectory: rootDirectory))
      .listMessages(workflowExecutionId: session.sessionId)
    return WorkflowRuntimePersistenceSnapshot(
      session: session,
      workflowMessages: messages,
      rootOutput: rootOutput,
      diagnostics: diagnostics,
      loopEvidence: loopEvidence
    )
  }

  private func ensureJSONBAvailable(_ db: OpaquePointer?) throws {
    let rows = try queryRows(
      db,
      sql: "SELECT typeof(jsonb('{}')) AS storage_type, json_valid(jsonb('{}'), 8) AS valid_jsonb",
      bindings: []
    )
    guard rows.first?["storage_type"] == "blob", rows.first?["valid_jsonb"] == "1" else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("sqlite JSONB support is unavailable")
    }
  }

  private func execute(_ db: OpaquePointer?, _ sql: String, bindings: [RuntimeSQLiteBinding] = []) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed(sqliteErrorMessage(db))
    }
    defer {
      sqlite3_finalize(statement)
    }
    try bind(statement, bindings)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed(sqliteErrorMessage(db))
    }
  }

  private func queryRows(_ db: OpaquePointer?, sql: String, bindings: [RuntimeSQLiteBinding]) throws -> [[String: String?]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed(sqliteErrorMessage(db))
    }
    defer {
      sqlite3_finalize(statement)
    }
    try bind(statement, bindings)
    var rows: [[String: String?]] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE {
        return rows
      }
      if result == SQLITE_ROW {
        var row: [String: String?] = [:]
        for index in 0..<sqlite3_column_count(statement) {
          guard let name = sqlite3_column_name(statement, index) else {
            continue
          }
          if sqlite3_column_type(statement, index) == SQLITE_NULL {
            row[String(cString: name)] = nil
          } else if let text = sqlite3_column_text(statement, index) {
            row[String(cString: name)] = String(cString: text)
          } else {
            row[String(cString: name)] = nil
          }
        }
        rows.append(row)
        continue
      }
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed(sqliteErrorMessage(db))
    }
  }

  private func tableColumnNames(_ db: OpaquePointer?, tableName: String) throws -> Set<String> {
    let rows = try queryRows(db, sql: "PRAGMA table_info(\(tableName))", bindings: [])
    return Set(rows.compactMap { $0["name"] ?? nil })
  }

  private func loopEvidenceSelectExpression(_ db: OpaquePointer?) throws -> String {
    if try tableColumnNames(db, tableName: "workflow_runtime_snapshots").contains("loop_evidence_json") {
      return "CASE WHEN loop_evidence_json IS NULL THEN NULL ELSE json(loop_evidence_json) END AS loop_evidence_json"
    }
    return "NULL AS loop_evidence_json"
  }

  private func bind(_ statement: OpaquePointer?, _ bindings: [RuntimeSQLiteBinding]) throws {
    for (offset, binding) in bindings.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch binding {
      case .text(let value):
        result = sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor)
      case .nullableText(let value):
        if let value {
          result = sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor)
        } else {
          result = sqlite3_bind_null(statement, index)
        }
      }
      guard result == SQLITE_OK else {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed("sqlite bind failed at parameter \(index)")
      }
    }
  }

  private func jsonString<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
  }

  private func isSafeId(_ value: String) -> Bool {
    guard !value.isEmpty, !value.contains("/"), !value.contains("..") else {
      return false
    }
    return value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
  }

  private static func dateString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

private enum RuntimeSQLiteBinding {
  case text(String)
  case nullableText(String?)
}

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func sqliteErrorMessage(_ db: OpaquePointer?) -> String {
  guard let message = sqlite3_errmsg(db) else {
    return "unknown sqlite error"
  }
  return String(cString: message)
}
