import Foundation
import RielaCore
import RielaSQLite

public struct WorkStoreError: Error, Equatable, Sendable, CustomStringConvertible {
  public var message: String
  /// Set when an optimistic-concurrency update lost the race.
  public var isVersionConflict: Bool

  public init(_ message: String, isVersionConflict: Bool = false) {
    self.message = message
    self.isVersionConflict = isVersionConflict
  }

  public var description: String { message }

  static func versionConflict(taskId: TaskID, expected: Int) -> WorkStoreError {
    WorkStoreError(
      "task '\(taskId.rawValue)' was not at version \(expected); reload it and retry",
      isVersionConflict: true
    )
  }
}

/// Filter for `WorkStore.listTasks`, shaped like `RoutineListFilter`.
public struct TaskListFilter: Equatable, Sendable {
  public var state: TaskState?
  public var intentId: IntentID?
  public var workflowId: String?
  public var limit: Int?

  public init(
    state: TaskState? = nil,
    intentId: IntentID? = nil,
    workflowId: String? = nil,
    limit: Int? = nil
  ) {
    self.state = state
    self.intentId = intentId
    self.workflowId = workflowId
    self.limit = limit
  }
}

/// SQLite-backed Work Runtime store.
///
/// It shares the runtime records database with
/// `SQLiteWorkflowRuntimePersistenceStore` (design section 11), opens a
/// connection per operation, reads a missing database as empty, and discards
/// a store whose schema generation has no migration path — there is no
/// migration, by decision.
public struct WorkStore: Sendable {
  public static let maximumListLimit = 1_000

  public var rootDirectory: String

  public init(rootDirectory: String) {
    self.rootDirectory = rootDirectory
  }

