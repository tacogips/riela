import Foundation
import RielaSQLite

public struct BotStoreError: Error, Equatable, Sendable, CustomStringConvertible {
  public var code: String
  public var message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }

  public var description: String { "\(code): \(message)" }
}

public struct BotSessionLink: Codable, Equatable, Sendable {
  public var sessionId: String
  public var botId: String
  public var source: String
  public var sourceRef: String?
  public var linkedAt: String

  public init(sessionId: String, botId: String, source: String, sourceRef: String?, linkedAt: String) {
    self.sessionId = sessionId
    self.botId = botId
    self.source = source
    self.sourceRef = sourceRef
    self.linkedAt = linkedAt
  }
}

public struct BotStore: Sendable {
  public var sessionStoreRoot: String

  public init(sessionStoreRoot: String) {
    self.sessionStoreRoot = sessionStoreRoot
  }

  public var databasePath: String {
    SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: sessionStoreRoot)
  }

  /// A missing database or a store that predates bot tables reads as empty.
  public func read<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T? {
    let path = databasePath
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let database = try RuntimeDatabaseAccess.withSchemaLockIfUninitialized(
      rootDirectory: sessionStoreRoot, databasePath: path
    ) {
      try SQLiteDatabase.open(path: path, mode: .strictReadOnly, options: .readOnlyDefault)
    }
    guard try database.tableExists("bots") else { return nil }
    return try body(database)
  }

  public func write<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
    let database = try RuntimeDatabaseAccess.withSchemaLock(rootDirectory: sessionStoreRoot) {
      let database = try SQLiteDatabase.open(path: databasePath, options: .writableRuntimeStoreDefault)
      try BotStoreSchema.prepare(in: database)
      try AskStoreSchema.prepare(in: database)
      return database
    }
    return try database.transaction(body)
  }

  @discardableResult
  public func create(_ record: BotRecord) throws -> BotRecord {
    try BotRecord.validate(record)
    return try write { database in
      guard try Self.load(botId: record.botId, in: database) == nil else {
        throw BotStoreError(code: "bot_exists", message: "Bot '\(record.botId)' already exists")
      }
      try database.execute(
        "INSERT INTO bots (bot_id, record_json, updated_at) VALUES (?, jsonb(?), ?)",
        bindings: [.text(record.botId), .text(try Self.recordJSON(record)), .text(record.updatedAt)]
      )
      return record
    }
  }

  public func load(botId: String) throws -> BotRecord? {
    try read { try Self.load(botId: botId, in: $0) } ?? nil
  }

  public func list() throws -> [BotRecord] {
    try read { database in
      try database.query("SELECT json(record_json) AS record_json FROM bots ORDER BY bot_id")
        .map(Self.decodeRecord)
    } ?? []
  }

  @discardableResult
  public func update(botId: String, _ mutate: (inout BotRecord) throws -> Void) throws -> BotRecord {
    try write { database in
      guard var record = try Self.load(botId: botId, in: database) else {
        throw Self.notFound(botId)
      }
      try mutate(&record)
      guard record.botId == botId else {
        throw BotStoreError(code: "bot_invalid", message: "Bot id cannot be changed")
      }
      try BotRecord.validate(record)
      record.updatedAt = RoutineStore.timestamp()
      try database.execute(
        "UPDATE bots SET record_json = jsonb(?), updated_at = ? WHERE bot_id = ?",
        bindings: [.text(try Self.recordJSON(record)), .text(record.updatedAt), .text(botId)]
      )
      return record
    }
  }

  @discardableResult
  public func setPaused(botId: String, paused: Bool) throws -> BotRecord {
    try update(botId: botId) { $0.paused = paused }
  }

  public func remove(botId: String) throws {
    try write { database in
      guard try Self.load(botId: botId, in: database) != nil else {
        throw Self.notFound(botId)
      }
      let pending = try database.query(
        """
        SELECT 1 FROM bot_session_links AS links
        JOIN activity_requests AS requests ON requests.session_id = links.session_id
        WHERE links.bot_id = ? AND requests.status = 'pending'
        LIMIT 1
        """,
        bindings: [.text(botId)]
      )
      guard pending.isEmpty else {
        throw BotStoreError(code: "bot_busy", message: "Bot '\(botId)' has a pending permission request")
      }
      for table in ["bot_session_links", "bot_list_state", "bot_suggestions", "bot_job_runs", "bots"] {
        try database.execute("DELETE FROM \(table) WHERE bot_id = ?", bindings: [.text(botId)])
      }
    }
  }

  public func linkSession(
    sessionId: String, botId: String, source: String, sourceRef: String? = nil, at: Date
  ) throws {
    try write { database in
      guard try Self.load(botId: botId, in: database) != nil else {
        throw Self.notFound(botId)
      }
      if let link = try Self.link(forSession: sessionId, in: database) {
        guard link.botId == botId else {
          throw BotStoreError(code: "bot_link_conflict", message: "Session '\(sessionId)' is already linked to bot '\(link.botId)'")
        }
        return
      }
      guard ["run", "routine", "job"].contains(source) else {
        throw BotStoreError(code: "bot_invalid", message: "Unknown bot session link source '\(source)'")
      }
      try database.execute(
        "INSERT INTO bot_session_links (session_id, bot_id, source, source_ref, linked_at) VALUES (?, ?, ?, ?, ?)",
        bindings: [.text(sessionId), .text(botId), .text(source), sourceRef.map(SQLiteValue.text) ?? .null, .text(RoutineStore.timestamp(at))]
      )
    }
  }

  public func link(forSession sessionId: String) throws -> BotSessionLink? {
    try read { try Self.link(forSession: sessionId, in: $0) } ?? nil
  }

  public func links(botId: String) throws -> [BotSessionLink] {
    try read { database in
      try database.query(
        "SELECT * FROM bot_session_links WHERE bot_id = ? ORDER BY linked_at DESC, session_id ASC",
        bindings: [.text(botId)]
      ).map(Self.decodeLink)
    } ?? []
  }

  private static func load(botId: String, in db: SQLiteDatabase) throws -> BotRecord? {
    try db.query(
      "SELECT json(record_json) AS record_json FROM bots WHERE bot_id = ?", bindings: [.text(botId)]
    ).first.map(decodeRecord)
  }

  private static func link(forSession sessionId: String, in db: SQLiteDatabase) throws -> BotSessionLink? {
    try db.query(
      "SELECT * FROM bot_session_links WHERE session_id = ?", bindings: [.text(sessionId)]
    ).first.map(decodeLink)
  }

  private static func decodeRecord(_ row: SQLiteRow) throws -> BotRecord {
    guard let json = row["record_json"] else {
      throw BotStoreError(code: "bot_invalid", message: "Bot record is missing its JSON")
    }
    return try JSONDecoder().decode(BotRecord.self, from: Data(json.utf8))
  }

  private static func decodeLink(_ row: SQLiteRow) throws -> BotSessionLink {
    guard let sessionId = row["session_id"], let botId = row["bot_id"],
      let source = row["source"], let linkedAt = row["linked_at"]
    else {
      throw BotStoreError(code: "bot_invalid", message: "Bot session link is missing a required field")
    }
    return BotSessionLink(sessionId: sessionId, botId: botId, source: source, sourceRef: row["source_ref"], linkedAt: linkedAt)
  }

  private static func recordJSON(_ record: BotRecord) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let json = String(data: try encoder.encode(record), encoding: .utf8) else {
      throw BotStoreError(code: "bot_invalid", message: "Bot record could not be encoded as UTF-8 JSON")
    }
    return json
  }

  private static func notFound(_ botId: String) -> BotStoreError {
    BotStoreError(code: "bot_not_found", message: "Bot '\(botId)' was not found")
  }
}
