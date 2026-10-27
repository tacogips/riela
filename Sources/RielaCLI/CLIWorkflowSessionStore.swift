import Foundation
import RielaCore
import RielaSQLite

public struct PersistedCLIWorkflowSession: Codable, Equatable, Sendable {
  public var workflowName: String
  public var session: WorkflowSession
  public var resolution: WorkflowResolutionOptions
  public var mockScenarioPath: String?
  public var runtimeVariables: JSONObject?
  /// Summary count populated by `list`; execution payloads remain unloaded.
  public var executionCount: Int?

  public init(
    workflowName: String,
    session: WorkflowSession,
    resolution: WorkflowResolutionOptions,
    mockScenarioPath: String? = nil,
    runtimeVariables: JSONObject? = nil,
    executionCount: Int? = nil
  ) {
    self.workflowName = workflowName
    self.session = session
    self.resolution = resolution
    self.mockScenarioPath = mockScenarioPath
    self.runtimeVariables = runtimeVariables
    self.executionCount = executionCount
  }
}

public enum CLIWorkflowSessionStoreError: Error, Equatable, Sendable {
  case invalidSessionId(String)
  case notFound(String)
  case canonicalSnapshotMissing(sessionId: String)
  case canonicalSnapshotMismatch(sessionId: String)
  case io(String)
  case sqliteFailed(String)
}

private struct CLIWorkflowSessionEnvelope: Codable {
  struct SessionStub: Codable {
    var sessionId: String
    var workflowId: String
    var status: WorkflowSessionStatus
    var updatedAt: Date
  }

  var workflowName: String
  var resolution: WorkflowResolutionOptions
  var mockScenarioPath: String?
  var runtimeVariables: JSONObject?
  var sessionStorage: String
  var session: SessionStub

  init(_ record: PersistedCLIWorkflowSession) {
    workflowName = record.workflowName
    resolution = record.resolution
    mockScenarioPath = record.mockScenarioPath
    runtimeVariables = record.runtimeVariables
    sessionStorage = "canonical"
    session = SessionStub(
      sessionId: record.session.sessionId,
      workflowId: record.session.workflowId,
      status: record.session.status,
      updatedAt: record.session.updatedAt
    )
  }
}

public struct CLIWorkflowSessionStore: Sendable {
  public var rootDirectory: String
  private let warningSink: @Sendable (String) -> Void

  public init(rootDirectory: String) {
    self.rootDirectory = rootDirectory
    warningSink = Self.writeWarningToStandardError
  }

