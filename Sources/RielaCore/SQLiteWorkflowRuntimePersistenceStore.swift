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

  public func loadSessionOverviews(_ filter: LoopSessionOverviewFilter) throws -> [LoopSessionOverview] {
    guard FileManager.default.fileExists(atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)) else {
      return []
    }
    let db = try openDatabase(readOnly: true)
    let columns = try mapSQLiteError { try db.tableColumnNames("workflow_runtime_snapshots") }
    let hasSummaryColumns = Set(["workflow_id", "session_status", "created_at", "loop_summary_json"]).isSubset(of: columns)
    let limit = max(1, min(filter.limit, 200))
    let loopEvidencePresenceSelect = columns.contains("loop_evidence_json")
      ? "loop_evidence_json IS NOT NULL AS has_loop_evidence"
      : "0 AS has_loop_evidence"
    var whereParts: [String] = []
    var bindings: [SQLiteValue] = []
    if hasSummaryColumns, let workflowId = filter.workflowId {
      whereParts.append("(workflow_id = ? OR workflow_id IS NULL)")
      bindings.append(.text(workflowId))
    }
    if hasSummaryColumns, let sessionStatus = filter.sessionStatus {
      if sessionStatus == "active" {
        whereParts.append("(session_status IN ('created', 'running') OR session_status IS NULL)")
      } else {
        whereParts.append("(session_status = ? OR session_status IS NULL)")
        bindings.append(.text(sessionStatus))
      }
    }
    let whereSQL = whereParts.isEmpty ? "" : "WHERE " + whereParts.joined(separator: " AND ")
    let batchSize = 200
    var offset = 0
    var overviews: [LoopSessionOverview] = []
    repeat {
      let rows: [SQLiteRow]
      if hasSummaryColumns {
        rows = try mapSQLiteError {
          try db.query(
            """
            SELECT workflow_execution_id,
              workflow_id,
              session_status,
              created_at,
              CASE WHEN loop_summary_json IS NULL THEN NULL ELSE json(loop_summary_json) END AS loop_summary_json,
              \(loopEvidencePresenceSelect),
              updated_at
            FROM workflow_runtime_snapshots
            \(whereSQL)
            ORDER BY updated_at DESC, workflow_execution_id
            LIMIT ? OFFSET ?
            """,
            bindings: bindings + [.int(Int64(batchSize)), .int(Int64(offset))]
          )
        }
      } else {
        let loopEvidenceSelect = try loopEvidenceSelectExpression(db)
        rows = try mapSQLiteError {
          try db.query(
            """
            SELECT workflow_execution_id,
              NULL AS workflow_id,
              NULL AS session_status,
              NULL AS created_at,
              CASE WHEN session_json IS NULL THEN NULL ELSE json(session_json) END AS session_json,
              \(loopEvidenceSelect),
              NULL AS loop_summary_json,
              0 AS has_loop_evidence,
              updated_at
            FROM workflow_runtime_snapshots
            \(whereSQL)
            ORDER BY updated_at DESC, workflow_execution_id
            LIMIT ? OFFSET ?
            """,
            bindings: bindings + [.int(Int64(batchSize)), .int(Int64(offset))]
          )
        }
      }
      let filtered = try rows.compactMap { row in
        try overview(from: row, db: db, hasSummaryColumns: hasSummaryColumns)
      }.filter { overview in
        overview.matches(filter)
      }
      overviews.append(contentsOf: filtered.prefix(limit - overviews.count))
      if rows.count < batchSize || overviews.count >= limit {
        break
      }
      offset += batchSize
    } while true
    return overviews
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
        workflow_id TEXT,
        session_status TEXT,
        created_at TEXT,
        session_json BLOB NOT NULL CHECK (json_valid(session_json, 8)),
        root_output_json BLOB CHECK (root_output_json IS NULL OR json_valid(root_output_json, 8)),
        diagnostics_json BLOB NOT NULL CHECK (json_valid(diagnostics_json, 8)),
        loop_evidence_json BLOB CHECK (loop_evidence_json IS NULL OR json_valid(loop_evidence_json, 8)),
        loop_summary_json BLOB CHECK (loop_summary_json IS NULL OR json_valid(loop_summary_json, 8)),
        updated_at TEXT NOT NULL
      )
      """
      )
      let columns = try db.tableColumnNames("workflow_runtime_snapshots")
      if !columns.contains("workflow_id") {
        try db.execute("ALTER TABLE workflow_runtime_snapshots ADD COLUMN workflow_id TEXT")
      }
      if !columns.contains("session_status") {
        try db.execute("ALTER TABLE workflow_runtime_snapshots ADD COLUMN session_status TEXT")
      }
      if !columns.contains("created_at") {
        try db.execute("ALTER TABLE workflow_runtime_snapshots ADD COLUMN created_at TEXT")
      }
      if !columns.contains("loop_evidence_json") {
        try db.execute(
        """
        ALTER TABLE workflow_runtime_snapshots
        ADD COLUMN loop_evidence_json BLOB CHECK (loop_evidence_json IS NULL OR json_valid(loop_evidence_json, 8))
        """
        )
      }
      if !columns.contains("loop_summary_json") {
        try db.execute(
        """
        ALTER TABLE workflow_runtime_snapshots
        ADD COLUMN loop_summary_json BLOB CHECK (loop_summary_json IS NULL OR json_valid(loop_summary_json, 8))
        """
        )
      }
      try db.execute("CREATE INDEX IF NOT EXISTS idx_workflow_runtime_snapshots_updated ON workflow_runtime_snapshots (updated_at DESC, workflow_execution_id)")
      try db.execute("CREATE INDEX IF NOT EXISTS idx_workflow_runtime_snapshots_summary ON workflow_runtime_snapshots (workflow_id, session_status, updated_at DESC)")
      try backfillSummaryColumns(db)
    }
  }

  private func upsertSnapshot(_ db: SQLiteDatabase, _ snapshot: WorkflowRuntimePersistenceSnapshot) throws {
    let rootOutputJSON = try snapshot.rootOutput.map(jsonString)
    let loopEvidenceJSON = try snapshot.loopEvidence.map(jsonString)
    let loopSummaryJSON = try snapshot.loopEvidence.map {
      try jsonString(LoopSessionSummary.make(manifest: $0, loopMetadata: snapshot.loopMetadata))
    }
    try mapSQLiteError {
      try db.execute(
      """
      INSERT INTO workflow_runtime_snapshots (
        workflow_execution_id, workflow_id, session_status, created_at,
        session_json, root_output_json, diagnostics_json, loop_evidence_json, loop_summary_json, updated_at
      ) VALUES (?, ?, ?, ?, jsonb(?), jsonb(?), jsonb(?), jsonb(?), jsonb(?), ?)
      ON CONFLICT(workflow_execution_id) DO UPDATE SET
        workflow_id = excluded.workflow_id,
        session_status = excluded.session_status,
        created_at = excluded.created_at,
        session_json = excluded.session_json,
        root_output_json = excluded.root_output_json,
        diagnostics_json = excluded.diagnostics_json,
        loop_evidence_json = excluded.loop_evidence_json,
        loop_summary_json = excluded.loop_summary_json,
        updated_at = excluded.updated_at
      """,
      bindings: [
        .text(snapshot.session.sessionId),
        .text(snapshot.session.workflowId),
        .text(snapshot.session.status.rawValue),
        .text(Self.dateString(snapshot.session.createdAt)),
        .text(try jsonString(snapshot.session)),
        .optionalText(rootOutputJSON),
        .text(try jsonString(snapshot.diagnostics)),
        .optionalText(loopEvidenceJSON),
        .optionalText(loopSummaryJSON),
        .text(Self.dateString(snapshot.session.updatedAt))
      ]
      )
    }
  }

  private func backfillSummaryColumns(_ db: SQLiteDatabase) throws {
    let rows = try db.query(
      """
      SELECT workflow_execution_id,
        json(session_json) AS session_json,
        CASE WHEN loop_evidence_json IS NULL THEN NULL ELSE json(loop_evidence_json) END AS loop_evidence_json
      FROM workflow_runtime_snapshots
      WHERE workflow_id IS NULL
        OR session_status IS NULL
        OR created_at IS NULL
        OR (loop_evidence_json IS NOT NULL AND loop_summary_json IS NULL)
      ORDER BY updated_at DESC, workflow_execution_id
      LIMIT 500
      """
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    for row in rows {
      guard let sessionId = row["workflow_execution_id"],
            let sessionText = row["session_json"],
            let sessionData = sessionText.data(using: .utf8) else {
        continue
      }
      guard let summary = legacySummary(from: row, sessionData: sessionData, decoder: decoder) else {
        continue
      }
      try db.execute(
        """
        UPDATE workflow_runtime_snapshots
        SET workflow_id = ?,
          session_status = ?,
          created_at = ?,
          loop_summary_json = jsonb(?)
        WHERE workflow_execution_id = ?
        """,
        bindings: [
          .text(summary.workflowId),
          .text(summary.sessionStatus),
          .text(summary.createdAt),
          .optionalText(summary.loopSummaryJSON),
          .text(sessionId)
        ]
      )
    }
  }

  private func legacySummary(
    from row: SQLiteRow,
    sessionData: Data,
    decoder: JSONDecoder
  ) -> LegacyWorkflowRuntimeSummary? {
    do {
      let session = try decoder.decode(WorkflowSession.self, from: sessionData)
      let summaryJSON: String?
      if let evidenceText = row["loop_evidence_json"], let evidenceData = evidenceText.data(using: .utf8) {
        let evidence = try decoder.decode(LoopEvidenceManifest.self, from: evidenceData)
        summaryJSON = try jsonString(LoopSessionSummary.make(manifest: evidence))
      } else {
        summaryJSON = nil
      }
      return LegacyWorkflowRuntimeSummary(
        workflowId: session.workflowId,
        sessionStatus: session.status.rawValue,
        createdAt: Self.dateString(session.createdAt),
        loopSummaryJSON: summaryJSON
      )
    } catch {
      return nil
    }
  }

  private struct LegacyWorkflowRuntimeSummary {
    var workflowId: String
    var sessionStatus: String
    var createdAt: String
    var loopSummaryJSON: String?
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

  private func overview(
    from row: SQLiteRow,
    db: SQLiteDatabase,
    hasSummaryColumns: Bool
  ) throws -> LoopSessionOverview? {
    guard hasSummaryColumns else {
      return try legacyOverview(from: row)
    }
    if canBuildOverviewFromSummaryColumns(row) {
      return try summaryColumnOverview(from: row)
    }
    guard let sessionId = row["workflow_execution_id"] else {
      return nil
    }
    return try legacyOverview(sessionId: sessionId, db: db)
  }

  private func canBuildOverviewFromSummaryColumns(_ row: SQLiteRow) -> Bool {
    guard row["workflow_id"] != nil,
          row["session_status"] != nil,
          row["created_at"] != nil,
          row["updated_at"] != nil else {
      return false
    }
    return row["loop_summary_json"] != nil || row["has_loop_evidence"] != "1"
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

  private func legacyOverview(sessionId: String, db: SQLiteDatabase) throws -> LoopSessionOverview? {
    let loopEvidenceSelect = try loopEvidenceSelectExpression(db)
    let rows = try mapSQLiteError {
      try db.query(
        """
        SELECT workflow_execution_id,
          CASE WHEN session_json IS NULL THEN NULL ELSE json(session_json) END AS session_json,
          \(loopEvidenceSelect),
          NULL AS loop_summary_json
        FROM workflow_runtime_snapshots
        WHERE workflow_execution_id = ?
        LIMIT 1
        """,
        bindings: [.text(sessionId)]
      )
    }
    guard let row = rows.first else {
      return nil
    }
    return try legacyOverview(from: row)
  }

  private func legacyOverview(from row: SQLiteRow) throws -> LoopSessionOverview? {
    guard let sessionText = row["session_json"], let sessionData = sessionText.data(using: .utf8) else {
      return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let session = try decoder.decode(WorkflowSession.self, from: sessionData)
    let summary: LoopSessionSummary?
    if let summaryText = row["loop_summary_json"], let data = summaryText.data(using: .utf8) {
      summary = try decoder.decode(LoopSessionSummary.self, from: data)
    } else if let evidenceText = row["loop_evidence_json"], let data = evidenceText.data(using: .utf8) {
      let evidence = try decoder.decode(LoopEvidenceManifest.self, from: data)
      summary = LoopSessionSummary.make(manifest: evidence)
    } else {
      summary = nil
    }
    return LoopSessionOverview.make(session: session, summary: summary)
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

  private static func date(from text: String) -> Date? {
    dateFormatter.date(from: text)
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

private extension LoopSessionOverview {
  func matches(_ filter: SQLiteWorkflowRuntimePersistenceStore.LoopSessionOverviewFilter) -> Bool {
    if let workflowId = filter.workflowId, self.workflowId != workflowId {
      return false
    }
    if let sessionStatus = filter.sessionStatus {
      if sessionStatus == "active" {
        guard self.sessionStatus == "created" || self.sessionStatus == "running" else {
          return false
        }
      } else if self.sessionStatus != sessionStatus {
        return false
      }
    }
    if let lastGateDecision = filter.lastGateDecision, self.lastGateDecision != lastGateDecision {
      return false
    }
    return true
  }
}
