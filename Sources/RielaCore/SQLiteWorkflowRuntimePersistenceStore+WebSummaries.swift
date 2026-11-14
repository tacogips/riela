import Foundation
import RielaSQLite

public extension SQLiteWorkflowRuntimePersistenceStore {
  struct MessageRoutingRecord: Equatable, Sendable {
    public var communicationId: String
    public var fromStepId: String?
    public var toStepId: String?
    public var sourceStepExecutionId: String?
    public var transitionCondition: String?
    public var lifecycleStatus: WorkflowMessageLifecycleStatus
    public var deliveryKind: WorkflowMessageDeliveryKind?
    public var createdOrder: Int
    public var createdAt: Date

    public init(
      communicationId: String,
      fromStepId: String?,
      toStepId: String?,
      sourceStepExecutionId: String?,
      transitionCondition: String?,
      lifecycleStatus: WorkflowMessageLifecycleStatus,
      deliveryKind: WorkflowMessageDeliveryKind?,
      createdOrder: Int,
      createdAt: Date
    ) {
      self.communicationId = communicationId
      self.fromStepId = fromStepId
      self.toStepId = toStepId
      self.sourceStepExecutionId = sourceStepExecutionId
      self.transitionCondition = transitionCondition
      self.lifecycleStatus = lifecycleStatus
      self.deliveryKind = deliveryKind
      self.createdOrder = createdOrder
      self.createdAt = createdAt
    }
  }

  struct WebSessionDetail: Equatable, Sendable {
    public var session: WorkflowSession
    public var diagnostics: [String]
    public var loopEvidence: LoopEvidenceManifest?
    public var messageTotalCount: Int
    public var messages: [MessageRoutingRecord]

    public init(
      session: WorkflowSession,
      diagnostics: [String],
      loopEvidence: LoopEvidenceManifest?,
      messageTotalCount: Int,
      messages: [MessageRoutingRecord]
    ) {
      self.session = session
      self.diagnostics = diagnostics
      self.loopEvidence = loopEvidence
      self.messageTotalCount = messageTotalCount
      self.messages = messages
    }
  }

  struct SessionSummary: Equatable, Sendable {
    public var sessionId: String
    public var workflowId: String
    public var status: WorkflowSessionStatus
    public var currentStepId: String?
    public var activeStepIds: [String]
    public var updatedAt: Date

    public init(
      sessionId: String,
      workflowId: String,
      status: WorkflowSessionStatus,
      currentStepId: String?,
      activeStepIds: [String],
      updatedAt: Date
    ) {
      self.sessionId = sessionId
      self.workflowId = workflowId
      self.status = status
      self.currentStepId = currentStepId
      self.activeStepIds = activeStepIds
      self.updatedAt = updatedAt
    }
  }