  init(
    rootDirectory: String,
    warningSink: @escaping @Sendable (String) -> Void
  ) {
    self.rootDirectory = rootDirectory
    self.warningSink = warningSink
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
    guard record.executionCount == nil else {
      throw CLIWorkflowSessionStoreError.sqliteFailed(
        "cannot save header-only session summary: \(record.session.sessionId)"
      )
    }
    guard isSafeSessionId(record.session.sessionId) else {
      throw CLIWorkflowSessionStoreError.invalidSessionId(record.session.sessionId)
    }
    try FileManager.default.createDirectory(atPath: rootDirectory, withIntermediateDirectories: true)
    let db = try openPersistenceDatabase()
    let runtimeStore = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: rootDirectory)
    )
    try prepareRuntimePersistenceSchemas(in: db, runtimeStore: runtimeStore)
    let seedSnapshot = WorkflowRuntimePersistenceProjector.snapshot(session: record.session)
    try WorkflowDefinitionPins.recordForeignPinIfNeeded(
      snapshot: seedSnapshot,
      sessionStoreRoot: runtimeStore.rootDirectory
    )
    try db.transaction { database in
      let snapshot: WorkflowRuntimePersistenceSnapshot
      do {
        var existing = try runtimeStore.load(sessionId: record.session.sessionId, in: database)
        existing.session = record.session
        snapshot = existing
      } catch let error as WorkflowRuntimePersistenceStoreError {
        guard case .notFound = error else { throw error }
        snapshot = WorkflowRuntimePersistenceProjector.snapshot(session: record.session)
      }
      try upsertRecord(database, record)
      try runtimeStore.save(snapshot, in: database)
    }
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
    let databasePath = Self.defaultDatabasePath(rootDirectory: rootDirectory)
    let schemaVersion = try db.query("PRAGMA schema_version").first?["schema_version"].flatMap(Int.init)
    let userVersion = Int(SQLiteWorkflowRuntimePersistenceStore.schemaGeneration)
    if let schemaVersion, CLIWorkflowSchemaSetupCache.shared.hasPrepared(
         databasePath: databasePath, schemaVersion: schemaVersion, userVersion: userVersion
       ) {
      try db.requireJSONBAvailable()
      try SQLiteWorkflowRuntimePersistenceStore.requireCompatibleSchemaGeneration(in: db)
      return
    }
    try ensureSchema(db)
    try runtimeStore.prepareSchema(in: db)
    let updatedSchemaVersion = try db.query("PRAGMA schema_version").first?["schema_version"].flatMap(Int.init)
    if let updatedSchemaVersion {
      CLIWorkflowSchemaSetupCache.shared.markPrepared(
        databasePath: databasePath, schemaVersion: updatedSchemaVersion, userVersion: userVersion
      )
    }
  }

  func save(
    _ record: PersistedCLIWorkflowSession,
    runtimeSnapshot snapshot: WorkflowRuntimePersistenceSnapshot,
    in db: SQLiteDatabase,
    runtimeStore: SQLiteWorkflowRuntimePersistenceStore
  ) throws {
    do {
      try validate(record: record, snapshot: snapshot)
      try WorkflowDefinitionPins.recordForeignPinIfNeeded(
        snapshot: snapshot,
        sessionStoreRoot: runtimeStore.rootDirectory
      )
      try db.transaction { database in
        try upsertRecord(database, record)
        try runtimeStore.save(snapshot, in: database)
      }
    } catch {
      if String(describing: error).contains("no such table") {
        CLIWorkflowSchemaSetupCache.shared.invalidate(databasePath: Self.defaultDatabasePath(rootDirectory: rootDirectory))
      }
      throw error
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
    try WorkflowDefinitionPins.recordForeignPinIfNeeded(
      snapshot: snapshot,
      sessionStoreRoot: runtimeStore.rootDirectory
    )
    try db.transaction { database in
      try upsertRecord(database, record)
      try runtimeStore.save(snapshot, appendingWorkflowMessages: messages, in: database)
    }
  }

  public func load(
    sessionId: String,
    strictReadOnly: Bool = false
  ) throws -> PersistedCLIWorkflowSession {
    try read(sessionId: sessionId, strictReadOnly: strictReadOnly, strictDecoding: false)
  }

  public func loadStrictReadOnly(sessionId: String) throws -> PersistedCLIWorkflowSession {
    try read(sessionId: sessionId, strictReadOnly: true, strictDecoding: true)
  }

  private func read(
    sessionId: String,
    strictReadOnly: Bool,
    strictDecoding: Bool
  ) throws -> PersistedCLIWorkflowSession {
    guard isSafeSessionId(sessionId) else {
      throw CLIWorkflowSessionStoreError.invalidSessionId(sessionId)
    }
    guard FileManager.default.fileExists(atPath: databasePath) else {
      throw CLIWorkflowSessionStoreError.notFound("session not found: \(sessionId)")
    }
    let db = try openDatabase(readOnly: true, strictReadOnly: strictReadOnly)
    guard try tableExists(db, name: "cli_workflow_sessions") else {
      throw CLIWorkflowSessionStoreError.notFound("session not found: \(sessionId)")
    }
    do {
      return try db.transaction(begin: "BEGIN") { database in
        let rows = try mapSQLiteError {
          try database.query(
            "SELECT json(record_json) AS record_json, json_type(record_json, '$.sessionStorage') AS storage FROM cli_workflow_sessions WHERE session_id = ? LIMIT 1",
            bindings: [.text(sessionId)]
          )
        }
        guard let row = rows.first else {
          throw CLIWorkflowSessionStoreError.notFound("session not found: \(sessionId)")
        }
        guard let recordText = row["record_json"] else {
          if strictDecoding {
            throw CLIWorkflowSessionStoreError.sqliteFailed("stored session record is missing")
          }
          throw CLIWorkflowSessionStoreError.notFound("session not found: \(sessionId)")
        }
        let record = try decodeStoredRecord(
          recordText,
          sessionId: sessionId,
          in: database,
          includeExecutions: true,
          validateEnvelopeHeader: strictDecoding,
          isLegacy: row["storage"] == nil
        )
        if strictDecoding, record.session.sessionId != sessionId {
          throw CLIWorkflowSessionStoreError.sqliteFailed("stored session ID does not match requested ID")
        }
        return record
      }
    } catch {
      if let storeError = error as? CLIWorkflowSessionStoreError {
        switch storeError {
        case .notFound: throw storeError
        case .canonicalSnapshotMissing where strictDecoding: throw storeError
        case .canonicalSnapshotMismatch where strictDecoding: throw storeError
        case .canonicalSnapshotMissing:
          warnAboutSkippedRecords(count: 1)
          throw CLIWorkflowSessionStoreError.notFound("session not found: \(sessionId)")
        default: break
        }
      }
      if strictDecoding {
        throw CLIWorkflowSessionStoreError.sqliteFailed("stored session record is invalid or mismatched")
      }
      warnAboutSkippedRecords(count: 1)
      throw CLIWorkflowSessionStoreError.notFound("session not found: \(sessionId)")
    }
  }

  public func loadAll() throws -> [PersistedCLIWorkflowSession] {
    guard FileManager.default.fileExists(atPath: databasePath) else {
      return []
    }
    let db = try openDatabase(readOnly: true)
    guard try tableExists(db, name: "cli_workflow_sessions") else {
      return []
    }
    return try db.transaction(begin: "BEGIN") { database in
      let rows = try mapSQLiteError {
        try database.query("SELECT session_id, json(record_json) AS record_json, json_type(record_json, '$.sessionStorage') AS storage FROM cli_workflow_sessions ORDER BY session_id")
      }
      return decodeRecords(rows, in: database, includeExecutions: true)
    }
  }

  /// Cheap existence probe used while reserving a fresh session id. It never
  /// decodes the record and treats an unreadable store as "unknown" (false)
  /// so reservation can still proceed on a brand-new session store.
  func sessionRecordExists(sessionId: String) -> Bool {
    guard isSafeSessionId(sessionId), FileManager.default.fileExists(atPath: databasePath) else {
      return false
    }
    guard let db = try? openDatabase(readOnly: true) else { return false }
    for table in ["cli_workflow_sessions", "session_retention_tombstones"] where (try? db.tableExists(table)) == true {
      if let rows = try? db.query("SELECT 1 FROM \(table) WHERE session_id=? LIMIT 1", bindings: [.text(sessionId)]), !rows.isEmpty {
        return true
      }
    }
    return false
  }

  func observeStartupIdentities(_ generator: any WorkflowRuntimeIDGenerating) throws {
    guard FileManager.default.fileExists(atPath: databasePath) else { return }
    do {
      let db = try openDatabase(readOnly: true)
      if try db.tableExists("cli_workflow_sessions"),
         !(try SQLiteWorkflowStartupIdentities.isPrepared(db, source: .cli)) {
        try prepareStartupIdentityMetadata()
      }
    }
    let db = try openDatabase(readOnly: true)
    if try db.tableExists("cli_workflow_sessions") {
      for row in try SQLiteWorkflowStartupIdentities.load(db, source: .cli) {
        generator.noteExistingSessionId(row.sessionId, workflowId: row.workflowId)
        row.executionIds.forEach { generator.noteExistingStepExecutionId($0) }
      }
    }
    if try db.tableExists("session_retention_tombstones") {
      for row in try db.query("SELECT session_id,workflow_id FROM session_retention_tombstones") {
        if let id = row["session_id"], let workflow = row["workflow_id"] {
          generator.noteExistingSessionId(id, workflowId: workflow)
        }
      }
    }
  }

  private func prepareStartupIdentityMetadata() throws {
    let db = try openDatabase()
    try db.transaction { database in
      try SQLiteWorkflowStartupIdentities.backfill(database, source: .cli)
    }
  }

  func loadRawSessionIdentities() throws -> [(sessionId: String, workflowId: String)] {
    guard FileManager.default.fileExists(atPath: databasePath) else {
      return []
    }
    let db = try openDatabase(readOnly: true)
    let rows = try db.tableExists("cli_workflow_sessions")
      ? db.query("SELECT session_id,workflow_id FROM cli_workflow_sessions ORDER BY session_id") : []
    let tombstones = try db.tableExists("session_retention_tombstones")
      ? db.query("SELECT session_id,workflow_id FROM session_retention_tombstones ORDER BY session_id") : []
    return (rows + tombstones).compactMap { row in
      guard let sessionId = row["session_id"],
            let workflowId = row["workflow_id"] else {
        return nil
      }
      return (sessionId: sessionId, workflowId: workflowId)
    }
  }

  /// Preserve execution ID high-water marks without decoding stored payloads.
  func observePersistedExecutionIdentities(_ generator: any WorkflowRuntimeIDGenerating) throws {
    guard FileManager.default.fileExists(atPath: databasePath) else { return }
    let db = try openDatabase(readOnly: true)
    guard try tableExists(db, name: "cli_workflow_sessions") else { return }
    let rows = try db.query(
      "SELECT session_id, json_type(record_json, '$.sessionStorage') AS storage "
        + "FROM cli_workflow_sessions ORDER BY session_id"
    )
    let runtimeStore = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: rootDirectory)
    )
    for row in rows {
      guard let sessionId = row["session_id"] else { continue }
      if row["storage"] == "text" {
        try runtimeStore.executionIdentities(sessionId: sessionId)
          .forEach { generator.noteExistingStepExecutionId($0) }
      } else {
        let identities = try db.query(
          "SELECT json_extract(e.value, '$.executionId') AS execution_id "
            + "FROM cli_workflow_sessions, json_each(record_json, '$.session.executions') AS e "
            + "WHERE session_id = ?",
          bindings: [.text(sessionId)]
        )
        identities.compactMap { $0["execution_id"] }
          .forEach { generator.noteExistingStepExecutionId($0) }
      }
    }
  }

  public func list(
    workflowName: String? = nil,
    status: WorkflowSessionStatus? = nil,
    limit: Int = 10
  ) throws -> [PersistedCLIWorkflowSession] {
    guard FileManager.default.fileExists(atPath: databasePath) else {
      return []
    }
    let db = try openDatabase(readOnly: true)
    guard try tableExists(db, name: "cli_workflow_sessions") else {
      return []
    }
    let query = try listSQL(workflowName: workflowName, status: status, limit: limit, in: db)
    return try db.transaction(begin: "BEGIN") { database in
      let rows = try mapSQLiteError { try database.query(query.sql, bindings: query.bindings) }
      return decodeRecords(rows, in: database, includeExecutions: false)
    }
  }

  func listSQL(
    workflowName: String?,
    status: WorkflowSessionStatus?,
    limit: Int,
    in db: SQLiteDatabase
  ) throws -> (sql: String, bindings: [SQLiteValue]) {
    let boundedLimit = max(1, min(limit, 100))
    var predicates: [String] = []
    var bindings: [SQLiteValue] = []
    if let workflowName {
      predicates.append("workflow_name = ?")
      bindings.append(.text(workflowName))
    }
    let hasSnapshots = try tableExists(db, name: "workflow_runtime_snapshots")
    let hasExecutionRows = try tableExists(db, name: "workflow_runtime_executions")
      && (try tableExists(db, name: "workflow_runtime_payloads"))
    if let status {
      predicates.append(hasSnapshots
        ? "COALESCE(runtime_snapshot.session_status, status) = ?"
        : "status = ?")
      bindings.append(.text(status.rawValue))
    }
    let whereClause = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
    bindings.append(.int(Int64(boundedLimit)))
    let executionCountExpression: String
    let snapshotJoin: String
    if hasSnapshots {
      snapshotJoin = """
      LEFT JOIN workflow_runtime_snapshots AS runtime_snapshot
        ON runtime_snapshot.workflow_execution_id = cli_workflow_sessions.session_id
      """
      let inlineCount = """
      (SELECT COUNT(*) FROM json_each(runtime_snapshot.session_json, '$.executions') AS e
        WHERE json_extract(e.value, '$.importedFrom') IS NULL)
      """
      let rowCount = hasExecutionRows
        ? """
          (SELECT COUNT(*) FROM workflow_runtime_executions AS e
            JOIN workflow_runtime_payloads AS p
              ON p.root_session_id=e.root_session_id AND p.digest=e.payload_digest
            WHERE e.workflow_execution_id=cli_workflow_sessions.session_id
              AND json_extract(p.bytes, '$.importedFrom') IS NULL)
          """
        : "0"
      executionCountExpression = """
      CASE
        WHEN json_extract(runtime_snapshot.session_json, '$._rielaNewExecutionCount') IS NOT NULL
          THEN json_extract(runtime_snapshot.session_json, '$._rielaNewExecutionCount')
        WHEN json_type(runtime_snapshot.session_json, '$.executions') = 'array'
          THEN \(inlineCount)
        ELSE COALESCE(\(rowCount), 0)
      END
      """
    } else {
      snapshotJoin = ""
      executionCountExpression = "(SELECT COUNT(*) FROM json_each(record_json, '$.session.executions') AS e WHERE json_extract(e.value, '$.importedFrom') IS NULL)"
    }
    let sql = """
    SELECT session_id, json(record_json) AS record_json,
      json_type(record_json, '$.sessionStorage') AS storage,
      CASE WHEN json_extract(record_json, '$.sessionStorage') = 'canonical'
        THEN COALESCE(\(executionCountExpression), 0)
        ELSE (SELECT COUNT(*) FROM json_each(record_json, '$.session.executions') AS e
          WHERE json_extract(e.value, '$.importedFrom') IS NULL) END AS execution_count
    FROM cli_workflow_sessions
    \(snapshotJoin)
    \(whereClause)
    ORDER BY cli_workflow_sessions.updated_at DESC, cli_workflow_sessions.session_id
    LIMIT ?
    """
    return (sql, bindings)
  }

  public func legacyFullRecordIds(limit: Int) throws -> [String] {
    guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
    let db = try openDatabase(readOnly: true)
    guard try tableExists(db, name: "cli_workflow_sessions") else { return [] }
    let boundedLimit = max(1, min(limit, 10_000))
    return try db.query(
      "SELECT session_id FROM cli_workflow_sessions "
        + "WHERE json_extract(record_json, '$.sessionStorage') IS NOT 'canonical' "
        + "ORDER BY session_id LIMIT ?",
      bindings: [.int(Int64(boundedLimit))]
    ).compactMap { $0["session_id"] }
  }

  /// Rewrites one legacy full row after ensuring its canonical snapshot exists.
  /// The caller must hold the session execution lock for the entire operation.
  @discardableResult
  public func convertLegacyRecord(sessionId: String) throws -> Bool {
    guard isSafeSessionId(sessionId) else {
      throw CLIWorkflowSessionStoreError.invalidSessionId(sessionId)
    }
    guard FileManager.default.fileExists(atPath: databasePath) else { return false }
    let db = try openPersistenceDatabase()
    let runtimeStore = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: rootDirectory)
    )
    try prepareRuntimePersistenceSchemas(in: db, runtimeStore: runtimeStore)
    guard let row = try db.query(
      "SELECT json(record_json) AS record_json, json_type(record_json, '$.sessionStorage') AS storage FROM cli_workflow_sessions WHERE session_id = ?",
      bindings: [.text(sessionId)]
    ).first, let text = row["record_json"], row["storage"] == nil else { return false }
    let record = try decodeRecord(text)
    let pinSnapshot: WorkflowRuntimePersistenceSnapshot
    do {
      pinSnapshot = try runtimeStore.load(sessionId: sessionId)
    } catch let error as WorkflowRuntimePersistenceStoreError {
      guard case .notFound = error else { throw error }
      pinSnapshot = WorkflowRuntimePersistenceProjector.snapshot(session: record.session)
    }
    try WorkflowDefinitionPins.recordForeignPinIfNeeded(
      snapshot: pinSnapshot,
      sessionStoreRoot: runtimeStore.rootDirectory
    )
    return try db.transaction(begin: "BEGIN IMMEDIATE") { database in
      guard let currentRow = try database.query(
        "SELECT json(record_json) AS record_json, json_type(record_json, '$.sessionStorage') AS storage FROM cli_workflow_sessions WHERE session_id = ?",
        bindings: [.text(sessionId)]
      ).first, currentRow["storage"] == nil, let current = currentRow["record_json"] else { return false }
      var converted = try decodeRecord(current)
      let snapshot: WorkflowRuntimePersistenceSnapshot
      do {
        snapshot = try runtimeStore.load(sessionId: sessionId, in: database)
        converted.session = snapshot.session
      } catch let error as WorkflowRuntimePersistenceStoreError {
        guard case .notFound = error else { throw error }
        snapshot = WorkflowRuntimePersistenceProjector.snapshot(session: converted.session)
        try runtimeStore.save(snapshot, in: database)
      }
      try upsertRecord(database, converted)
      return true
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

  private func openDatabase(
    readOnly: Bool = false,
    strictReadOnly: Bool = false
  ) throws -> SQLiteDatabase {
    let runtimeRoot = canonicalRuntimeStoreRoot(sessionStoreRoot: rootDirectory)
    if strictReadOnly {
      return try openDatabaseBody(runtimeRoot: runtimeRoot, readOnly: readOnly, strictReadOnly: strictReadOnly)
    }
    if readOnly {
      return try RuntimeDatabaseAccess.withSchemaLockIfUninitialized(
        rootDirectory: runtimeRoot, databasePath: databasePath
      ) {
        try openDatabaseBody(runtimeRoot: runtimeRoot, readOnly: true, strictReadOnly: false)
      }
    }
    return try RuntimeDatabaseAccess.withSchemaLock(rootDirectory: runtimeRoot) {
      try openDatabaseBody(runtimeRoot: runtimeRoot, readOnly: false, strictReadOnly: false)
    }
  }

  private func openDatabaseBody(
    runtimeRoot: String,
    readOnly: Bool,
    strictReadOnly: Bool
  ) throws -> SQLiteDatabase {
    if !readOnly, !strictReadOnly {
      SQLiteWorkflowRuntimePersistenceStore.discardIncompatibleStoreIfNeeded(databasePath: databasePath)
    }
    let mode: SQLiteOpenMode
    if strictReadOnly {
      mode = .strictReadOnlyWithImmutableFallback
    } else {
      mode = readOnly ? .readOnly : .readWriteCreate
    }
    let database = try mapSQLiteError {
      try SQLiteDatabase.open(
        path: databasePath,
        mode: mode,
        options: readOnly ? .readOnlyDefault : .writableRuntimeStoreDefault
      )
    }
    if !readOnly, !strictReadOnly {
      let runtimeStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot)
      try prepareRuntimePersistenceSchemas(in: database, runtimeStore: runtimeStore)
    }
    return database
  }

  private func ensureSchema(_ db: SQLiteDatabase) throws {
    try mapSQLiteError {
      try db.requireJSONBAvailable()
      try SQLiteWorkflowRuntimePersistenceStore.requireCompatibleSchemaGeneration(in: db)
      // Filter columns are generated from record_json so they can never drift
      // from the persisted record; updated_at stays explicit because the JSON
      // dates lack the fractional seconds the list ordering relies on.
      try db.execute(
      """
      CREATE TABLE IF NOT EXISTS cli_workflow_sessions (
        session_id TEXT PRIMARY KEY,
        record_json BLOB NOT NULL CHECK (json_valid(record_json, 8)),
        updated_at TEXT NOT NULL,
        workflow_name TEXT NOT NULL GENERATED ALWAYS AS (json_extract(record_json, '$.workflowName')) STORED,
        workflow_id TEXT NOT NULL GENERATED ALWAYS AS (json_extract(record_json, '$.session.workflowId')) STORED,
        status TEXT NOT NULL GENERATED ALWAYS AS (json_extract(record_json, '$.session.status')) STORED
      )
      """
      )
      try db.execute("CREATE INDEX IF NOT EXISTS idx_cli_workflow_sessions_updated ON cli_workflow_sessions (updated_at DESC, session_id)")
      try db.execute("CREATE INDEX IF NOT EXISTS idx_cli_workflow_sessions_workflow_status_updated ON cli_workflow_sessions (workflow_name, status, updated_at DESC)")
      try SQLiteWorkflowStartupIdentities.ensureSchema(db, source: .cli)
      try ensureSessionRetentionTriggers(db)
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
        session_id, record_json, updated_at
      ) VALUES (?, jsonb(?), ?)
      ON CONFLICT(session_id) DO UPDATE SET
        record_json = excluded.record_json,
        updated_at = excluded.updated_at
      """,
      bindings: [
        .text(record.session.sessionId),
        .text(try jsonString(CLIWorkflowSessionEnvelope(record))),
        .text(Self.dateString(record.session.updatedAt))
      ]
      )
      try SQLiteWorkflowStartupIdentities.save(db, source: .cli,
        sessionId: record.session.sessionId, workflowId: record.session.workflowId,
        executionIds: record.session.executions.map(\.executionId))
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

  private func decodeStoredRecord(
    _ text: String,
    sessionId: String,
    in db: SQLiteDatabase,
    includeExecutions: Bool,
    validateEnvelopeHeader: Bool = false,
    isLegacy: Bool
  ) throws -> PersistedCLIWorkflowSession {
    if isLegacy { return try decodeRecord(text) }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let data = text.data(using: .utf8) else {
      throw CLIWorkflowSessionStoreError.sqliteFailed("stored session envelope is not UTF-8")
    }
    let envelope = try decoder.decode(CLIWorkflowSessionEnvelope.self, from: data)
    guard envelope.sessionStorage == "canonical" else {
      throw CLIWorkflowSessionStoreError.sqliteFailed("stored session envelope marker is invalid")
    }
    let runtimeStore = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: rootDirectory)
    )
    let session: WorkflowSession
    do {
      if includeExecutions {
        session = try runtimeStore.load(sessionId: sessionId, in: db).session
      } else {
        session = try runtimeStore.loadSessionHeader(sessionId: sessionId, in: db)
      }
    } catch let error as WorkflowRuntimePersistenceStoreError {
      if case .notFound = error {
        throw CLIWorkflowSessionStoreError.canonicalSnapshotMissing(sessionId: sessionId)
      }
      throw error
    }
    guard !validateEnvelopeHeader
      || (envelope.session.sessionId == session.sessionId
        && envelope.session.workflowId == session.workflowId
        && envelope.session.status == session.status) else {
      throw CLIWorkflowSessionStoreError.canonicalSnapshotMismatch(sessionId: sessionId)
    }
    return PersistedCLIWorkflowSession(
      workflowName: envelope.workflowName,
      session: session,
      resolution: envelope.resolution,
      mockScenarioPath: envelope.mockScenarioPath,
      runtimeVariables: envelope.runtimeVariables
    )
  }

  private func decodeRecords(
    _ rows: [SQLiteRow],
    in db: SQLiteDatabase,
    includeExecutions: Bool
  ) -> [PersistedCLIWorkflowSession] {
    var records: [PersistedCLIWorkflowSession] = []
    var skippedCount = 0
    for row in rows {
      guard let recordText = row["record_json"] else {
        continue
      }
      guard let sessionId = row["session_id"] else { continue }
      let isLegacy = row["storage"] == nil
      let record: PersistedCLIWorkflowSession
      do {
        record = try decodeStoredRecord(
          recordText,
          sessionId: sessionId,
          in: db,
          includeExecutions: includeExecutions,
          isLegacy: isLegacy
        )
      } catch {
        skippedCount += 1
        continue
      }
      var summary = record
      if !includeExecutions, let count = row["execution_count"].flatMap(Int.init) {
        summary.executionCount = count
      }
      records.append(summary)
    }
    warnAboutSkippedRecords(count: skippedCount)
    return records
  }

  private func warnAboutSkippedRecords(count: Int) {
    guard count > 0 else {
      return
    }
    warningSink("warning: skipped \(count) unreadable CLI session record(s)")
  }

  private static func writeWarningToStandardError(_ message: String) {
    let data = Data("\(message)\n".utf8)
    FileHandle.standardError.write(data)
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

enum RuntimeStoreHydration: Equatable, Sendable {
  case none
  case family(of: String)
}

/// Builds the in-memory runtime store a production command seeds from the
/// persisted CLI state. Fresh session ids are reserved through
/// `executionLocks` so concurrent processes sharing one session store never
/// create the same session (GitHub #122). Pass the same registry to
/// `makeSessionExecutionAdmission(registry:)` so the runner's admission check
/// recognises the reservation instead of re-acquiring it.
func makeSeededProductionRuntimeStore(
  sessionStoreRoot: String,
  executionLocks: SessionExecutionLockRegistry,
  hydration: RuntimeStoreHydration
) async throws -> InMemoryWorkflowRuntimeStore {
  let sessionStore = CLIWorkflowSessionStore(rootDirectory: sessionStoreRoot)
  let persistenceStore = SQLiteWorkflowRuntimePersistenceStore(
    rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot)
  )
  let generator = LockReservingWorkflowRuntimeIDGenerator(registry: executionLocks) { sessionId in
    sessionStore.sessionRecordExists(sessionId: sessionId)
      || ((try? persistenceStore.sessionExists(sessionId: sessionId)) ?? false)
  }
  let runtimeStore = InMemoryWorkflowRuntimeStore(idGenerator: generator)
  for attempt in 0..<3 {
    do {
      try sessionStore.observeStartupIdentities(generator)
      try persistenceStore.observePersistedIdentities(generator)
      break
    } catch SQLiteWorkflowStartupIdentities.MetadataError.staleProjection {
      if attempt == 2 { throw SQLiteWorkflowStartupIdentities.MetadataError.staleProjection }
    }
  }
  if case let .family(sessionId) = hydration {
    try await seedRuntimeStoreFromPersistedCLIState(
      runtimeStore,
      sessionStoreRoot: sessionStoreRoot,
      familyOf: sessionId
    )
  }
  return runtimeStore
}

func seedRuntimeStoreFromPersistedCLIState(
  _ runtimeStore: InMemoryWorkflowRuntimeStore,
  sessionStoreRoot: String,
  familyOf sessionId: String
) async throws {
  let sessionStore = CLIWorkflowSessionStore(rootDirectory: sessionStoreRoot)
  let persistenceStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot))
  // A durable supervisor can reserve a family child before its CLI record
  // exists, so family hydration also checks each canonical snapshot.
  var seen = Set<String>()
  let familyIds = ([sessionId] + (try persistenceStore.sessionFamilyIds(of: sessionId))).filter {
    seen.insert($0).inserted
  }
  for familyId in familyIds {
    let existing: PersistedCLIWorkflowSession?
    do {
      existing = try sessionStore.load(sessionId: familyId)
    } catch let error as CLIWorkflowSessionStoreError {
      if case .notFound = error {
        existing = nil
      } else {
        throw error
      }
    }
    if let existing {
      await runtimeStore.seedSession(existing.session)
      do {
        let snapshot = try persistenceStore.load(sessionId: familyId)
        await runtimeStore.seedWorkflowMessages(snapshot.workflowMessages)
      } catch let error as WorkflowRuntimePersistenceStoreError {
        if case .notFound = error { continue }
        throw error
      }
    } else {
      do {
        let snapshot = try persistenceStore.load(sessionId: familyId)
        await runtimeStore.seedSession(snapshot.session)
        await runtimeStore.seedWorkflowMessages(snapshot.workflowMessages)
      } catch let snapshotError as WorkflowRuntimePersistenceStoreError {
        if case .notFound = snapshotError { continue }
        throw snapshotError
      }
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

private final class CLIWorkflowSchemaSetupCache: @unchecked Sendable {
  static let shared = CLIWorkflowSchemaSetupCache()
  private struct Entry: Equatable {
    let device: UInt64
    let inode: UInt64
    let schemaVersion: Int
    let userVersion: Int
  }
  private let lock = NSLock()
  private var entries: [String: Entry] = [:]

  func hasPrepared(databasePath: String, schemaVersion: Int, userVersion: Int) -> Bool {
    guard let identity = fileIdentity(databasePath: databasePath, schemaVersion: schemaVersion, userVersion: userVersion) else { return false }
    lock.lock()
    defer { lock.unlock() }
    return entries[databasePath] == identity
  }

  func markPrepared(databasePath: String, schemaVersion: Int, userVersion: Int) {
    guard let identity = fileIdentity(databasePath: databasePath, schemaVersion: schemaVersion, userVersion: userVersion) else { return }
    lock.lock()
    defer { lock.unlock() }
    entries[databasePath] = identity
  }

  func invalidate(databasePath: String) {
    lock.lock()
    defer { lock.unlock() }
    entries.removeValue(forKey: databasePath)
  }

  private func fileIdentity(databasePath: String, schemaVersion: Int, userVersion: Int) -> Entry? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: databasePath),
          let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
          let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
    return Entry(device: device, inode: inode, schemaVersion: schemaVersion, userVersion: userVersion)
  }
}
