import Foundation
import RielaSQLite

/// Managed lifecycle state of a routine. SQLite is the source of truth: the
/// event-serve cron gate consults it before every dispatch, so completing or
/// disabling a routine takes effect without restarting the serve loop.
public enum RoutineStatus: String, Codable, CaseIterable, Sendable {
  case active
  case disabled
  case completed
}

public struct RoutineRecord: Codable, Equatable, Sendable {
  public var routineId: String
  public var name: String
  /// The original natural-language instruction (e.g. the chat message) the
  /// routine was created from, kept for audit and re-parsing.
  public var instruction: String?
  /// What to do on every tick; injected into the target workflow input.
  public var task: String
  /// Six-field cron expression (sec min hour dom month dow).
  public var schedule: String
  public var timezone: String?
  /// Workflow run on every tick.
  public var workflowName: String
  /// Natural-language completion condition; when a run judges it met the
  /// routine transitions to `completed`.
  public var completionCriteria: String?
  public var status: RoutineStatus
  public var createdAt: String
  public var updatedAt: String
  public var completedAt: String?
  public var completionNote: String?
  public var lastRunAt: String?
  public var runCount: Int
  /// Event root holding the routine's cron source/binding JSON files.
  public var eventRoot: String
  public var sourceId: String
  public var bindingId: String
  /// When true, completing the routine also deactivates `workflowName` in the
  /// workflow registry (safe only for workflows dedicated to this routine).
  public var deactivateWorkflowOnCompletion: Bool
  /// Where the routine came from (chat provider, conversation, actor…).
  public var origin: JSONObject?

  public init(
    routineId: String,
    name: String,
    instruction: String? = nil,
    task: String,
    schedule: String,
    timezone: String? = nil,
    workflowName: String,
    completionCriteria: String? = nil,
    status: RoutineStatus = .active,
    createdAt: String,
    updatedAt: String,
    completedAt: String? = nil,
    completionNote: String? = nil,
    lastRunAt: String? = nil,
    runCount: Int = 0,
    eventRoot: String,
    sourceId: String,
    bindingId: String,
    deactivateWorkflowOnCompletion: Bool = false,
    origin: JSONObject? = nil
  ) {
    self.routineId = routineId
    self.name = name
    self.instruction = instruction
    self.task = task
    self.schedule = schedule
    self.timezone = timezone
    self.workflowName = workflowName
    self.completionCriteria = completionCriteria
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.completedAt = completedAt
    self.completionNote = completionNote
    self.lastRunAt = lastRunAt
    self.runCount = runCount
    self.eventRoot = eventRoot
    self.sourceId = sourceId
    self.bindingId = bindingId
    self.deactivateWorkflowOnCompletion = deactivateWorkflowOnCompletion
    self.origin = origin
  }
}

public struct RoutineListFilter: Codable, Equatable, Sendable {
  public var status: RoutineStatus?
  public var workflowName: String?
  public var limit: Int?

  public init(status: RoutineStatus? = nil, workflowName: String? = nil, limit: Int? = nil) {
    self.status = status
    self.workflowName = workflowName
    self.limit = limit
  }
}

public struct RoutineStoreError: Error, Equatable, Sendable, CustomStringConvertible {
  public var message: String

  public init(_ message: String) {
    self.message = message
  }

  public var description: String { message }
}

/// SQLite-backed routine store. One database per root directory; connections
/// are opened per operation (WAL for writes, read-only opens for reads, a
/// missing database reads as empty).
public struct RoutineStore: Sendable {
  /// Routine records are not regenerable, so an older store without a
  /// registered migration path is a hard error rather than an auto-discard.
  /// When bumping, append an upgrade step to `schemaMigrations`.
  public static let schemaGeneration: Int64 = 1

  /// Ordered `from → from+1` upgrade steps applied in place when an older
  /// stamped store is opened. Append a `SQLiteSchemaMigration(fromGeneration:)`
  /// here for every future `schemaGeneration` bump.
  public static let schemaMigrations: [SQLiteSchemaMigration] = []
  public static let databaseFileName = "routines.sqlite"
  public static let rootDirectoryEnvironmentKey = "RIELA_ROUTINE_STORE"
  public static let maximumListLimit = 1_000

  public var rootDirectory: String

  public init(rootDirectory: String) {
    self.rootDirectory = rootDirectory
  }

