import Foundation
import RielaCore
import SQLite3

public struct PersistedCLIWorkflowSession: Codable, Equatable, Sendable {
  public var workflowName: String
  public var session: WorkflowSession
  public var resolution: WorkflowResolutionOptions
  public var mockScenarioPath: String?

  public init(
    workflowName: String,
    session: WorkflowSession,
    resolution: WorkflowResolutionOptions,
    mockScenarioPath: String? = nil
  ) {
    self.workflowName = workflowName
    self.session = session
    self.resolution = resolution
    self.mockScenarioPath = mockScenarioPath
  }
}

public enum CLIWorkflowSessionStoreError: Error, Equatable, Sendable {
  case invalidSessionId(String)
  case notFound(String)
  case io(String)
  case sqliteFailed(String)
}

public struct CLIWorkflowSessionStore: Sendable {
  public var rootDirectory: String

  public init(rootDirectory: String) {
    self.rootDirectory = rootDirectory
  }

  public static func defaultDatabasePath(rootDirectory: String) -> String {
    SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: rootDirectory)
    )
  }

  public static func resolveRootDirectory(
    sessionStore: String?,
    scope: WorkflowScope,
    workingDirectory: String,
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
  ) -> String {
    if let sessionStore, !sessionStore.isEmpty {
      let url = URL(fileURLWithPath: sessionStore, isDirectory: true)
      return url.path.hasPrefix("/") ? url.path : URL(fileURLWithPath: workingDirectory).appendingPathComponent(sessionStore).path
    }
    if let envRoot = environment["RIELA_SESSION_STORE"], !envRoot.isEmpty {
      let url = URL(fileURLWithPath: envRoot, isDirectory: true)
      return url.path.hasPrefix("/") ? url.path : URL(fileURLWithPath: workingDirectory).appendingPathComponent(envRoot).path
    }
    switch scope {
    case .user:
      let homeDirectory = CLIRuntimeEnvironment.homeDirectory(environment: environment)
      return URL(fileURLWithPath: homeDirectory)
        .appendingPathComponent(".riela/sessions", isDirectory: true)
        .path
    case .auto, .project, .direct:
      return URL(fileURLWithPath: workingDirectory)
        .appendingPathComponent(".riela/sessions", isDirectory: true)
        .path
    }
  }

  public func save(_ record: PersistedCLIWorkflowSession) throws {
    guard isSafeSessionId(record.session.sessionId) else {
      throw CLIWorkflowSessionStoreError.invalidSessionId(record.session.sessionId)
    }
    try FileManager.default.createDirectory(atPath: rootDirectory, withIntermediateDirectories: true)
    let db = try openDatabase()
    defer {
      sqlite3_close(db)
    }
    try ensureSchema(db)
    try upsertRecord(db, record)
  }

  public func save(
    _ record: PersistedCLIWorkflowSession,
    runtimeSnapshot snapshot: WorkflowRuntimePersistenceSnapshot
  ) throws {
    guard record.session.sessionId == snapshot.session.sessionId else {
      throw CLIWorkflowSessionStoreError.invalidSessionId(snapshot.session.sessionId)
    }
    guard isSafeSessionId(record.session.sessionId) else {
      throw CLIWorkflowSessionStoreError.invalidSessionId(record.session.sessionId)
    }
    try FileManager.default.createDirectory(atPath: rootDirectory, withIntermediateDirectories: true)
    let db = try openDatabase()
    defer {
      sqlite3_close(db)
    }
    try execute(db, "BEGIN IMMEDIATE")
    do {
      try ensureSchema(db)
      try upsertRecord(db, record)
      try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: rootDirectory))
        .save(snapshot, in: db)
      try execute(db, "COMMIT")
    } catch {
      try? execute(db, "ROLLBACK")
      throw error
    }
  }

  public func load(sessionId: String) throws -> PersistedCLIWorkflowSession {
    guard isSafeSessionId(sessionId) else {
      throw CLIWorkflowSessionStoreError.invalidSessionId(sessionId)
    }
    guard FileManager.default.fileExists(atPath: databasePath) else {
      throw CLIWorkflowSessionStoreError.notFound("session not found: \(sessionId)")
    }
    let db = try openDatabase(readOnly: true)
    defer {
      sqlite3_close(db)
    }
    guard try tableExists(db, name: "cli_workflow_sessions") else {
      throw CLIWorkflowSessionStoreError.notFound("session not found: \(sessionId)")
    }
    let rows = try queryRows(
      db,
      sql: "SELECT json(record_json) AS record_json FROM cli_workflow_sessions WHERE session_id = ? LIMIT 1",
      bindings: [.text(sessionId)]
    )
    guard let recordText = rows.first?["record_json"] ?? nil else {
      throw CLIWorkflowSessionStoreError.notFound("session not found: \(sessionId)")
    }
    return try decodeRecord(recordText)
  }

  public func loadAll() throws -> [PersistedCLIWorkflowSession] {
    guard FileManager.default.fileExists(atPath: databasePath) else {
      return []
    }
    let db = try openDatabase(readOnly: true)
    defer {
      sqlite3_close(db)
    }
    guard try tableExists(db, name: "cli_workflow_sessions") else {
      return []
    }
    return try queryRows(
      db,
      sql: "SELECT json(record_json) AS record_json FROM cli_workflow_sessions ORDER BY session_id",
      bindings: []
    ).compactMap { row in
      guard let recordText = row["record_json"] ?? nil else {
        return nil
      }
      return try decodeRecord(recordText)
    }
  }

  private func isSafeSessionId(_ sessionId: String) -> Bool {
    guard !sessionId.isEmpty, !sessionId.contains("/"), !sessionId.contains("..") else {
      return false
    }
    return sessionId.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
  }

  private var databasePath: String {
    Self.defaultDatabasePath(rootDirectory: rootDirectory)
  }

  private func openDatabase(readOnly: Bool = false) throws -> OpaquePointer? {
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
      throw CLIWorkflowSessionStoreError.sqliteFailed("failed to open sqlite database at \(databasePath): \(message)")
    }
    return opened
  }

  private func ensureSchema(_ db: OpaquePointer?) throws {
    try ensureJSONBAvailable(db)
    try execute(
      db,
      """
      CREATE TABLE IF NOT EXISTS cli_workflow_sessions (
        session_id TEXT PRIMARY KEY,
        workflow_name TEXT NOT NULL,
        workflow_id TEXT NOT NULL,
        status TEXT NOT NULL,
        record_json BLOB NOT NULL CHECK (json_valid(record_json, 8)),
        updated_at TEXT NOT NULL
      )
      """
    )
    try execute(db, "CREATE INDEX IF NOT EXISTS idx_cli_workflow_sessions_updated ON cli_workflow_sessions (updated_at DESC, session_id)")
  }

  private func ensureJSONBAvailable(_ db: OpaquePointer?) throws {
    let rows = try queryRows(
      db,
      sql: "SELECT typeof(jsonb('{}')) AS storage_type, json_valid(jsonb('{}'), 8) AS valid_jsonb",
      bindings: []
    )
    guard rows.first?["storage_type"] == "blob", rows.first?["valid_jsonb"] == "1" else {
      throw CLIWorkflowSessionStoreError.sqliteFailed("sqlite JSONB support is unavailable")
    }
  }

  private func tableExists(_ db: OpaquePointer?, name: String) throws -> Bool {
    let rows = try queryRows(
      db,
      sql: "SELECT 1 AS present FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
      bindings: [.text(name)]
    )
    return rows.first?["present"] != nil
  }

  private func upsertRecord(_ db: OpaquePointer?, _ record: PersistedCLIWorkflowSession) throws {
    try execute(
      db,
      """
      INSERT INTO cli_workflow_sessions (
        session_id, workflow_name, workflow_id, status, record_json, updated_at
      ) VALUES (?, ?, ?, ?, jsonb(?), ?)
      ON CONFLICT(session_id) DO UPDATE SET
        workflow_name = excluded.workflow_name,
        workflow_id = excluded.workflow_id,
        status = excluded.status,
        record_json = excluded.record_json,
        updated_at = excluded.updated_at
      """,
      bindings: [
        .text(record.session.sessionId),
        .text(record.workflowName),
        .text(record.session.workflowId),
        .text(record.session.status.rawValue),
        .text(try jsonString(record)),
        .text(Self.dateString(record.session.updatedAt))
      ]
    )
  }

  private func execute(_ db: OpaquePointer?, _ sql: String, bindings: [CLISessionSQLiteBinding] = []) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw CLIWorkflowSessionStoreError.sqliteFailed(sqliteErrorMessage(db))
    }
    defer {
      sqlite3_finalize(statement)
    }
    try bind(statement, bindings)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw CLIWorkflowSessionStoreError.sqliteFailed(sqliteErrorMessage(db))
    }
  }

  private func queryRows(_ db: OpaquePointer?, sql: String, bindings: [CLISessionSQLiteBinding]) throws -> [[String: String?]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw CLIWorkflowSessionStoreError.sqliteFailed(sqliteErrorMessage(db))
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
      throw CLIWorkflowSessionStoreError.sqliteFailed(sqliteErrorMessage(db))
    }
  }

  private func bind(_ statement: OpaquePointer?, _ bindings: [CLISessionSQLiteBinding]) throws {
    for (offset, binding) in bindings.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch binding {
      case .text(let value):
        result = sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor)
      }
      guard result == SQLITE_OK else {
        throw CLIWorkflowSessionStoreError.sqliteFailed("sqlite bind failed at parameter \(index)")
      }
    }
  }

  private func jsonString<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
  }

  private func decodeRecord(_ text: String) throws -> PersistedCLIWorkflowSession {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let data = text.data(using: .utf8) else {
      throw CLIWorkflowSessionStoreError.sqliteFailed("stored session record is not UTF-8")
    }
    return try decoder.decode(PersistedCLIWorkflowSession.self, from: data)
  }

  private static func dateString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

func canonicalRuntimeStoreRoot(sessionStoreRoot: String) -> String {
  URL(fileURLWithPath: sessionStoreRoot, isDirectory: true)
    .appendingPathComponent("runtime-records", isDirectory: true)
    .path
}

func seedRuntimeStoreFromPersistedCLIState(
  _ runtimeStore: InMemoryWorkflowRuntimeStore,
  sessionStoreRoot: String
) async throws {
  let sessionStore = CLIWorkflowSessionStore(rootDirectory: sessionStoreRoot)
  let persistenceStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot))
  for existing in try sessionStore.loadAll() {
    await runtimeStore.seedSession(existing.session)
    do {
      let snapshot = try persistenceStore.load(sessionId: existing.session.sessionId)
      await runtimeStore.seedWorkflowMessages(snapshot.workflowMessages)
    } catch let error as WorkflowRuntimePersistenceStoreError {
      if case .notFound = error {
        continue
      }
      throw error
    }
  }
}

private enum CLISessionSQLiteBinding {
  case text(String)
}

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func sqliteErrorMessage(_ db: OpaquePointer?) -> String {
  guard let message = sqlite3_errmsg(db) else {
    return "unknown sqlite error"
  }
  return String(cString: message)
}
