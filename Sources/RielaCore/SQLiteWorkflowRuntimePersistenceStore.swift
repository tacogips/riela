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
  public static let executionStorageMarkerKey = "_rielaExecutionStorage"

  public struct PersistenceWriteSample: Sendable {
    public let boundBytes: Int
    public let statements: Int

    public init(boundBytes: Int, statements: Int) {
      self.boundBytes = boundBytes
      self.statements = statements
    }
  }

  /// The generation-11 stamp and 10→11 step live in the schema extension below.
  /// Search tokens: `schemaGeneration: Int64 = 11`, `fromGeneration: 10`.
  public var rootDirectory: String
  private let executionReuse = RuntimeExecutionReuse()
  let persistenceWriteObserver: (@Sendable (PersistenceWriteSample) -> Void)?

  public init(
    rootDirectory: String,
    persistenceWriteObserver: (@Sendable (PersistenceWriteSample) -> Void)? = nil
  ) {
    self.rootDirectory = rootDirectory
    self.persistenceWriteObserver = persistenceWriteObserver
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
    try WorkflowDefinitionPins.recordForeignPinIfNeeded(snapshot: snapshot, sessionStoreRoot: rootDirectory)
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
    try WorkflowDefinitionPins.recordForeignPinIfNeeded(snapshot: snapshot, sessionStoreRoot: rootDirectory)
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
    try load(sessionId: sessionId, strictReadOnly: false)
  }

  /// Read the committed state without decoding invocation inputs and outputs.
  /// Terminal fencing needs these two scalars, even for a very large history.
  public func loadStatus(sessionId: String) throws -> (status: WorkflowSessionStatus, failureKind: WorkflowSessionFailureKind?) {
    guard isSafeId(sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(sessionId)
    }
    let db = try openDatabase(readOnly: true)
    guard try runtimeSnapshotTableExists(db) else {
      throw WorkflowRuntimePersistenceStoreError.notFound("runtime snapshot not found: \(sessionId)")
    }
    let rows = try mapRuntimeSQLiteError {
      try db.query(
        "SELECT session_status, json_extract(session_json, '$.failureKind') AS failure_kind, "
          + "json_type(session_json, '$.failureKind') AS failure_type "
          + "FROM workflow_runtime_snapshots WHERE workflow_execution_id = ? LIMIT 1",
        bindings: [.text(sessionId)]
      )
    }
    guard let row = rows.first else {
      throw WorkflowRuntimePersistenceStoreError.notFound("runtime snapshot not found: \(sessionId)")
    }
    guard let value = row["session_status"], let status = WorkflowSessionStatus(rawValue: value) else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("runtime snapshot status is invalid")
    }
    guard row["failure_type"] == nil || row["failure_type"] == "null" || row["failure_type"] == "text" else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("runtime snapshot failure kind is invalid")
    }
    return (status, row["failure_kind"].map(WorkflowSessionFailureKind.init(rawValue:)))
  }

  /// Reports whether a runtime snapshot row exists for `sessionId` without
  /// decoding it. A missing database or table reports `false`.
  public func sessionExists(sessionId: String) throws -> Bool {
    guard isSafeId(sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(sessionId)
    }
    guard FileManager.default.fileExists(atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)) else {
      return false
    }
    let db = try openDatabase(readOnly: true)
    guard try runtimeSnapshotTableExists(db) else {
      return false
    }
    let rows = try mapRuntimeSQLiteError {
      try db.query(
        "SELECT 1 FROM workflow_runtime_snapshots WHERE workflow_execution_id = ? LIMIT 1",
        bindings: [.text(sessionId)]
      )
    }
    return !rows.isEmpty
  }

  public func loadStrictReadOnly(sessionId: String) throws -> WorkflowRuntimePersistenceSnapshot {
    try load(sessionId: sessionId, strictReadOnly: true)
  }

  public func load(sessionId: String, in db: SQLiteDatabase) throws -> WorkflowRuntimePersistenceSnapshot {
    guard isSafeId(sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(sessionId)
    }
    guard try runtimeSnapshotTableExists(db) else {
      throw WorkflowRuntimePersistenceStoreError.notFound("runtime snapshot not found: \(sessionId)")
    }
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

  private func load(
    sessionId: String,
    strictReadOnly: Bool
  ) throws -> WorkflowRuntimePersistenceSnapshot {
    guard isSafeId(sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(sessionId)
    }
    let db = try openDatabase(readOnly: true, strictReadOnly: strictReadOnly)
    guard try runtimeSnapshotTableExists(db) else {
      throw WorkflowRuntimePersistenceStoreError.notFound("runtime snapshot not found: \(sessionId)")
    }
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

  /// Advances runtime ID high-water marks without materializing unrelated
  /// session outputs, backend events, or message payloads during a fresh run.
  public func observePersistedIdentities(_ generator: any WorkflowRuntimeIDGenerating) throws {
    guard FileManager.default.fileExists(atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)) else { return }
    do {
      let read = try openDatabase(readOnly: true)
      if try runtimeSnapshotTableExists(read),
         !(try SQLiteWorkflowStartupIdentities.isPrepared(read, source: .runtime)) {
        let write = try openDatabase()
        try write.transaction { try SQLiteWorkflowStartupIdentities.backfill($0, source: .runtime) }
      }
    }
    let db = try openDatabase(readOnly: true)
    try mapRuntimeSQLiteError {
      if try runtimeSnapshotTableExists(db) {
        for row in try SQLiteWorkflowStartupIdentities.load(db, source: .runtime) {
          generator.noteExistingSessionId(row.sessionId, workflowId: row.workflowId)
          row.executionIds.forEach { generator.noteExistingStepExecutionId($0) }
        }
      }
      if try db.tableExists("workflow_messages") {
        for row in try db.query("SELECT communication_id FROM workflow_messages") {
          if let communicationId = row["communication_id"] { generator.noteExistingCommunicationId(communicationId) }
        }
      }
    }
  }

  public func loadAll() throws -> [WorkflowRuntimePersistenceSnapshot] {
    guard FileManager.default.fileExists(atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)) else {
      return []
    }
    let db = try openDatabase(readOnly: true)
    guard try runtimeSnapshotTableExists(db) else {
      return []
    }
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
    guard try runtimeSnapshotTableExists(db) else {
      return []
    }
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
    let isTerminal = snapshot.session.status.isTerminal
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

  /// A loop-concurrency preflight deliberately creates only its lease table.
  /// Readers that run before the first session save must treat that partial
  /// runtime database as empty rather than failing a newly admitted run.
  func runtimeSnapshotTableExists(_ db: SQLiteDatabase) throws -> Bool {
    try mapRuntimeSQLiteError {
      try db.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'workflow_runtime_snapshots' LIMIT 1",
        bindings: []
      )
    }.isEmpty == false
  }

  private func ensureSchema(_ db: SQLiteDatabase) throws {
    try mapRuntimeSQLiteError {
      try db.requireJSONBAvailable()
      try Self.requireCompatibleSchemaGeneration(in: db)
      try WorkflowDefinitionStoreSchema.create(in: db)
      try WorkflowDefinitionHistorySchema.create(in: db)
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
      try SQLiteWorkflowStartupIdentities.ensureSchema(db, source: .runtime)
      try Self.createNestedInvocationSchema(in: db)
      try SQLiteRuntimeExecutionRowsSchema.create(in: db)
    }
  }

  func upsertSnapshot(_ db: SQLiteDatabase, _ snapshot: WorkflowRuntimePersistenceSnapshot) throws {
    traceSnapshotAssembly("begin", count: snapshot.session.executions.count)
    try validateTaskTerminalWrite(snapshot, in: db)
    let cacheKey = Self.defaultDatabasePath(rootDirectory: rootDirectory) + ":" + snapshot.session.sessionId
    let witness = UUID().uuidString
    if try reuseSnapshotExecutions(db, snapshot, cacheKey: cacheKey, witness: witness) { return }
    let persistedHeader = try encodedHeaderJSON(for: snapshot.session, witness: witness)
    try mapRuntimeSQLiteError {
      traceSnapshotAssembly("full-ready", count: snapshot.session.executions.count)
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
      bindings: [.text(snapshot.session.sessionId), .text(persistedHeader)] + snapshotColumnBindings(snapshot)
      )
      let metrics = try writeExecutionRows(db, snapshot)
      try completeSnapshotWrite(db, snapshot, cacheKey: cacheKey, witness: witness)
      observeWrite(headerJSON: persistedHeader, executions: snapshot.session.executions, selected: Array(snapshot.session.executions.indices), statements: metrics.statements + 1)
    }
  }

  private func reuseSnapshotExecutions(
    _ db: SQLiteDatabase, _ snapshot: WorkflowRuntimePersistenceSnapshot,
    cacheKey: String, witness: String
  ) throws -> Bool {
    let sessionId = snapshot.session.sessionId
    guard let previous = executionReuse.load(cacheKey),
      previous.executions.count <= snapshot.session.executions.count,
      previous.executions.map(\.executionId) == snapshot.session.executions.prefix(previous.executions.count).map(\.executionId),
      try db.query("SELECT json_extract(session_json, '$._rielaCanonicalWrite') AS witness FROM workflow_runtime_snapshots WHERE workflow_execution_id = ?",
        bindings: [.text(sessionId)]).first?["witness"] == previous.witness else { return false }
    let changed = snapshot.session.executions.indices.filter {
      $0 >= previous.executions.count || previous.executions[$0] != snapshot.session.executions[$0]
    }
    let persistedHeader = try encodedHeaderJSON(for: snapshot.session, witness: witness)
    let metadata = try snapshotColumnBindings(snapshot)
    let metadataTexts = metadata.prefix(4).map { value -> String? in
      switch value {
      case let .text(text): return text
      case .null: return nil
      default: return nil
      }
    }
    let metadataChanged = [previous.rootOutputJSON, Optional(previous.diagnosticsJSON), previous.loopEvidenceJSON, previous.loopSummaryJSON]
      .enumerated().filter { index, old in old != metadataTexts[index] }
    var assignments = ["session_json = jsonb(?)"]
    var bindings: [SQLiteValue] = [.text(persistedHeader)]
    let columnNames = ["root_output_json", "diagnostics_json", "loop_evidence_json", "loop_summary_json"]
    for (index, value) in metadataChanged {
      assignments.append("\(columnNames[index]) = jsonb(?)")
      bindings.append(metadata[index])
      _ = value
    }
    let createdAt = Self.dateString(snapshot.session.createdAt)
    let updatedAt = Self.dateString(snapshot.session.updatedAt)
    if previous.createdAt != createdAt {
      assignments.append("created_at = ?")
      bindings.append(.text(createdAt))
    }
    if previous.updatedAt != updatedAt {
      assignments.append("updated_at = ?")
      bindings.append(.text(updatedAt))
    }
    bindings += [.text(sessionId), .text(previous.witness)]
    try mapRuntimeSQLiteError {
      traceSnapshotAssembly("delta-ready", count: snapshot.session.executions.count, changed: changed.count)
      let count = try db.executeAndReturnChangedRowCount(
        "UPDATE workflow_runtime_snapshots SET " + assignments.joined(separator: ", ")
          + " WHERE workflow_execution_id=? AND json_extract(session_json, '$._rielaCanonicalWrite')=?",
        bindings: bindings)
      guard count == 1 else {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed("canonical execution witness changed")
      }
      let metrics = try writeExecutionRows(db, snapshot, selected: changed)
      try completeSnapshotWrite(
        db, snapshot, cacheKey: cacheKey, witness: witness,
        executionIds: Array(snapshot.session.executions.dropFirst(previous.executions.count).map(\.executionId))
      )
      observeWrite(headerJSON: persistedHeader, executions: snapshot.session.executions, selected: changed, statements: metrics.statements + 1)
    }
    return true
  }

  private func completeSnapshotWrite(
    _ db: SQLiteDatabase, _ snapshot: WorkflowRuntimePersistenceSnapshot, cacheKey: String, witness: String,
    executionIds: [String]? = nil
  ) throws {
    try WorkflowDefinitionPins.recordPinIfNeeded(db, snapshot: snapshot, sessionStoreRoot: rootDirectory)
    let projectedExecutionIds: [String]
    if let executionIds {
      let existing = try db.query(
        "SELECT execution_ids_json FROM runtime_startup_identities WHERE session_id=?",
        bindings: [.text(snapshot.session.sessionId)]
      ).first?["execution_ids_json"].flatMap { text -> [String]? in
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
      } ?? []
      projectedExecutionIds = existing + executionIds
    } else {
      projectedExecutionIds = snapshot.session.executions.map(\.executionId)
    }
    try SQLiteWorkflowStartupIdentities.save(db, source: .runtime,
      sessionId: snapshot.session.sessionId, workflowId: snapshot.session.workflowId,
      executionIds: projectedExecutionIds)
    try touchLoopConcurrencyLease(db, snapshot)
    if snapshot.session.status.isTerminal {
      _ = try releaseUnreferencedPayloads(rootSessionId: snapshot.session.rootSessionId ?? snapshot.session.sessionId, in: db)
    }
    // A rollback removes this UUID, invalidating the optimization on next save.
    let columns = try snapshotColumnBindings(snapshot)
    executionReuse.remember(
      cacheKey,
      witness: witness,
      executions: snapshot.session.executions,
      rootOutputJSON: optionalText(columns[0]),
      diagnosticsJSON: optionalText(columns[1]) ?? "[]",
      loopEvidenceJSON: optionalText(columns[2]),
      loopSummaryJSON: optionalText(columns[3]),
      createdAt: Self.dateString(snapshot.session.createdAt),
      updatedAt: Self.dateString(snapshot.session.updatedAt)
    )
    traceSnapshotAssembly("written", count: snapshot.session.executions.count)
  }

  private func traceSnapshotAssembly(_ phase: String, count: Int, changed: Int = 0) {
    guard ProcessInfo.processInfo.environment["RIELA_BULK_RESOURCE_DIAGNOSTICS"] == "1" else { return }
    // Numeric test diagnostics only; never emit inputs, outputs, IDs or env.
    FileHandle.standardError.write(Data("canonical-resource phase=\(phase) executions=\(count) changed=\(changed)\n".utf8))
  }

  func isSafeId(_ value: String) -> Bool {
    guard !value.isEmpty, !value.contains("/"), !value.contains("..") else {
      return false
    }
    return value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
  }

  static func dateString(_ date: Date) -> String {
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