  public static func defaultRootDirectory(workingDirectory: String) -> String {
    URL(fileURLWithPath: workingDirectory, isDirectory: true)
      .appendingPathComponent(".riela/routines", isDirectory: true)
      .path
  }

  public static func resolveRootDirectory(
    explicit: String?,
    workingDirectory: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String {
    if let explicit, !explicit.isEmpty {
      return absoluteRootDirectory(explicit, workingDirectory: workingDirectory)
    }
    if let fromEnvironment = environment[rootDirectoryEnvironmentKey], !fromEnvironment.isEmpty {
      return absoluteRootDirectory(fromEnvironment, workingDirectory: workingDirectory)
    }
    return defaultRootDirectory(workingDirectory: workingDirectory)
  }

  public var databasePath: String {
    URL(fileURLWithPath: rootDirectory, isDirectory: true)
      .appendingPathComponent(Self.databaseFileName)
      .path
  }

  public func save(_ record: RoutineRecord) throws {
    let db = try openWritable()
    let json = try recordJSONString(record)
    try db.execute(
      """
      INSERT INTO routines (routine_id, record_json, updated_at)
      VALUES (?, jsonb(?), ?)
      ON CONFLICT(routine_id) DO UPDATE SET
        record_json = excluded.record_json,
        updated_at = excluded.updated_at
      """,
      bindings: [.text(record.routineId), .text(json), .text(record.updatedAt)]
    )
  }

  public func load(routineId: String) throws -> RoutineRecord? {
    guard let db = try openReadOnlyIfPresent() else {
      return nil
    }
    let rows = try db.query(
      "SELECT json(record_json) AS record_json FROM routines WHERE routine_id = ?",
      bindings: [.text(routineId)]
    )
    guard let row = rows.first, let json = row["record_json"] else {
      return nil
    }
    return try decodeRecord(json)
  }

  public func list(filter: RoutineListFilter = RoutineListFilter()) throws -> [RoutineRecord] {
    if let limit = filter.limit, !(1...Self.maximumListLimit).contains(limit) {
      throw RoutineStoreError("routine list limit must be between 1 and \(Self.maximumListLimit)")
    }
    guard let db = try openReadOnlyIfPresent() else {
      return []
    }
    var sql = "SELECT json(record_json) AS record_json FROM routines"
    var clauses: [String] = []
    var bindings: [SQLiteValue] = []
    if let status = filter.status {
      clauses.append("status = ?")
      bindings.append(.text(status.rawValue))
    }
    if let workflowName = filter.workflowName {
      clauses.append("workflow_name = ?")
      bindings.append(.text(workflowName))
    }
    if !clauses.isEmpty {
      sql += " WHERE " + clauses.joined(separator: " AND ")
    }
    sql += " ORDER BY updated_at DESC, routine_id ASC"
    if let limit = filter.limit {
      sql += " LIMIT ?"
      bindings.append(.int(Int64(limit)))
    }
    return try db.query(sql, bindings: bindings).map { row in
      guard let json = row["record_json"] else {
        throw RoutineStoreError("routine store row is missing record_json")
      }
      return try decodeRecord(json)
    }
  }

  /// Applies `mutate` to the stored record inside one write transaction and
  /// returns the updated record. Throws when the routine does not exist.
  @discardableResult
  public func update(
    routineId: String,
    mutate: (inout RoutineRecord) -> Void
  ) throws -> RoutineRecord {
    let db = try openWritable()
    return try db.transaction { db in
      let rows = try db.query(
        "SELECT json(record_json) AS record_json FROM routines WHERE routine_id = ?",
        bindings: [.text(routineId)]
      )
      guard let row = rows.first, let json = row["record_json"] else {
        throw RoutineStoreError("routine '\(routineId)' was not found")
      }
      var record = try decodeRecord(json)
      mutate(&record)
      record.updatedAt = Self.timestamp()
      try db.execute(
        "UPDATE routines SET record_json = jsonb(?), updated_at = ? WHERE routine_id = ?",
        bindings: [.text(try recordJSONString(record)), .text(record.updatedAt), .text(routineId)]
      )
      return record
    }
  }

  @discardableResult
  public func recordRunCompletion(routineId: String, at date: Date = Date()) throws -> RoutineRecord {
    try update(routineId: routineId) { record in
      record.lastRunAt = Self.timestamp(date)
      record.runCount += 1
    }
  }

  @discardableResult
  public func delete(routineId: String) throws -> Bool {
    guard FileManager.default.fileExists(atPath: databasePath) else {
      return false
    }
    let db = try openWritable()
    let changed = try db.executeAndReturnChangedRowCount(
      "DELETE FROM routines WHERE routine_id = ?",
      bindings: [.text(routineId)]
    )
    return changed > 0
  }

  public static func timestamp(_ date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private func openWritable() throws -> SQLiteDatabase {
    let db = try SQLiteDatabase.open(path: databasePath, mode: .readWriteCreate, options: .writableDefault)
    try ensureSchema(db)
    return db
  }

  private func openReadOnlyIfPresent() throws -> SQLiteDatabase? {
    guard FileManager.default.fileExists(atPath: databasePath) else {
      return nil
    }
    let db = try SQLiteDatabase.open(path: databasePath, mode: .readOnly, options: .readOnlyDefault)
    do {
      try requireCompatibleGeneration(db, mode: .verify)
      return db
    } catch is SQLiteSchemaMigrator.MigrationPendingError {
      // An older migratable store: migrate through a writable open, then
      // reopen read-only against the upgraded schema.
      _ = try openWritable()
      let migrated = try SQLiteDatabase.open(path: databasePath, mode: .readOnly, options: .readOnlyDefault)
      try requireCompatibleGeneration(migrated, mode: .verify)
      return migrated
    }
  }

  private func ensureSchema(_ db: SQLiteDatabase) throws {
    try requireCompatibleGeneration(db)
    try db.transaction { db in
      try db.execute(
        """
        CREATE TABLE IF NOT EXISTS routines (
          routine_id TEXT PRIMARY KEY,
          record_json BLOB NOT NULL CHECK (json_valid(record_json, 8)),
          name TEXT GENERATED ALWAYS AS (json_extract(record_json, '$.name')) STORED,
          status TEXT GENERATED ALWAYS AS (json_extract(record_json, '$.status')) STORED,
          workflow_name TEXT GENERATED ALWAYS AS (json_extract(record_json, '$.workflowName')) STORED,
          updated_at TEXT NOT NULL
        )
        """
      )
      try db.execute("CREATE INDEX IF NOT EXISTS idx_routines_status ON routines(status)")
      try db.execute("CREATE INDEX IF NOT EXISTS idx_routines_workflow_name ON routines(workflow_name)")
      try db.execute("PRAGMA user_version = \(Self.schemaGeneration)")
    }
  }

  private func requireCompatibleGeneration(
    _ db: SQLiteDatabase,
    mode: SQLiteSchemaMigrator.Mode = .migrate
  ) throws {
    do {
      try SQLiteSchemaMigrator.migrateIfNeeded(
        in: db,
        currentGeneration: Self.schemaGeneration,
        migrations: Self.schemaMigrations,
        preGenerationProbe: { try $0.tableExists("routines") },
        storeDescription: "routine store",
        mode: mode
      )
    } catch let error as SQLiteSchemaMigrator.NewerGenerationError {
      throw RoutineStoreError(
        "routine store at \(databasePath) uses schema generation \(error.stampedGeneration); this build supports \(Self.schemaGeneration)"
      )
    } catch let error as SQLiteSchemaMigrator.MissingMigrationPathError {
      throw RoutineStoreError(
        "routine store at \(databasePath) (schema generation \(error.stampedGeneration)) has no migration path to generation \(Self.schemaGeneration); move it aside and recreate routines"
      )
    }
  }

  private func recordJSONString(_ record: RoutineRecord) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(record)
    guard let json = String(data: data, encoding: .utf8) else {
      throw RoutineStoreError("routine record could not be encoded as UTF-8 JSON")
    }
    return json
  }

  private func decodeRecord(_ json: String) throws -> RoutineRecord {
    do {
      return try JSONDecoder().decode(RoutineRecord.self, from: Data(json.utf8))
    } catch {
      throw RoutineStoreError("routine store contains an invalid record: \(error)")
    }
  }

  private static func absoluteRootDirectory(_ path: String, workingDirectory: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
      return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }
    return URL(
      fileURLWithPath: expanded,
      relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true)
    ).standardizedFileURL.path
  }
}