  public var databasePath: String {
    SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: rootDirectory)
  }

  // MARK: - Intents

  public func saveIntent(_ intent: Intent) throws {
    let db = try openWritable()
    try db.execute(
      """
      INSERT INTO work_intents (intent_id, record, created_at)
      VALUES (?, jsonb(?), ?)
      ON CONFLICT(intent_id) DO UPDATE SET record = excluded.record
      """,
      bindings: [.text(intent.id.rawValue), .text(try encode(intent)), .text(Self.timestamp())]
    )
  }

  public func loadIntent(id: IntentID) throws -> Intent? {
    try loadRecord(Intent.self, table: "work_intents", column: "intent_id", value: id.rawValue)
  }

  public func listIntents(state: IntentState? = nil, limit: Int? = nil) throws -> [Intent] {
    try validate(limit: limit, label: "intent list")
    guard let db = try openReadOnlyIfPresent() else {
      return []
    }
    var sql = "SELECT json(record) AS record FROM work_intents"
    var bindings: [SQLiteValue] = []
    if let state {
      sql += " WHERE state = ?"
      bindings.append(.text(state.rawValue))
    }
    sql += " ORDER BY created_at DESC, intent_id ASC"
    if let limit {
      sql += " LIMIT ?"
      bindings.append(.int(Int64(limit)))
    }
    return try decodeRows(Intent.self, from: db.query(sql, bindings: bindings))
  }

  // MARK: - Tasks

  /// Inserts a task, or replaces it wholesale. Lifecycle transitions go
  /// through `updateTask(_:expectedVersion:)` so two writers cannot both
  /// advance one task.
  public func saveTask(_ task: WorkTask) throws {
    let db = try openWritable()
    try db.execute(
      """
      INSERT INTO work_tasks (task_id, record, updated_at)
      VALUES (?, jsonb(?), ?)
      ON CONFLICT(task_id) DO UPDATE SET
        record = excluded.record,
        updated_at = excluded.updated_at
      """,
      bindings: [.text(task.id.rawValue), .text(try encode(task)), .text(Self.timestamp())]
    )
  }

  public func loadTask(id: TaskID) throws -> WorkTask? {
    try loadRecord(WorkTask.self, table: "work_tasks", column: "task_id", value: id.rawValue)
  }

  /// Optimistic concurrency on `work_tasks.version`, as
  /// `SpecialistSupervisorStore.claim` does today: the update only lands when
  /// the stored row is still at `expectedVersion`, and the returned record
  /// carries `expectedVersion + 1`.
  @discardableResult
  public func updateTask(_ task: WorkTask, expectedVersion: Int) throws -> WorkTask {
    var updated = task
    updated.version = expectedVersion + 1
    let db = try openWritable()
    let changed = try db.executeAndReturnChangedRowCount(
      "UPDATE work_tasks SET record = jsonb(?), updated_at = ? WHERE task_id = ? AND version = ?",
      bindings: [
        .text(try encode(updated)),
        .text(Self.timestamp()),
        .text(updated.id.rawValue),
        .int(Int64(expectedVersion))
      ]
    )
    guard changed > 0 else {
      throw WorkStoreError.versionConflict(taskId: updated.id, expected: expectedVersion)
    }
    return updated
  }

  public func listTasks(filter: TaskListFilter = TaskListFilter()) throws -> [WorkTask] {
    try validate(limit: filter.limit, label: "task list")
    guard let db = try openReadOnlyIfPresent() else {
      return []
    }
    var clauses: [String] = []
    var bindings: [SQLiteValue] = []
    if let state = filter.state {
      clauses.append("state = ?")
      bindings.append(.text(state.rawValue))
    }
    if let intentId = filter.intentId {
      clauses.append("intent_id = ?")
      bindings.append(.text(intentId.rawValue))
    }
    if let workflowId = filter.workflowId {
      clauses.append("workflow_id = ?")
      bindings.append(.text(workflowId))
    }
    var sql = "SELECT json(record) AS record FROM work_tasks"
    if !clauses.isEmpty {
      sql += " WHERE " + clauses.joined(separator: " AND ")
    }
    sql += " ORDER BY updated_at DESC, task_id ASC"
    if let limit = filter.limit {
      sql += " LIMIT ?"
      bindings.append(.int(Int64(limit)))
    }
    return try decodeRows(WorkTask.self, from: db.query(sql, bindings: bindings))
  }

  // MARK: - Attempts

  public func saveAttempt(_ attempt: Attempt) throws {
    let db = try openWritable()
    try db.execute(
      """
      INSERT INTO work_attempts (attempt_id, record, created_at)
      VALUES (?, jsonb(?), ?)
      ON CONFLICT(attempt_id) DO UPDATE SET record = excluded.record
      """,
      bindings: [.text(attempt.id.rawValue), .text(try encode(attempt)), .text(Self.timestamp())]
    )
  }

  public func loadAttempt(id: AttemptID) throws -> Attempt? {
    try loadRecord(Attempt.self, table: "work_attempts", column: "attempt_id", value: id.rawValue)
  }

  public func loadAttempt(sessionId: String) throws -> Attempt? {
    try loadRecord(Attempt.self, table: "work_attempts", column: "session_id", value: sessionId)
  }

  public func listAttempts(taskId: TaskID) throws -> [Attempt] {
    guard let db = try openReadOnlyIfPresent() else {
      return []
    }
    return try decodeRows(Attempt.self, from: db.query(
      "SELECT json(record) AS record FROM work_attempts WHERE task_id = ? ORDER BY created_at ASC, attempt_id ASC",
      bindings: [.text(taskId.rawValue)]
    ))
  }

  // MARK: - Decisions

  public func saveDecision(_ decision: Decision) throws {
    let db = try openWritable()
    try db.execute(
      """
      INSERT INTO work_decisions (decision_id, record, created_at)
      VALUES (?, jsonb(?), ?)
      ON CONFLICT(decision_id) DO UPDATE SET record = excluded.record
      """,
      bindings: [
        .text(decision.id.rawValue),
        .text(try encode(decision)),
        .text(Self.timestamp(decision.createdAt))
      ]
    )
  }

  public func listDecisions(taskId: TaskID) throws -> [Decision] {
    guard let db = try openReadOnlyIfPresent() else {
      return []
    }
    return try decodeRows(Decision.self, from: db.query(
      "SELECT json(record) AS record FROM work_decisions WHERE task_id = ? ORDER BY created_at ASC, decision_id ASC",
      bindings: [.text(taskId.rawValue)]
    ))
  }

  // MARK: - Evidence

  public func saveEvidence(_ evidence: Evidence) throws {
    try saveEvidence([evidence])
  }

  /// Writes a whole projection pass in one transaction: a half-written ledger
  /// would make the completion check read a state no attempt ever had.
  public func saveEvidence(_ records: [Evidence]) throws {
    guard !records.isEmpty else {
      return
    }
    let db = try openWritable()
    try db.transaction { db in
      for record in records {
        try db.execute(
          """
          INSERT INTO work_evidence (evidence_id, record, created_at)
          VALUES (?, jsonb(?), ?)
          ON CONFLICT(evidence_id) DO UPDATE SET record = excluded.record
          """,
          bindings: [
            .text(record.id.rawValue),
            .text(try encode(record)),
            .text(Self.timestamp(record.createdAt))
          ]
        )
      }
    }
  }

  public func listEvidence(taskId: TaskID, kind: EvidenceKind? = nil) throws -> [Evidence] {
    guard let db = try openReadOnlyIfPresent() else {
      return []
    }
    var sql = "SELECT json(record) AS record FROM work_evidence WHERE task_id = ?"
    var bindings: [SQLiteValue] = [.text(taskId.rawValue)]
    if let kind {
      sql += " AND kind = ?"
      bindings.append(.text(kind.rawValue))
    }
    sql += " ORDER BY created_at ASC, evidence_id ASC"
    return try decodeRows(Evidence.self, from: db.query(sql, bindings: bindings))
  }

  // MARK: - Findings

  public func saveFindings(_ findings: [Finding], taskId: TaskID) throws {
    guard !findings.isEmpty else {
      return
    }
    let db = try openWritable()
    try db.transaction { db in
      for finding in findings {
        try db.execute(
          """
          INSERT INTO work_findings (task_id, fingerprint, record)
          VALUES (?, ?, jsonb(?))
          ON CONFLICT(task_id, fingerprint) DO UPDATE SET record = excluded.record
          """,
          bindings: [
            .text(taskId.rawValue),
            .text(finding.fingerprint.key),
            .text(try encode(finding))
          ]
        )
      }
    }
  }

  public func listFindings(taskId: TaskID, status: FindingStatus? = nil) throws -> [Finding] {
    guard let db = try openReadOnlyIfPresent() else {
      return []
    }
    var sql = "SELECT json(record) AS record FROM work_findings WHERE task_id = ?"
    var bindings: [SQLiteValue] = [.text(taskId.rawValue)]
    if let status {
      sql += " AND status = ?"
      bindings.append(.text(status.rawValue))
    }
    sql += " ORDER BY fingerprint ASC"
    return try decodeRows(Finding.self, from: db.query(sql, bindings: bindings))
  }

  // MARK: - Connections

  public static func timestamp(_ date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private func openWritable() throws -> SQLiteDatabase {
    try createRootDirectoryIfNeeded()
    // Session stores hold regenerable run history, so a generation without a
    // migration path is discarded and recreated rather than hard-failing.
    SQLiteWorkflowRuntimePersistenceStore.discardIncompatibleStoreIfNeeded(databasePath: databasePath)
    let db = try mapSQLiteError {
      try SQLiteDatabase.open(path: databasePath, mode: .readWriteCreate, options: .writableDefault)
    }
    try mapSQLiteError {
      try Self.prepareSchema(in: db)
    }
    return db
  }

  private func openReadOnlyIfPresent() throws -> SQLiteDatabase? {
    guard FileManager.default.fileExists(atPath: databasePath) else {
      return nil
    }
    let db = try mapSQLiteError {
      try SQLiteDatabase.open(path: databasePath, mode: .readOnly, options: .readOnlyDefault)
    }
    // A database written before the Work Runtime existed has no work_* tables;
    // a read of it is empty, not an error, and the next writable open rebuilds
    // it under the current generation.
    guard try mapSQLiteError({ try db.tableExists("work_tasks") }) else {
      return nil
    }
    return db
  }

  private func createRootDirectoryIfNeeded() throws {
    let directory = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  private func loadRecord<T: Decodable>(
    _ type: T.Type,
    table: String,
    column: String,
    value: String
  ) throws -> T? {
    guard let db = try openReadOnlyIfPresent() else {
      return nil
    }
    let rows = try db.query(
      "SELECT json(record) AS record FROM \(table) WHERE \(column) = ?",
      bindings: [.text(value)]
    )
    return try decodeRows(type, from: rows).first
  }

  private func decodeRows<T: Decodable>(_ type: T.Type, from rows: [SQLiteRow]) throws -> [T] {
    try rows.map { row in
      guard let json = row["record"] else {
        throw WorkStoreError("work store row is missing its record column")
      }
      do {
        return try Self.decoder.decode(type, from: Data(json.utf8))
      } catch {
        throw WorkStoreError("work store contains an invalid \(type) record: \(error)")
      }
    }
  }

  private func validate(limit: Int?, label: String) throws {
    guard let limit else {
      return
    }
    guard (1...Self.maximumListLimit).contains(limit) else {
      throw WorkStoreError("\(label) limit must be between 1 and \(Self.maximumListLimit)")
    }
  }

  private func encode<T: Encodable>(_ value: T) throws -> String {
    let data: Data
    do {
      data = try Self.encoder.encode(value)
    } catch {
      throw WorkStoreError("work record could not be encoded as JSON: \(error)")
    }
    guard let json = String(bytes: data, encoding: .utf8) else {
      throw WorkStoreError("work record could not be encoded as UTF-8 JSON")
    }
    return json
  }

  private func mapSQLiteError<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as SQLiteError {
      throw WorkStoreError("work store sqlite failure: \(error)")
    }
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
