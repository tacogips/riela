import Foundation
import RielaSQLite

/// Accepted-baseline row for a workflow's loop (design S10). One baseline per
/// workflow id in the MVP.
public struct LoopBaseline: Codable, Equatable, Sendable {
  public var workflowId: String
  public var sessionId: String
  public var setAt: Date
  public var note: String?

  public init(workflowId: String, sessionId: String, setAt: Date, note: String? = nil) {
    self.workflowId = workflowId
    self.sessionId = sessionId
    self.setAt = setAt
    self.note = note
  }
}

public struct SQLiteWorkflowRuntimePersistenceStore: Sendable {
  public var rootDirectory: String

  public init(rootDirectory: String) {
    self.rootDirectory = rootDirectory
  }

  public static func defaultDatabasePath(rootDirectory: String) -> String {
    SQLiteWorkflowMessageLog.defaultDatabasePath(rootDirectory: rootDirectory)
  }

  public struct LoopSessionOverviewFilter: Sendable {
    public var workflowId: String?
    public var sessionStatus: String?
    public var lastGateDecision: String?
    public var limit: Int

    public init(
      workflowId: String? = nil,
      sessionStatus: String? = nil,
      lastGateDecision: String? = nil,
      limit: Int = 50
    ) {
      self.workflowId = workflowId
      self.sessionStatus = sessionStatus
      self.lastGateDecision = lastGateDecision
      self.limit = limit
    }
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

  /// Bumped whenever the schema changes shape. The store never migrates old
  /// layouts in place: a database stamped with an older generation must be
  /// deleted (or garbage-collected) before this build can write to it.
  public static let schemaGeneration: Int64 = 2

  /// Refuses writable opens against a database whose tables predate the
  /// current schema generation, and stamps fresh databases. Throws SQLiteError
  /// so each store maps it into its own error domain.
  public static func requireCompatibleSchemaGeneration(in db: SQLiteDatabase) throws {
    let version = try db.query("PRAGMA user_version").first?["user_version"].flatMap(Int64.init) ?? 0
    guard version < schemaGeneration else {
      return
    }
    let hasPreGenerationTables = try db.tableExists("workflow_runtime_snapshots")
      || db.tableExists("cli_workflow_sessions")
    guard !hasPreGenerationTables else {
      throw SQLiteError(
        operation: .execute,
        code: nil,
        message: "session store schema predates generation \(schemaGeneration); delete the session store and rerun"
      )
    }
    try db.execute("PRAGMA user_version = \(schemaGeneration)")
  }

