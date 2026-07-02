import Foundation
import RielaSQLite

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
    try prepareSchema(in: db)
    try db.transaction { database in
      try save(snapshot, in: database)
    }
  }

  public func save(_ snapshot: WorkflowRuntimePersistenceSnapshot, in db: SQLiteDatabase) throws {
    guard isSafeId(snapshot.session.sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(snapshot.session.sessionId)
    }
    try upsertSnapshot(db, snapshot)
    try SQLiteWorkflowMessageLog(databasePath: Self.defaultDatabasePath(rootDirectory: rootDirectory))
      .replaceMessages(for: snapshot.session.sessionId, with: snapshot.workflowMessages, in: db)
  }

  public func save(
    _ snapshot: WorkflowRuntimePersistenceSnapshot,
    appendingWorkflowMessages messages: [WorkflowMessageRecord]
  ) throws {
    guard isSafeId(snapshot.session.sessionId),
          messages.allSatisfy({ $0.workflowExecutionId == snapshot.session.sessionId }) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(snapshot.session.sessionId)
    }
    let db = try openDatabase()
    try prepareSchema(in: db)
    try db.transaction { database in
      try save(snapshot, appendingWorkflowMessages: messages, in: database)
    }
  }

  public func save(
    _ snapshot: WorkflowRuntimePersistenceSnapshot,
    appendingWorkflowMessages messages: [WorkflowMessageRecord],
    in db: SQLiteDatabase
  ) throws {
    guard isSafeId(snapshot.session.sessionId),
          messages.allSatisfy({ $0.workflowExecutionId == snapshot.session.sessionId }) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(snapshot.session.sessionId)
    }
    try upsertSnapshot(db, snapshot)
    try SQLiteWorkflowMessageLog(databasePath: Self.defaultDatabasePath(rootDirectory: rootDirectory))
      .upsertMessages(messages, in: db)
  }

  public func prepareSchema(in db: SQLiteDatabase) throws {
    try ensureSchema(db)
    try SQLiteWorkflowMessageLog(databasePath: Self.defaultDatabasePath(rootDirectory: rootDirectory))
      .prepareSchema(in: db)
  }

  public func load(sessionId: String) throws -> WorkflowRuntimePersistenceSnapshot {
    guard isSafeId(sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(sessionId)
    }
    let db = try openDatabase(readOnly: true)
    let loopEvidenceSelect = try loopEvidenceSelectExpression(db)
    let rows = try mapSQLiteError {
      try db.query(
        """
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
    }
    guard let row = rows.first else {
      throw WorkflowRuntimePersistenceStoreError.notFound("runtime snapshot not found: \(sessionId)")
    }
    return try snapshot(from: row, db: db)
  }

  public func loadAll() throws -> [WorkflowRuntimePersistenceSnapshot] {
    guard FileManager.default.fileExists(atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)) else {
      return []
    }
    let db = try openDatabase(readOnly: true)
    let loopEvidenceSelect = try loopEvidenceSelectExpression(db)
    return try mapSQLiteError {
      try db.query(
        """
        SELECT json(session_json) AS session_json,
          CASE WHEN root_output_json IS NULL THEN NULL ELSE json(root_output_json) END AS root_output_json,
          json(diagnostics_json) AS diagnostics_json,
          \(loopEvidenceSelect)
        FROM workflow_runtime_snapshots
        ORDER BY updated_at DESC, workflow_execution_id
        """,
        bindings: []
      )
    }.map { try snapshot(from: $0, db: db) }
  }

  private func openDatabase(readOnly: Bool = false) throws -> SQLiteDatabase {
    let databasePath = Self.defaultDatabasePath(rootDirectory: rootDirectory)
    return try mapSQLiteError {
      try SQLiteDatabase.open(
        path: databasePath,
        mode: readOnly ? .readOnly : .readWriteCreate,
        options: readOnly ? .readOnlyDefault : .writableDefault
      )
    }
  }

  private func ensureSchema(_ db: SQLiteDatabase) throws {
    try mapSQLiteError {
      try db.requireJSONBAvailable()
      try db.execute(
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
      if try !db.tableColumnNames("workflow_runtime_snapshots").contains("loop_evidence_json") {
        try db.execute(
        """
        ALTER TABLE workflow_runtime_snapshots
        ADD COLUMN loop_evidence_json BLOB CHECK (loop_evidence_json IS NULL OR json_valid(loop_evidence_json, 8))
        """
        )
      }
      try db.execute("CREATE INDEX IF NOT EXISTS idx_workflow_runtime_snapshots_updated ON workflow_runtime_snapshots (updated_at DESC, workflow_execution_id)")
    }
  }

  private func upsertSnapshot(_ db: SQLiteDatabase, _ snapshot: WorkflowRuntimePersistenceSnapshot) throws {
    let rootOutputJSON = try snapshot.rootOutput.map(jsonString)
    let loopEvidenceJSON = try snapshot.loopEvidence.map(jsonString)
    try mapSQLiteError {
      try db.execute(
      """
      INSERT INTO workflow_runtime_snapshots (
        workflow_execution_id, session_json, root_output_json, diagnostics_json, loop_evidence_json, updated_at
      ) VALUES (?, jsonb(?), jsonb(?), jsonb(?), jsonb(?), ?)
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
        .optionalText(rootOutputJSON),
        .text(try jsonString(snapshot.diagnostics)),
        .optionalText(loopEvidenceJSON),
        .text(Self.dateString(snapshot.session.updatedAt))
      ]
      )
    }
  }

  private func snapshot(from row: SQLiteRow, db: SQLiteDatabase) throws -> WorkflowRuntimePersistenceSnapshot {
    guard let sessionText = row["session_json"],
          let diagnosticsText = row["diagnostics_json"],
          let sessionData = sessionText.data(using: .utf8),
          let diagnosticsData = diagnosticsText.data(using: .utf8) else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("runtime snapshot row is missing required fields")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let session = try decoder.decode(WorkflowSession.self, from: sessionData)
    let diagnostics = try decoder.decode([String].self, from: diagnosticsData)
    let rootOutput: JSONObject?
    if let rootOutputText = row["root_output_json"], let data = rootOutputText.data(using: .utf8) {
      rootOutput = try decoder.decode(JSONObject.self, from: data)
    } else {
      rootOutput = nil
    }
    let loopEvidence: LoopEvidenceManifest?
    if let loopEvidenceText = row["loop_evidence_json"], let data = loopEvidenceText.data(using: .utf8) {
      loopEvidence = try decoder.decode(LoopEvidenceManifest.self, from: data)
    } else {
      loopEvidence = nil
    }
    let messages = try SQLiteWorkflowMessageLog(databasePath: Self.defaultDatabasePath(rootDirectory: rootDirectory))
      .listMessages(workflowExecutionId: session.sessionId, in: db)
    return WorkflowRuntimePersistenceSnapshot(
      session: session,
      workflowMessages: messages,
      rootOutput: rootOutput,
      diagnostics: diagnostics,
      loopEvidence: loopEvidence
    )
  }

  private func loopEvidenceSelectExpression(_ db: SQLiteDatabase) throws -> String {
    if try mapSQLiteError({ try db.tableColumnNames("workflow_runtime_snapshots") }).contains("loop_evidence_json") {
      return "CASE WHEN loop_evidence_json IS NULL THEN NULL ELSE json(loop_evidence_json) END AS loop_evidence_json"
    }
    return "NULL AS loop_evidence_json"
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
    dateFormatter.string(from: date)
  }
}

private let dateFormatter = LockedISO8601DateFormatter()

private func mapSQLiteError<T>(_ body: () throws -> T) throws -> T {
  do {
    return try body()
  } catch let error as SQLiteError {
    throw WorkflowRuntimePersistenceStoreError.sqliteFailed(error.message)
  }
}