  func loadSessionSummaries(
    workflowId: String,
    limit: Int
  ) throws -> [SessionSummary] {
    guard FileManager.default.fileExists(
      atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)
    ) else {
      return []
    }
    let boundedLimit = max(1, min(limit, 200))
    if try summarySchemaNeedsMigration() {
      let writableDatabase = try openDatabase(readOnly: false)
      try prepareSchema(in: writableDatabase)
    }
    let db = try openDatabase(readOnly: true)
    guard try !hasUnmigratedSummaryRows(database: db) else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed(
        "runtime session summary migration did not complete"
      )
    }
    let statuses: [WorkflowSessionStatus] = [.created, .running, .completed, .failed]
    let rows = try statuses.flatMap { status in
      try summaryRows(
        database: db,
        whereClause: "snapshots.workflow_id = ? AND snapshots.session_status = ?",
        bindings: [.text(workflowId), .text(status.rawValue), .int(Int64(boundedLimit))]
      )
    }
    .sorted(by: sessionSummaryRowPrecedes)
    .prefix(boundedLimit)
    .map { $0 }
    let decoder = JSONDecoder()
    return try rows.map { row in
      guard let sessionId = row["workflow_execution_id"],
            let rowWorkflowId = row["workflow_id"],
            let statusValue = row["session_status"],
            let status = WorkflowSessionStatus(rawValue: statusValue),
            let updatedAtValue = row["updated_at"],
            let updatedAt = Self.date(from: updatedAtValue),
            let activeStepIdsValue = row["active_step_ids"],
            let activeStepIdsData = activeStepIdsValue.data(using: .utf8) else {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed(
          "runtime session summary row is malformed"
        )
      }
      var activeStepIds = Set(try decoder.decode([String].self, from: activeStepIdsData))
      let currentStepId = row["current_step_id"]
      if status == .running, let currentStepId {
        activeStepIds.insert(currentStepId)
      }
      return SessionSummary(
        sessionId: sessionId,
        workflowId: rowWorkflowId,
        status: status,
        currentStepId: currentStepId,
        activeStepIds: activeStepIds.sorted(),
        updatedAt: updatedAt
      )
    }
  }

  func loadWebSessionDetail(
    sessionId: String,
    messageLimit: Int
  ) throws -> WebSessionDetail {
    guard isSafeId(sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(sessionId)
    }
    guard FileManager.default.fileExists(
      atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)
    ) else {
      throw WorkflowRuntimePersistenceStoreError.notFound(sessionId)
    }
    if try webDetailSchemaNeedsMigration() {
      let writableDatabase = try openDatabase(readOnly: false)
      try prepareSchema(in: writableDatabase)
    }
    let boundedMessageLimit = max(1, min(messageLimit, 500))
    let db = try openDatabase(readOnly: true)
    return try mapRuntimeSQLiteError {
      try db.transaction(begin: "BEGIN") { database in
        try webSessionDetail(
          sessionId: sessionId,
          messageLimit: boundedMessageLimit,
          database: database
        )
      }
    }
  }

  private func webSessionDetail(
    sessionId: String,
    messageLimit: Int,
    database: SQLiteDatabase
  ) throws -> WebSessionDetail {
    let loopEvidenceSelect = try loopEvidenceSelectExpression(database)
    let snapshotRows = try mapRuntimeSQLiteError {
      try database.query(
        """
        SELECT json(session_json) AS session_json,
          json(diagnostics_json) AS diagnostics_json,
          \(loopEvidenceSelect)
        FROM workflow_runtime_snapshots
        WHERE workflow_execution_id = ?
        LIMIT 1
        """,
        bindings: [.text(sessionId)]
      )
    }
    guard let row = snapshotRows.first else {
      throw WorkflowRuntimePersistenceStoreError.notFound(sessionId)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let sessionValue = row["session_json"],
          let diagnosticsValue = row["diagnostics_json"],
          let sessionData = sessionValue.data(using: .utf8),
          let diagnosticsData = diagnosticsValue.data(using: .utf8) else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed(
        "runtime web session detail row is malformed"
      )
    }
    let session = try decoder.decode(WorkflowSession.self, from: sessionData)
    let diagnostics = try decoder.decode([String].self, from: diagnosticsData)
    let loopEvidence: LoopEvidenceManifest?
    if let value = row["loop_evidence_json"], let data = value.data(using: .utf8) {
      loopEvidence = try decoder.decode(LoopEvidenceManifest.self, from: data)
    } else {
      loopEvidence = nil
    }
    let messageTotalCount = try loadMessageCount(sessionId: sessionId, database: database)
    let messages = try loadRecentRoutingMessages(
      sessionId: sessionId,
      limit: messageLimit,
      database: database
    )
    return WebSessionDetail(
      session: session,
      diagnostics: diagnostics,
      loopEvidence: loopEvidence,
      messageTotalCount: messageTotalCount,
      messages: messages
    )
  }

  func loadDiagnostics(sessionId: String) throws -> [String] {
    guard isSafeId(sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(sessionId)
    }
    guard FileManager.default.fileExists(
      atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)
    ) else {
      return []
    }
    let db = try openDatabase(readOnly: true)
    let rows = try mapRuntimeSQLiteError {
      try db.query(
        """
        SELECT json(diagnostics_json) AS diagnostics_json
        FROM workflow_runtime_snapshots
        WHERE workflow_execution_id = ?
        LIMIT 1
        """,
        bindings: [.text(sessionId)]
      )
    }
    guard let diagnosticsValue = rows.first?["diagnostics_json"],
          let diagnosticsData = diagnosticsValue.data(using: .utf8) else {
      return []
    }
    return try JSONDecoder().decode([String].self, from: diagnosticsData)
  }

  private func summaryRows(
    database: SQLiteDatabase,
    whereClause: String,
    bindings: [SQLiteValue]
  ) throws -> [SQLiteRow] {
    try mapRuntimeSQLiteError {
      try database.query(
        """
        SELECT snapshots.workflow_execution_id,
          snapshots.workflow_id,
          snapshots.session_status,
          json_extract(snapshots.session_json, '$.currentStepId') AS current_step_id,
          COALESCE((
            SELECT json_group_array(json_extract(execution.value, '$.stepId'))
            FROM json_each(snapshots.session_json, '$.executions') AS execution
            WHERE json_extract(execution.value, '$.status') = 'running'
          ), '[]') AS active_step_ids,
          snapshots.updated_at
        FROM workflow_runtime_snapshots AS snapshots
        WHERE \(whereClause)
        ORDER BY snapshots.updated_at DESC
        LIMIT ?
        """,
        bindings: bindings
      )
    }
  }

  private func summarySchemaNeedsMigration() throws -> Bool {
    let db = try openDatabase(readOnly: true)
    let columns = try mapRuntimeSQLiteError {
      try db.tableColumnNames("workflow_runtime_snapshots")
    }
    guard columns.contains("workflow_id"),
          columns.contains("session_status"),
          columns.contains("created_at") else {
      return true
    }
    return try hasUnmigratedSummaryRows(database: db)
  }

  private func hasUnmigratedSummaryRows(database: SQLiteDatabase) throws -> Bool {
    try mapRuntimeSQLiteError {
      try database.query(
        """
        SELECT workflow_execution_id
        FROM workflow_runtime_snapshots
        WHERE workflow_id IS NULL
        LIMIT 1
        """
      ).first != nil
    }
  }

  private func webDetailSchemaNeedsMigration() throws -> Bool {
    let db = try openDatabase(readOnly: true)
    let columns = try mapRuntimeSQLiteError {
      try db.tableColumnNames("workflow_runtime_snapshots")
    }
    guard columns.contains("loop_evidence_json") else {
      return true
    }
    return try mapRuntimeSQLiteError {
      try db.query(
        """
        SELECT 1
        FROM sqlite_schema
        WHERE type = 'index'
          AND name = 'idx_workflow_messages_session_order'
        LIMIT 1
        """
      ).first == nil
    }
  }

  private func loadMessageCount(
    sessionId: String,
    database: SQLiteDatabase
  ) throws -> Int {
    let rows = try mapRuntimeSQLiteError {
      try database.query(
        """
        SELECT COUNT(*) AS message_count
        FROM workflow_messages
        WHERE workflow_execution_id = ?
        """,
        bindings: [.text(sessionId)]
      )
    }
    guard let value = rows.first?["message_count"], let count = Int(value) else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed(
        "runtime message count row is malformed"
      )
    }
    return count
  }

  private func loadRecentRoutingMessages(
    sessionId: String,
    limit: Int,
    database: SQLiteDatabase
  ) throws -> [MessageRoutingRecord] {
    let rows = try mapRuntimeSQLiteError {
      try database.query(
        """
        SELECT communication_id, from_step_id, to_step_id,
          source_step_execution_id, transition_condition,
          lifecycle_status, delivery_kind, created_order, created_at
        FROM workflow_messages
        WHERE workflow_execution_id = ?
        ORDER BY created_order DESC, communication_id DESC
        LIMIT ?
        """,
        bindings: [.text(sessionId), .int(Int64(limit))]
      )
    }
    return try rows.reversed().map { row in
      guard let communicationId = row["communication_id"],
            let lifecycleStatusValue = row["lifecycle_status"],
            let lifecycleStatus = WorkflowMessageLifecycleStatus(rawValue: lifecycleStatusValue),
            let deliveryKindValue = row["delivery_kind"],
            let deliveryKind = WorkflowMessageDeliveryKind(rawValue: deliveryKindValue),
            let createdOrderValue = row["created_order"],
            let createdOrder = Int(createdOrderValue),
            let createdAtValue = row["created_at"],
            let createdAt = Self.date(from: createdAtValue) else {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed(
          "runtime routing message row is malformed"
        )
      }
      return MessageRoutingRecord(
        communicationId: communicationId,
        fromStepId: row["from_step_id"],
        toStepId: row["to_step_id"],
        sourceStepExecutionId: row["source_step_execution_id"],
        transitionCondition: row["transition_condition"],
        lifecycleStatus: lifecycleStatus,
        deliveryKind: deliveryKind,
        createdOrder: createdOrder,
        createdAt: createdAt
      )
    }
  }
}

