import Foundation
import RielaCore
import RielaSQLite

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
    let db = try openPersistenceDatabase()
    let runtimeStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: rootDirectory))
    try prepareRuntimePersistenceSchemas(in: db, runtimeStore: runtimeStore)
    try save(record, runtimeSnapshot: snapshot, in: db, runtimeStore: runtimeStore)
  }

  public func save(
    _ record: PersistedCLIWorkflowSession,
    runtimeSnapshot snapshot: WorkflowRuntimePersistenceSnapshot,
    appendingWorkflowMessages messages: [WorkflowMessageRecord]
  ) throws {
    guard record.session.sessionId == snapshot.session.sessionId else {
      throw CLIWorkflowSessionStoreError.invalidSessionId(snapshot.session.sessionId)
    }
    guard isSafeSessionId(record.session.sessionId) else {
      throw CLIWorkflowSessionStoreError.invalidSessionId(record.session.sessionId)
    }
    try FileManager.default.createDirectory(atPath: rootDirectory, withIntermediateDirectories: true)
    let db = try openPersistenceDatabase()
    let runtimeStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: rootDirectory))
    try prepareRuntimePersistenceSchemas(in: db, runtimeStore: runtimeStore)
    try save(
      record,
      runtimeSnapshot: snapshot,
      appendingWorkflowMessages: messages,
      in: db,
      runtimeStore: runtimeStore
    )
  }

  func openPersistenceDatabase(readOnly: Bool = false) throws -> SQLiteDatabase {
    try openDatabase(readOnly: readOnly)
  }

  func prepareRuntimePersistenceSchemas(
    in db: SQLiteDatabase,
    runtimeStore: SQLiteWorkflowRuntimePersistenceStore
  ) throws {
    try ensureSchema(db)
    try runtimeStore.prepareSchema(in: db)
  }

  func save(
    _ record: PersistedCLIWorkflowSession,
    runtimeSnapshot snapshot: WorkflowRuntimePersistenceSnapshot,
    in db: SQLiteDatabase,
    runtimeStore: SQLiteWorkflowRuntimePersistenceStore
  ) throws {
    try validate(record: record, snapshot: snapshot)
    try db.transaction { database in
      try upsertRecord(database, record)
      try runtimeStore.save(snapshot, in: database)
    }
  }

  func save(
    _ record: PersistedCLIWorkflowSession,
    runtimeSnapshot snapshot: WorkflowRuntimePersistenceSnapshot,
    appendingWorkflowMessages messages: [WorkflowMessageRecord],
    in db: SQLiteDatabase,
    runtimeStore: SQLiteWorkflowRuntimePersistenceStore
  ) throws {
    try validate(record: record, snapshot: snapshot)
    try db.transaction { database in
      try upsertRecord(database, record)
      try runtimeStore.save(snapshot, appendingWorkflowMessages: messages, in: database)
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
    guard try tableExists(db, name: "cli_workflow_sessions") else {
      throw CLIWorkflowSessionStoreError.notFound("session not found: \(sessionId)")
    }
    let rows = try mapSQLiteError {
      try db.query(
        "SELECT json(record_json) AS record_json FROM cli_workflow_sessions WHERE session_id = ? LIMIT 1",
      bindings: [.text(sessionId)]
      )
    }
    guard let recordText = rows.first?["record_json"] else {
      throw CLIWorkflowSessionStoreError.notFound("session not found: \(sessionId)")
    }
    return try decodeRecord(recordText)
  }

  public func loadAll() throws -> [PersistedCLIWorkflowSession] {
    guard FileManager.default.fileExists(atPath: databasePath) else {
      return []
    }
    let db = try openDatabase(readOnly: true)
    guard try tableExists(db, name: "cli_workflow_sessions") else {
      return []
    }
    return try mapSQLiteError {
      try db.query("SELECT json(record_json) AS record_json FROM cli_workflow_sessions ORDER BY session_id")
    }.compactMap { row in
      guard let recordText = row["record_json"] else {
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

  private func validate(
    record: PersistedCLIWorkflowSession,
    snapshot: WorkflowRuntimePersistenceSnapshot
  ) throws {
    guard record.session.sessionId == snapshot.session.sessionId else {
      throw CLIWorkflowSessionStoreError.invalidSessionId(snapshot.session.sessionId)
    }
    guard isSafeSessionId(record.session.sessionId) else {
      throw CLIWorkflowSessionStoreError.invalidSessionId(record.session.sessionId)
    }
  }

  private func openDatabase(readOnly: Bool = false) throws -> SQLiteDatabase {
    try mapSQLiteError {
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
      try db.execute("CREATE INDEX IF NOT EXISTS idx_cli_workflow_sessions_updated ON cli_workflow_sessions (updated_at DESC, session_id)")
    }
  }

  private func tableExists(_ db: SQLiteDatabase, name: String) throws -> Bool {
    try mapSQLiteError {
      try db.tableExists(name)
    }
  }

  private func upsertRecord(_ db: SQLiteDatabase, _ record: PersistedCLIWorkflowSession) throws {
    try mapSQLiteError {
      try db.execute(
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

private func mapSQLiteError<T>(_ body: () throws -> T) throws -> T {
  do {
    return try body()
  } catch let error as SQLiteError {
    throw CLIWorkflowSessionStoreError.sqliteFailed(error.message)
  }
}
