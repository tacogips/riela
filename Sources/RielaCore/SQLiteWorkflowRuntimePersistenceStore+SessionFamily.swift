import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import RielaSQLite

public extension SQLiteWorkflowRuntimePersistenceStore {
  /// Returns the canonical snapshots sharing the target session's root.
  /// Missing stores, tables, and target rows have no known family members.
  func sessionFamilyIds(of sessionId: String) throws -> [String] {
    guard isSafeId(sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(sessionId)
    }
    guard FileManager.default.fileExists(atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)) else {
      return []
    }
    let db = try openDatabase(readOnly: true)
    let tableRows = try mapRuntimeSQLiteError {
      try db.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'workflow_runtime_snapshots' LIMIT 1",
        bindings: []
      )
    }
    guard !tableRows.isEmpty else {
      return []
    }
    let rows = try mapRuntimeSQLiteError {
      try db.query(
        """
        SELECT workflow_execution_id
        FROM workflow_runtime_snapshots
        WHERE root_session_id = (
          SELECT root_session_id
          FROM workflow_runtime_snapshots
          WHERE workflow_execution_id = ?
        )
        ORDER BY created_at, workflow_execution_id
        """,
        bindings: [.text(sessionId)]
      )
    }
    return rows.compactMap { $0["workflow_execution_id"] }
  }

  /// Loads only the requested snapshots, skipping rows that disappeared.
  func loadFamily(ids: [String]) throws -> [WorkflowRuntimePersistenceSnapshot] {
    var snapshots: [WorkflowRuntimePersistenceSnapshot] = []
    for id in ids {
      do {
        snapshots.append(try load(sessionId: id))
      } catch let error as WorkflowRuntimePersistenceStoreError {
        if case .notFound = error { continue }
        throw error
      }
    }
    return snapshots
  }

  func encodedHeaderJSON(for session: WorkflowSession, witness: String) throws -> String {
    let encoded = try jsonString(session)
    guard let data = encoded.data(using: .utf8) else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("runtime session header encoding failed")
    }
    var header = try JSONDecoder().decode(JSONObject.self, from: data)
    header.removeValue(forKey: "executions")
    header[Self.executionStorageMarkerKey] = .string("rows")
    header["_rielaCanonicalWrite"] = .string(witness)
    return try jsonString(header)
  }

  func writeExecutionRows(
    _ db: SQLiteDatabase,
    _ snapshot: WorkflowRuntimePersistenceSnapshot,
    selected: [Int]? = nil
  ) throws -> (statements: Int, bytes: Int) {
    let sessionId = snapshot.session.sessionId
    let rootId = snapshot.session.rootSessionId ?? sessionId
    let indexes = selected ?? Array(snapshot.session.executions.indices)
    var bytes = 0
    var statements = 0
    for ordinal in indexes {
      let execution = snapshot.session.executions[ordinal]
      let payload = try payloadJSON(execution)
      let digest = Self.sha256(payload)
      bytes += payload.utf8.count
      try db.execute(
        "INSERT OR IGNORE INTO workflow_runtime_payloads(root_session_id,digest,bytes,byte_count) VALUES(?,?,jsonb(?),?)",
        bindings: [.text(rootId), .text(digest), .text(payload), .int(Int64(payload.utf8.count))]
      )
      statements += 1
      try db.execute(
        """
        INSERT INTO workflow_runtime_executions(
          workflow_execution_id, ordinal, execution_id, root_session_id, payload_digest
        ) VALUES(?, ?, ?, ?, ?)
        ON CONFLICT(workflow_execution_id, ordinal) DO UPDATE SET
          execution_id=excluded.execution_id,
          root_session_id=excluded.root_session_id,
          payload_digest=excluded.payload_digest
        """,
        bindings: [.text(sessionId), .int(Int64(ordinal)), .text(execution.executionId), .text(rootId), .text(digest)]
      )
      statements += 1
    }
    try db.execute(
      "DELETE FROM workflow_runtime_executions WHERE workflow_execution_id=? AND ordinal>=?",
      bindings: [.text(sessionId), .int(Int64(snapshot.session.executions.count))]
    )
    statements += 1
    _ = try releaseUnreferencedPayloads(rootSessionId: rootId, in: db)
    return (statements, bytes)
  }

  func releaseUnreferencedPayloads(rootSessionId: String, in db: SQLiteDatabase) throws -> Int64 {
    let count = try db.query(
      """
      SELECT COALESCE(SUM(byte_count), 0) AS bytes
      FROM workflow_runtime_payloads AS p
      WHERE p.root_session_id = ?
        AND NOT EXISTS (
          SELECT 1 FROM workflow_runtime_executions AS e
          WHERE e.root_session_id = p.root_session_id AND e.payload_digest = p.digest
        )
        AND NOT EXISTS (
          SELECT 1 FROM workflow_nested_invocation_refs AS r
          WHERE r.root_session_id = p.root_session_id AND r.digest = p.digest
        )
      """,
      bindings: [.text(rootSessionId)]
    ).first?["bytes"].flatMap(Int64.init) ?? 0
    try db.execute(
      """
      DELETE FROM workflow_runtime_payloads AS p
      WHERE p.root_session_id = ?
        AND NOT EXISTS (
          SELECT 1 FROM workflow_runtime_executions AS e
          WHERE e.root_session_id = p.root_session_id AND e.payload_digest = p.digest
        )
        AND NOT EXISTS (
          SELECT 1 FROM workflow_nested_invocation_refs AS r
          WHERE r.root_session_id = p.root_session_id AND r.digest = p.digest
        )
      """,
      bindings: [.text(rootSessionId)]
    )
    return count
  }

  func persistNestedReferences(
    _ snapshot: WorkflowRuntimePersistenceSnapshot,
    invocationKey: String,
    role: String,
    in db: SQLiteDatabase
  ) throws -> JSONObject {
    let rootId = snapshot.session.rootSessionId ?? snapshot.session.sessionId
    try db.execute("DELETE FROM workflow_nested_invocation_refs WHERE invocation_key=? AND role=?", bindings: [.text(invocationKey), .text(role)])
    var header = snapshot
    header.session.executions = []
    header.rootOutput = nil
    header.diagnostics = []
    let headerDigest = try insertNestedPayload(try payloadJSON(header), ordinal: -1, rootId: rootId, invocationKey: invocationKey, role: role, in: db)
    var executionDigests: [JSONValue] = []
    for (ordinal, execution) in snapshot.session.executions.enumerated() {
      let digest = try insertNestedPayload(try payloadJSON(execution), ordinal: ordinal, rootId: rootId, invocationKey: invocationKey, role: role, in: db)
      executionDigests.append(.string(digest))
    }
    var references: JSONObject = ["headerDigest": .string(headerDigest), "executionDigests": .array(executionDigests)]
    if let output = snapshot.rootOutput {
      let digest = try insertNestedPayload(try payloadJSON(output), ordinal: snapshot.session.executions.count, rootId: rootId, invocationKey: invocationKey, role: role, in: db)
      references["rootOutputDigest"] = .string(digest)
    }
    let diagnosticsDigest = try insertNestedPayload(try payloadJSON(snapshot.diagnostics), ordinal: snapshot.session.executions.count + 1, rootId: rootId, invocationKey: invocationKey, role: role, in: db)
    references["diagnosticsDigest"] = .string(diagnosticsDigest)
    if let workflow = snapshot.loopEvidence {
      references["loopEvidenceDigest"] = .string(try insertNestedPayload(try payloadJSON(workflow), ordinal: snapshot.session.executions.count + 2, rootId: rootId, invocationKey: invocationKey, role: role, in: db))
    }
    return references
  }

  func insertNestedPayload(
    _ payload: String,
    ordinal: Int,
    rootId: String,
    invocationKey: String,
    role: String,
    in db: SQLiteDatabase
  ) throws -> String {
    let digest = Self.sha256(payload)
    try db.execute(
      "INSERT OR IGNORE INTO workflow_runtime_payloads(root_session_id,digest,bytes,byte_count) VALUES(?,?,jsonb(?),?)",
      bindings: [.text(rootId), .text(digest), .text(payload), .int(Int64(payload.utf8.count))]
    )
    try db.execute(
      "INSERT INTO workflow_nested_invocation_refs(invocation_key,role,ordinal,root_session_id,digest) VALUES(?,?,?,?,?)",
      bindings: [.text(invocationKey), .text(role), .int(Int64(ordinal)), .text(rootId), .text(digest)]
    )
    return digest
  }

  func observeWrite(headerJSON: String, executions: [WorkflowStepExecution], selected: [Int], statements: Int) {
    guard let persistenceWriteObserver else { return }
    let bytes = selected.reduce(headerJSON.utf8.count) { total, index in
      total + ((try? payloadJSON(executions[index]))?.utf8.count ?? 0)
    }
    persistenceWriteObserver(SQLiteWorkflowRuntimePersistenceStore.PersistenceWriteSample(boundBytes: bytes, statements: statements))
  }

  func payloadJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = RuntimeSnapshotDates.encoding
    encoder.outputFormatting = [.sortedKeys]
    return String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
  }

  static func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  func optionalText(_ value: SQLiteValue) -> String? {
    if case let .text(text) = value { return text }
    return nil
  }

  func snapshotColumnBindings(_ snapshot: WorkflowRuntimePersistenceSnapshot) throws -> [SQLiteValue] {
    let summary = try snapshot.loopEvidence.map {
      try jsonString(LoopSessionSummary.make(manifest: $0, loopMetadata: snapshot.loopMetadata))
    }
    return [
      .optionalText(try snapshot.rootOutput.map(jsonString)), .text(try jsonString(snapshot.diagnostics)),
      .optionalText(try snapshot.loopEvidence.map(jsonString)), .optionalText(summary),
      .text(Self.dateString(snapshot.session.createdAt)), .text(Self.dateString(snapshot.session.updatedAt))
    ]
  }

  func validateTaskTerminalWrite(
    _ snapshot: WorkflowRuntimePersistenceSnapshot,
    in db: SQLiteDatabase
  ) throws {
    guard try db.tableExists("work_attempts") else { return }
    let sessionId = snapshot.session.sessionId
    guard let attemptId = try db.query(
      "SELECT attempt_id FROM work_attempts WHERE session_id = ? LIMIT 1",
      bindings: [.text(sessionId)]
    ).first?["attempt_id"] else { return }
    let status = snapshot.session.status
    let isTerminal = status.isTerminal
    if isTerminal, try db.tableExists("work_cancellations") {
      let pending = try db.query(
        "SELECT c.attempt_id FROM work_cancellations c "
          + "LEFT JOIN work_decisions d ON d.decision_id = c.decision_id "
          + "WHERE c.attempt_id = ? AND c.acknowledged_at IS NULL "
          + "AND (d.kind IS NULL OR d.kind != 'handover' OR d.attempt_id != c.attempt_id) LIMIT 1",
        bindings: [.text(attemptId)]
      ).first != nil
      let pendingHandover = try db.query(
        "SELECT c.attempt_id FROM work_cancellations c "
          + "JOIN work_decisions d ON d.decision_id = c.decision_id "
          + "WHERE c.attempt_id = ? AND c.acknowledged_at IS NULL "
          + "AND d.kind = 'handover' AND d.attempt_id = c.attempt_id LIMIT 1",
        bindings: [.text(attemptId)]
      ).first != nil
      let allowedPendingTerminal = snapshot.session.isCancellation
        || (status == .failed && snapshot.session.failureKind == .stalled && pendingHandover)
      if (pending || pendingHandover) && !allowedPendingTerminal {
        throw WorkflowRuntimePersistenceStoreError.cancellationPending(sessionId)
      }
    }
    guard let existing = try db.query(
      "SELECT session_status, updated_at, json_extract(session_json, '$.failureKind') AS failure_kind "
        + "FROM workflow_runtime_snapshots WHERE workflow_execution_id = ? LIMIT 1",
      bindings: [.text(sessionId)]
    ).first, let previousStatus = existing["session_status"] else { return }
    if previousStatus == WorkflowSessionStatus.completed.rawValue
      || previousStatus == WorkflowSessionStatus.failed.rawValue
      || previousStatus == WorkflowSessionStatus.cancelled.rawValue {
      let sameTerminal = isTerminal && status.rawValue == previousStatus
        && snapshot.session.failureKind?.rawValue == existing["failure_kind"]
      let notOlder = (existing["updated_at"] ?? "") <= Self.dateString(snapshot.session.updatedAt)
      if !sameTerminal || !notOlder {
        throw WorkflowRuntimePersistenceStoreError.terminalSnapshotConflict(sessionId)
      }
    }
  }

  func snapshot(from row: SQLiteRow, db: SQLiteDatabase) throws -> WorkflowRuntimePersistenceSnapshot {
    guard let sessionText = row["session_json"], let diagnosticsText = row["diagnostics_json"],
          let sessionData = sessionText.data(using: .utf8), let diagnosticsData = diagnosticsText.data(using: .utf8) else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("runtime snapshot row is missing required fields")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = RuntimeSnapshotDates.decoding
    let session = try decoder.decode(WorkflowSession.self, from: assembledSessionData(from: sessionData, db: db))
    let diagnostics = try decoder.decode([String].self, from: diagnosticsData)
    let rootOutput = try row["root_output_json"].flatMap { $0.data(using: .utf8) }.map { try decoder.decode(JSONObject.self, from: $0) }
    let loopEvidence = try row["loop_evidence_json"].flatMap { $0.data(using: .utf8) }.map { try decoder.decode(LoopEvidenceManifest.self, from: $0) }
    let messages = try SQLiteWorkflowMessageLog(databasePath: Self.defaultDatabasePath(rootDirectory: rootDirectory))
      .listMessages(workflowExecutionId: session.sessionId, in: db)
    return WorkflowRuntimePersistenceSnapshot(
      session: session, workflowMessages: messages, rootOutput: rootOutput,
      diagnostics: diagnostics, loopEvidence: loopEvidence
    )
  }

  func assembledSessionData(from headerData: Data, db: SQLiteDatabase) throws -> Data {
    var object = try JSONDecoder().decode(JSONObject.self, from: headerData)
    guard object[Self.executionStorageMarkerKey] == .string("rows") else { return headerData }
    guard case let .string(id)? = object["sessionId"] else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("runtime snapshot header has no session id")
    }
    let rows = try db.query(
      """
      SELECT json(p.bytes) AS execution_json
      FROM workflow_runtime_executions AS e
      JOIN workflow_runtime_payloads AS p
        ON p.root_session_id = e.root_session_id AND p.digest = e.payload_digest
      WHERE e.workflow_execution_id = ?
      ORDER BY e.ordinal
      """,
      bindings: [.text(id)]
    )
    let executions: [JSONValue] = try rows.map { row in
      guard let value = row["execution_json"], let data = value.data(using: .utf8) else {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed("runtime execution payload is missing")
      }
      return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    object.removeValue(forKey: Self.executionStorageMarkerKey)
    object["executions"] = .array(executions)
    return try JSONEncoder().encode(object)
  }

  func summaryColumnOverview(from row: SQLiteRow) throws -> LoopSessionOverview? {
    guard let sessionId = row["workflow_execution_id"], let workflowId = row["workflow_id"],
          let sessionStatus = row["session_status"], let createdAtText = row["created_at"],
          let createdAt = Self.date(from: createdAtText), let updatedAtText = row["updated_at"],
          let updatedAt = Self.date(from: updatedAtText) else {
      return nil
    }
    let summary: LoopSessionSummary?
    if let summaryText = row["loop_summary_json"], let data = summaryText.data(using: .utf8) {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = RuntimeSnapshotDates.decoding
      summary = try decoder.decode(LoopSessionSummary.self, from: data)
    } else {
      summary = nil
    }
    return LoopSessionOverview.make(
      workflowId: workflowId, sessionId: sessionId, sessionStatus: sessionStatus,
      createdAt: createdAt, updatedAt: updatedAt, summary: summary
    )
  }

  public func executionIdentities(sessionId: String) throws -> [String] {
    guard isSafeId(sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(sessionId)
    }
    let db = try openDatabase(readOnly: true)
    guard try runtimeSnapshotTableExists(db) else { return [] }
    if try db.tableExists("workflow_runtime_executions") {
      let rows = try db.query(
        "SELECT execution_id FROM workflow_runtime_executions WHERE workflow_execution_id = ? ORDER BY ordinal",
        bindings: [.text(sessionId)]
      )
      let marker = try db.query(
        "SELECT json_type(session_json, '$." + Self.executionStorageMarkerKey + "') AS marker FROM workflow_runtime_snapshots WHERE workflow_execution_id = ?",
        bindings: [.text(sessionId)]
      ).first?["marker"]
      if !rows.isEmpty || marker == "text" {
        return rows.compactMap { $0["execution_id"] }
      }
    }
    let rows = try db.query(
      "SELECT json_extract(value, '$.executionId') AS execution_id FROM workflow_runtime_snapshots, json_each(session_json, '$.executions') WHERE workflow_execution_id = ? ORDER BY CAST(key AS INTEGER)",
      bindings: [.text(sessionId)]
    )
    return rows.compactMap { $0["execution_id"] }
  }

  public func legacyInlineSessionIds(limit: Int) throws -> [String] {
    guard FileManager.default.fileExists(atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)) else { return [] }
    let db = try openDatabase(readOnly: true)
    guard try runtimeSnapshotTableExists(db) else { return [] }
    return try db.query(
      "SELECT workflow_execution_id FROM workflow_runtime_snapshots "
        + "WHERE json_type(session_json, '$.executions') = 'array' "
        + "AND json_type(session_json, '$." + Self.executionStorageMarkerKey + "') IS NULL "
        + "ORDER BY created_at LIMIT ?",
      bindings: [.int(Int64(max(0, limit)))]
    ).compactMap { $0["workflow_execution_id"] }
  }

  public func convertLegacySession(sessionId: String) throws -> Bool {
    guard isSafeId(sessionId) else {
      throw WorkflowRuntimePersistenceStoreError.invalidSessionId(sessionId)
    }
    guard FileManager.default.fileExists(atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)) else {
      return false
    }
    let read = try openDatabase(readOnly: true)
    guard let row = try read.query(
      "SELECT json_type(session_json, '$.executions') AS executions_type, json_type(session_json, '$.\(Self.executionStorageMarkerKey)') AS marker FROM workflow_runtime_snapshots WHERE workflow_execution_id=?",
      bindings: [.text(sessionId)]
    ).first, row["executions_type"] == "array", row["marker"] == nil else {
      return false
    }
    let snapshot = try load(sessionId: sessionId)
    let db = try openDatabase()
    try prepareSchema(in: db)
    try db.transaction { try upsertSnapshot($0, snapshot) }
    return true
  }

  public func legacyEmbeddedNestedInvocationKeys(limit: Int) throws -> [String] {
    guard FileManager.default.fileExists(atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)) else { return [] }
    let db = try openDatabase(readOnly: true)
    guard try db.tableExists("workflow_nested_invocations") else { return [] }
    return try db.query(
      "SELECT invocation_key FROM workflow_nested_invocations WHERE json_type(reservation_json, '$.childSnapshotStorage') IS NULL ORDER BY created_at LIMIT ?",
      bindings: [.int(Int64(max(0, limit)))]
    ).compactMap { $0["invocation_key"] }
  }

  public func convertLegacyNestedInvocation(invocationKey: String) throws -> Bool {
    guard isSafeId(invocationKey),
          FileManager.default.fileExists(atPath: Self.defaultDatabasePath(rootDirectory: rootDirectory)) else {
      return false
    }
    let db = try openDatabase()
    try prepareSchema(in: db)
    return try db.transaction { database in
      guard try database.query(
        "SELECT json_type(reservation_json, '$.childSnapshotStorage') AS marker FROM workflow_nested_invocations WHERE invocation_key=?",
        bindings: [.text(invocationKey)]
      ).first? ["marker"] == nil,
      let record = try nestedInvocationRecord(key: invocationKey, in: database) else { return false }
      let reservation = try encodedReservation(record.reservation, key: invocationKey, in: database)
      let terminal = try record.childTerminalSnapshot.map {
        try encodedNestedSnapshot($0, key: invocationKey, role: "terminal", in: database)
      }
      try database.execute(
        "UPDATE workflow_nested_invocations SET reservation_json=jsonb(?), child_terminal_json=CASE WHEN ? IS NULL THEN NULL ELSE jsonb(?) END WHERE invocation_key=?",
        bindings: [.text(reservation), .optionalText(terminal), .optionalText(terminal), .text(invocationKey)]
      )
      return true
    }
  }

  @discardableResult
  public func releaseUnreferencedPayloads(rootSessionId: String) throws -> Int64 {
    let db = try openDatabase()
    try prepareSchema(in: db)
    return try db.transaction { try releaseUnreferencedPayloads(rootSessionId: rootSessionId, in: $0) }
  }

  func jsonString<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = RuntimeSnapshotDates.encoding
    return String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
  }
}