private func sessionSummaryRowPrecedes(_ lhs: SQLiteRow, _ rhs: SQLiteRow) -> Bool {
  let lhsUpdatedAt = lhs["updated_at"] ?? ""
  let rhsUpdatedAt = rhs["updated_at"] ?? ""
  if lhsUpdatedAt != rhsUpdatedAt {
    return lhsUpdatedAt > rhsUpdatedAt
  }
  return (lhs["workflow_execution_id"] ?? "") < (rhs["workflow_execution_id"] ?? "")
}

func backfillRuntimeSessionSummaryColumns(_ db: SQLiteDatabase) throws {
  // Undecodable legacy rows must keep NULL summary columns (the decode-based
  // backfill skips them); gate this cheap SQL pass on a known session status
  // so it cannot resurrect rows the typed decoder rejects.
  let knownStatuses = WorkflowSessionStatus.allCases
    .map { "'\($0.rawValue)'" }
    .joined(separator: ", ")
  try db.execute(
    """
    UPDATE workflow_runtime_snapshots
    SET workflow_id = COALESCE(workflow_id, json_extract(session_json, '$.workflowId')),
      session_status = COALESCE(session_status, json_extract(session_json, '$.status')),
      created_at = COALESCE(created_at, json_extract(session_json, '$.createdAt'))
    WHERE (workflow_id IS NULL
      OR session_status IS NULL
      OR created_at IS NULL)
      AND json_extract(session_json, '$.status') IN (\(knownStatuses))
    """
  )
}