  /// Deletes an incompatible pre-generation session store database (plus its
  /// WAL/SHM sidecars) so the writable open that follows rebuilds the
  /// current-generation schema from scratch. Session stores hold regenerable
  /// run history, so discarding beats hard-failing every writable open;
  /// memory stores keep their hard error because their data is not
  /// regenerable. Unreadable databases are left for the normal open path to
  /// report.
  @discardableResult
  public static func discardIncompatibleStoreIfNeeded(databasePath: String) -> Bool {
    guard FileManager.default.fileExists(atPath: databasePath) else {
      return false
    }
    let isIncompatible: Bool
    do {
      let db = try SQLiteDatabase.open(path: databasePath, mode: .readOnly, options: .readOnlyDefault)
      let version = try db.query("PRAGMA user_version").first?["user_version"].flatMap(Int64.init) ?? 0
      if version >= schemaGeneration {
        isIncompatible = false
      } else {
        isIncompatible = try db.tableExists("workflow_runtime_snapshots")
          || db.tableExists("cli_workflow_sessions")
          || db.tableExists("workflow_messages")
      }
    } catch {
      return false
    }
    guard isIncompatible else {
      return false
    }
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: databasePath + suffix)
    }
    FileHandle.standardError.write(Data(
      "warning: discarded incompatible pre-generation session store at \(databasePath)\n".utf8
    ))
    return true
  }

  public func load(sessionId: String) throws -> WorkflowRuntimePersistenceSnapshot {
    try load(sessionId: sessionId, strictReadOnly: false)
  }

  public func loadStrictReadOnly(sessionId: String) throws -> WorkflowRuntimePersistenceSnapshot {
    try load(sessionId: sessionId, strictReadOnly: true)
  }

  private func load(
    sessionId: String,
    strictReadOnly: Bool
  ) throws -> WorkflowRuntimePersistenceSnapshot {
    guard isSafeId(sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(sessionId)
    }
    let db = try openDatabase(readOnly: true, strictReadOnly: strictReadOnly)
    let rows = try mapRuntimeSQLiteError {
      try db.query(
        """
        SELECT json(session_json) AS session_json,
          CASE WHEN root_output_json IS NULL THEN NULL ELSE json(root_output_json) END AS root_output_json,
          json(diagnostics_json) AS diagnostics_json,
          \(runtimeLoopEvidenceSelectSQL)
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
    return try mapRuntimeSQLiteError {
      try db.query(
        """
        SELECT json(session_json) AS session_json,
          CASE WHEN root_output_json IS NULL THEN NULL ELSE json(root_output_json) END AS root_output_json,
          json(diagnostics_json) AS diagnostics_json,
          \(runtimeLoopEvidenceSelectSQL)
        FROM workflow_runtime_snapshots
        ORDER BY updated_at DESC, workflow_execution_id
        """,
        bindings: []
      )
    }.map { try snapshot(from: $0, db: db) }
  }

  public func loadSessionOverviews(_ filter: LoopSessionOverviewFilter) throws -> [LoopSessionOverview] {
    guard FileManager.default.fileExists(atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)) else {
      return []
    }
    let db = try openDatabase(readOnly: true)
    let limit = max(1, min(filter.limit, 200))
    var whereParts: [String] = []
    var bindings: [SQLiteValue] = []
    if let workflowId = filter.workflowId {
      whereParts.append("workflow_id = ?")
      bindings.append(.text(workflowId))
    }
    if let sessionStatus = filter.sessionStatus {
      if sessionStatus == "active" {
        whereParts.append("session_status IN ('created', 'running')")
      } else {
        whereParts.append("session_status = ?")
        bindings.append(.text(sessionStatus))
      }
    }
    if let lastGateDecision = filter.lastGateDecision {
      whereParts.append("json_extract(loop_summary_json, '$.lastGateDecision') = ?")
      bindings.append(.text(lastGateDecision))
    }
    let whereSQL = whereParts.isEmpty ? "" : "WHERE " + whereParts.joined(separator: " AND ")
    let rows = try mapRuntimeSQLiteError {
      try db.query(
        """
        SELECT workflow_execution_id,
          workflow_id,
          session_status,
          created_at,
          CASE WHEN loop_summary_json IS NULL THEN NULL ELSE json(loop_summary_json) END AS loop_summary_json,
          updated_at
        FROM workflow_runtime_snapshots
        \(whereSQL)
        ORDER BY updated_at DESC, workflow_execution_id
        LIMIT ?
        """,
        bindings: bindings + [.int(Int64(limit))]
      )
    }
    return try rows.compactMap(summaryColumnOverview(from:))
  }

  // MARK: - Loop baselines (design S10)

  /// Sets or replaces the accepted baseline for a workflow. Writes happen only
  /// through the explicit `loop baseline` commands; the table is created
  /// lazily on this writable open.
  public func setLoopBaseline(_ baseline: LoopBaseline) throws {
    guard isSafeId(baseline.sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(baseline.sessionId)
    }
    let db = try openDatabase()
    try ensureLoopBaselineSchema(db)
    try mapRuntimeSQLiteError {
      try db.execute(
        """
        INSERT INTO loop_baselines (workflow_id, session_id, set_at, note)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(workflow_id) DO UPDATE SET
          session_id = excluded.session_id,
          set_at = excluded.set_at,
          note = excluded.note
        """,
        bindings: [
          .text(baseline.workflowId),
          .text(baseline.sessionId),
          .text(Self.dateString(baseline.setAt)),
          .optionalText(baseline.note)
        ]
      )
    }
  }

  /// Reads the baseline for a workflow on a read-only connection. A missing
  /// database or missing table means "no baseline", never an error.
  public func loadLoopBaseline(workflowId: String) throws -> LoopBaseline? {
    guard FileManager.default.fileExists(atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)) else {
      return nil
    }
    let db = try openDatabase(readOnly: true)
    guard try loopBaselineTableExists(db) else {
      return nil
    }
    let rows = try mapRuntimeSQLiteError {
      try db.query(
        "SELECT workflow_id, session_id, set_at, note FROM loop_baselines WHERE workflow_id = ? LIMIT 1",
        bindings: [.text(workflowId)]
      )
    }
    guard let row = rows.first,
          let sessionId = row["session_id"],
          let setAtText = row["set_at"],
          let setAt = Self.date(from: setAtText) else {
      return nil
    }
    return LoopBaseline(
      workflowId: workflowId,
      sessionId: sessionId,
      setAt: setAt,
      note: row["note"]
    )
  }

  /// Removes the baseline for a workflow. Returns whether a baseline existed.
  @discardableResult
  public func clearLoopBaseline(workflowId: String) throws -> Bool {
    let db = try openDatabase()
    try ensureLoopBaselineSchema(db)
    let existed = try mapRuntimeSQLiteError {
      try db.query(
        "SELECT workflow_id FROM loop_baselines WHERE workflow_id = ? LIMIT 1",
        bindings: [.text(workflowId)]
      )
    }.isEmpty == false
    try mapRuntimeSQLiteError {
      try db.execute("DELETE FROM loop_baselines WHERE workflow_id = ?", bindings: [.text(workflowId)])
    }
    return existed
  }

  private func ensureLoopBaselineSchema(_ db: SQLiteDatabase) throws {
    try mapRuntimeSQLiteError {
      try db.execute(
        """
        CREATE TABLE IF NOT EXISTS loop_baselines (
          workflow_id TEXT PRIMARY KEY,
          session_id  TEXT NOT NULL,
          set_at      TEXT NOT NULL,
          note        TEXT
        ) WITHOUT ROWID
        """
      )
    }
  }

  private func loopBaselineTableExists(_ db: SQLiteDatabase) throws -> Bool {
    try mapRuntimeSQLiteError {
      try db.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'loop_baselines' LIMIT 1",
        bindings: []
      )
    }.isEmpty == false
  }

  // MARK: - Loop concurrency leases (design S11)

  /// How a lease-acquire attempt resolved.
  public enum LoopLeaseAcquisition: Equatable, Sendable {
    /// Lease granted. `takenOverFrom` names the stale holder's session id
    /// when the acquire replaced an expired lease (recorded as a diagnostic
    /// on the new run).
    case acquired(takenOverFrom: String?)
    /// A fresh lease is held by another run.
    case busy(holderSessionId: String, heartbeatAt: Date)
  }

  /// Acquires the single per-workflow lease in one writable transaction:
  /// insert, or replace an existing row only when its heartbeat is older than
  /// `staleAfterSeconds` (default 600 — the `possiblyStale` threshold).
  public func acquireLoopConcurrencyLease(
    workflowId: String,
    holder: String,
    now: Date = Date(),
    staleAfterSeconds: TimeInterval = 600
  ) throws -> LoopLeaseAcquisition {
    let db = try openDatabase()
    try ensureLoopLeaseSchema(db)
    var acquisition = LoopLeaseAcquisition.acquired(takenOverFrom: nil)
    try mapRuntimeSQLiteError {
      try db.transaction { database in
        let rows = try database.query(
          "SELECT session_id, heartbeat_at FROM loop_concurrency_leases WHERE workflow_id = ? LIMIT 1",
          bindings: [.text(workflowId)]
        )
        if let row = rows.first,
           let holderSessionId = row["session_id"],
           let heartbeatText = row["heartbeat_at"],
           let heartbeatAt = Self.date(from: heartbeatText) {
          if now.timeIntervalSince(heartbeatAt) < staleAfterSeconds {
            acquisition = .busy(holderSessionId: holderSessionId, heartbeatAt: heartbeatAt)
            return
          }
          acquisition = .acquired(takenOverFrom: holderSessionId)
        }
        try database.execute(
          """
          INSERT INTO loop_concurrency_leases (workflow_id, session_id, acquired_at, heartbeat_at)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(workflow_id) DO UPDATE SET
            session_id = excluded.session_id,
            acquired_at = excluded.acquired_at,
            heartbeat_at = excluded.heartbeat_at
          """,
          bindings: [
            .text(workflowId),
            .text(holder),
            .text(Self.dateString(now)),
            .text(Self.dateString(now))
          ]
        )
      }
    }
    return acquisition
  }

  /// Current lease row for a workflow.
  public struct LoopConcurrencyLease: Equatable, Sendable {
    public var sessionId: String
    public var acquiredAt: Date
    public var heartbeatAt: Date

    public init(sessionId: String, acquiredAt: Date, heartbeatAt: Date) {
      self.sessionId = sessionId
      self.acquiredAt = acquiredAt
      self.heartbeatAt = heartbeatAt
    }
  }

  /// Reads the current lease row (read-only; missing database/table → nil).
  public func loadLoopConcurrencyLease(workflowId: String) throws -> LoopConcurrencyLease? {
    guard FileManager.default.fileExists(atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)) else {
      return nil
    }
    let db = try openDatabase(readOnly: true)
    guard try loopLeaseTableExists(db) else {
      return nil
    }
    let rows = try mapRuntimeSQLiteError {
      try db.query(
        "SELECT session_id, acquired_at, heartbeat_at FROM loop_concurrency_leases WHERE workflow_id = ? LIMIT 1",
        bindings: [.text(workflowId)]
      )
    }
    guard let row = rows.first,
          let sessionId = row["session_id"],
          let acquiredAt = row["acquired_at"].flatMap(Self.date(from:)),
          let heartbeatAt = row["heartbeat_at"].flatMap(Self.date(from:)) else {
      return nil
    }
    return LoopConcurrencyLease(sessionId: sessionId, acquiredAt: acquiredAt, heartbeatAt: heartbeatAt)
  }

  /// Releases the lease when held by `holder` (a placeholder token or the
  /// bound session id). Crashed processes never call this; their rows expire
  /// via the staleness takeover in `acquireLoopConcurrencyLease`.
  public func releaseLoopConcurrencyLease(workflowId: String, holder: String) throws {
    let db = try openDatabase()
    try ensureLoopLeaseSchema(db)
    try mapRuntimeSQLiteError {
      try db.execute(
        "DELETE FROM loop_concurrency_leases WHERE workflow_id = ? AND session_id = ?",
        bindings: [.text(workflowId), .text(holder)]
      )
    }
  }

  /// Heartbeat/bind/release ride the single snapshot save path (the same
  /// "derived writes happen in one helper" rule the summary columns follow):
  /// a pending placeholder lease binds to the first session saved for the
  /// workflow, live saves refresh the heartbeat, and terminal saves release
  /// the lease. No new timers, no background thread.
  private func touchLoopConcurrencyLease(_ db: SQLiteDatabase, _ snapshot: WorkflowRuntimePersistenceSnapshot) throws {
    guard try loopLeaseTableExists(db) else {
      return
    }
    let sessionId = snapshot.session.sessionId
    let workflowId = snapshot.session.workflowId
    let isTerminal = snapshot.session.status == .completed || snapshot.session.status == .failed
    if isTerminal {
      try db.execute(
        """
        DELETE FROM loop_concurrency_leases
        WHERE workflow_id = ? AND (session_id = ? OR session_id LIKE 'pending:%')
        """,
        bindings: [.text(workflowId), .text(sessionId)]
      )
      return
    }
    try db.execute(
      """
      UPDATE loop_concurrency_leases
      SET session_id = ?, heartbeat_at = ?
      WHERE workflow_id = ? AND (session_id = ? OR session_id LIKE 'pending:%')
      """,
      bindings: [
        .text(sessionId),
        .text(Self.dateString(snapshot.session.updatedAt)),
        .text(workflowId),
        .text(sessionId)
      ]
    )
  }

  private func ensureLoopLeaseSchema(_ db: SQLiteDatabase) throws {
    try mapRuntimeSQLiteError {
      try db.execute(
        """
        CREATE TABLE IF NOT EXISTS loop_concurrency_leases (
          workflow_id  TEXT PRIMARY KEY,
          session_id   TEXT NOT NULL,
          acquired_at  TEXT NOT NULL,
          heartbeat_at TEXT NOT NULL
        ) WITHOUT ROWID
        """
      )
    }
  }

  private func loopLeaseTableExists(_ db: SQLiteDatabase) throws -> Bool {
    try mapRuntimeSQLiteError {
      try db.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'loop_concurrency_leases' LIMIT 1",
        bindings: []
      )
    }.isEmpty == false
  }

  func openDatabase(
    readOnly: Bool = false,
    strictReadOnly: Bool = false
  ) throws -> SQLiteDatabase {
    let databasePath = Self.defaultDatabasePath(rootDirectory: rootDirectory)
    if !readOnly, !strictReadOnly {
      Self.discardIncompatibleStoreIfNeeded(databasePath: databasePath)
    }
    let mode: SQLiteOpenMode
    if strictReadOnly {
      mode = .strictReadOnlyWithImmutableFallback
    } else {
      mode = readOnly ? .readOnly : .readWriteCreate
    }
    return try mapRuntimeSQLiteError {
      try SQLiteDatabase.open(
        path: databasePath,
        mode: mode,
        options: readOnly ? .readOnlyDefault : .writableDefault
      )
    }
  }

  private func ensureSchema(_ db: SQLiteDatabase) throws {
    try mapRuntimeSQLiteError {
      try db.requireJSONBAvailable()
      try Self.requireCompatibleSchemaGeneration(in: db)
      // The summary columns are generated from session_json so they can never
      // drift from the snapshot payload. created_at/updated_at stay explicit:
      // the JSON dates are second-granularity ISO8601 while ordering needs the
      // fractional-second timestamps the store writes itself.
      try db.execute(
      """
      CREATE TABLE IF NOT EXISTS workflow_runtime_snapshots (
        workflow_execution_id TEXT PRIMARY KEY,
        session_json BLOB NOT NULL CHECK (json_valid(session_json, 8)),
        root_output_json BLOB CHECK (root_output_json IS NULL OR json_valid(root_output_json, 8)),
        diagnostics_json BLOB NOT NULL CHECK (json_valid(diagnostics_json, 8)),
        loop_evidence_json BLOB CHECK (loop_evidence_json IS NULL OR json_valid(loop_evidence_json, 8)),
        loop_summary_json BLOB CHECK (loop_summary_json IS NULL OR json_valid(loop_summary_json, 8)),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        workflow_id TEXT NOT NULL GENERATED ALWAYS AS (json_extract(session_json, '$.workflowId')) STORED,
        session_status TEXT NOT NULL GENERATED ALWAYS AS (json_extract(session_json, '$.status')) STORED,
        parent_session_id TEXT GENERATED ALWAYS AS (json_extract(session_json, '$.parentSessionId')) STORED,
        root_session_id TEXT NOT NULL GENERATED ALWAYS AS (
          COALESCE(json_extract(session_json, '$.rootSessionId'), workflow_execution_id)
        ) STORED
      )
      """
      )
      try db.execute("CREATE INDEX IF NOT EXISTS idx_workflow_runtime_snapshots_updated ON workflow_runtime_snapshots (updated_at DESC, workflow_execution_id)")
      try db.execute("CREATE INDEX IF NOT EXISTS idx_workflow_runtime_snapshots_summary ON workflow_runtime_snapshots (workflow_id, session_status, updated_at DESC)")
      try db.execute("CREATE INDEX IF NOT EXISTS idx_workflow_runtime_snapshots_workflow_updated ON workflow_runtime_snapshots (workflow_id, updated_at DESC, workflow_execution_id)")
      try db.execute("CREATE INDEX IF NOT EXISTS idx_workflow_runtime_snapshots_parent ON workflow_runtime_snapshots (parent_session_id, created_at, workflow_execution_id)")
      try db.execute("CREATE INDEX IF NOT EXISTS idx_workflow_runtime_snapshots_root ON workflow_runtime_snapshots (root_session_id, created_at, workflow_execution_id)")
    }
  }

  private func upsertSnapshot(_ db: SQLiteDatabase, _ snapshot: WorkflowRuntimePersistenceSnapshot) throws {
    let rootOutputJSON = try snapshot.rootOutput.map(jsonString)
    let loopEvidenceJSON = try snapshot.loopEvidence.map(jsonString)
    let loopSummaryJSON = try snapshot.loopEvidence.map {
      try jsonString(LoopSessionSummary.make(manifest: $0, loopMetadata: snapshot.loopMetadata))
    }
    try mapRuntimeSQLiteError {
      try db.execute(
      """
      INSERT INTO workflow_runtime_snapshots (
        workflow_execution_id, session_json, root_output_json, diagnostics_json,
        loop_evidence_json, loop_summary_json, created_at, updated_at
      ) VALUES (?, jsonb(?), jsonb(?), jsonb(?), jsonb(?), jsonb(?), ?, ?)
      ON CONFLICT(workflow_execution_id) DO UPDATE SET
        session_json = excluded.session_json,
        root_output_json = excluded.root_output_json,
        diagnostics_json = excluded.diagnostics_json,
        loop_evidence_json = excluded.loop_evidence_json,
        loop_summary_json = excluded.loop_summary_json,
        created_at = excluded.created_at,
        updated_at = excluded.updated_at
      """,
      bindings: [
        .text(snapshot.session.sessionId),
        .text(try jsonString(snapshot.session)),
        .optionalText(rootOutputJSON),
        .text(try jsonString(snapshot.diagnostics)),
        .optionalText(loopEvidenceJSON),
        .optionalText(loopSummaryJSON),
        .text(Self.dateString(snapshot.session.createdAt)),
        .text(Self.dateString(snapshot.session.updatedAt))
      ]
      )
      try touchLoopConcurrencyLease(db, snapshot)
    }
  }

  func snapshot(from row: SQLiteRow, db: SQLiteDatabase) throws -> WorkflowRuntimePersistenceSnapshot {
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

  private func summaryColumnOverview(from row: SQLiteRow) throws -> LoopSessionOverview? {
    guard let sessionId = row["workflow_execution_id"],
          let workflowId = row["workflow_id"],
          let sessionStatus = row["session_status"],
          let createdAtText = row["created_at"],
          let createdAt = Self.date(from: createdAtText),
          let updatedAtText = row["updated_at"],
          let updatedAt = Self.date(from: updatedAtText) else {
      return nil
    }
    let summary: LoopSessionSummary?
    if let summaryText = row["loop_summary_json"], let data = summaryText.data(using: .utf8) {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      summary = try decoder.decode(LoopSessionSummary.self, from: data)
    } else {
      summary = nil
    }
    return LoopSessionOverview.make(
      workflowId: workflowId,
      sessionId: sessionId,
      sessionStatus: sessionStatus,
      createdAt: createdAt,
      updatedAt: updatedAt,
      summary: summary
    )
  }

  private func jsonString<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
  }

  func isSafeId(_ value: String) -> Bool {
    guard !value.isEmpty, !value.contains("/"), !value.contains("..") else {
      return false
    }
    return value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
  }

  private static func dateString(_ date: Date) -> String {
    dateFormatter.string(from: date)
  }

  static func date(from text: String) -> Date? {
    dateFormatter.date(from: text)
  }
}

private let dateFormatter = LockedISO8601DateFormatter()

let runtimeLoopEvidenceSelectSQL =
  "CASE WHEN loop_evidence_json IS NULL THEN NULL ELSE json(loop_evidence_json) END AS loop_evidence_json"

func mapRuntimeSQLiteError<T>(_ body: () throws -> T) throws -> T {
  do {
    return try body()
  } catch let error as SQLiteError {
    throw WorkflowRuntimePersistenceStoreError.sqliteFailed(error.message)
  }
}
