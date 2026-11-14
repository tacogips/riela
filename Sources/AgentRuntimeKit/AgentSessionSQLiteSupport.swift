import Foundation
import RielaSQLite

public struct AgentSessionSQLiteGit: Equatable, Sendable {
  public var sha: String?
  public var branch: String?
  public var originURL: String?

  public init(sha: String? = nil, branch: String? = nil, originURL: String? = nil) {
    self.sha = sha
    self.branch = branch
    self.originURL = originURL
  }
}

public struct AgentSessionSQLiteRecord: Equatable, Sendable {
  public var id: String
  public var rolloutPath: String
  public var createdAt: Date
  public var updatedAt: Date
  public var source: String
  public var modelProvider: String?
  public var cwd: String
  public var cliVersion: String
  public var title: String
  public var firstUserMessage: String?
  public var archivedAt: Date?
  public var git: AgentSessionSQLiteGit?

  public init?(_ row: [String: String]) {
    guard
      let id = AgentSessionSQLiteSupport.nonEmpty(row["id"]),
      let rolloutPath = AgentSessionSQLiteSupport.nonEmpty(row["rollout_path"]),
      let createdAt = AgentSessionSQLiteSupport
        .nonEmpty(row["created_at"])
        .flatMap(AgentSessionSQLiteSupport.sqliteDate),
      let updatedAt = AgentSessionSQLiteSupport
        .nonEmpty(row["updated_at"])
        .flatMap(AgentSessionSQLiteSupport.sqliteDate),
      let cwd = AgentSessionSQLiteSupport.nonEmpty(row["cwd"])
    else {
      return nil
    }
    self.id = id
    self.rolloutPath = rolloutPath
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    source = row["source"] ?? ""
    modelProvider = AgentSessionSQLiteSupport.nonEmpty(row["model_provider"])
    self.cwd = cwd
    cliVersion = AgentSessionSQLiteSupport.nonEmpty(row["cli_version"]) ?? "unknown"
    title = AgentSessionSQLiteSupport.nonEmpty(row["title"])
      ?? AgentSessionSQLiteSupport.nonEmpty(row["first_user_message"])
      ?? id
    firstUserMessage = AgentSessionSQLiteSupport.nonEmpty(row["first_user_message"])
    archivedAt = AgentSessionSQLiteSupport
      .nonEmpty(row["archived_at"])
      .flatMap(AgentSessionSQLiteSupport.sqliteDate)
    git = Self.git(from: row)
  }

  private static func git(from row: [String: String]) -> AgentSessionSQLiteGit? {
    let sha = AgentSessionSQLiteSupport.nonEmpty(row["git_sha"])
    let branch = AgentSessionSQLiteSupport.nonEmpty(row["git_branch"])
    let originURL = AgentSessionSQLiteSupport.nonEmpty(row["git_origin_url"])
    guard sha != nil || branch != nil || originURL != nil else {
      return nil
    }
    return AgentSessionSQLiteGit(sha: sha, branch: branch, originURL: originURL)
  }
}

public enum AgentSessionSQLiteReadMode: Equatable, Sendable {
  case compatibility
  case strict
}

public struct AgentSessionSQLiteQuery: Equatable, Sendable {
  public var id: String?
  public var cwd: String?
  public var createdAfter: Date?
  public var createdBefore: Date?
  public var limit: Int

  public init(
    id: String? = nil,
    cwd: String? = nil,
    createdAfter: Date? = nil,
    createdBefore: Date? = nil,
    limit: Int
  ) {
    self.id = id
    self.cwd = cwd
    self.createdAfter = createdAfter
    self.createdBefore = createdBefore
    self.limit = max(1, limit)
  }
}

public enum AgentSessionSQLiteSupport {
  public static let threadColumns = [
    "id", "rollout_path", "created_at", "updated_at", "source", "model_provider", "cwd",
    "cli_version", "title", "first_user_message", "archived_at", "git_sha", "git_branch",
    "git_origin_url"
  ]

  public static func openThreadsDatabase(
    at path: String,
    readMode: AgentSessionSQLiteReadMode = .compatibility
  ) -> String? {
    guard
      FileManager.default.fileExists(atPath: path),
      (try? openReadOnlyDatabase(at: path, readMode: readMode).tableExists("threads")) == true
    else {
      return nil
    }
    return path
  }

  public static func listThreadRecords(
    dbPath: String,
    separator: String,
    readMode: AgentSessionSQLiteReadMode = .compatibility
  ) -> [AgentSessionSQLiteRecord] {
    selectThreadRows(
      dbPath: dbPath,
      separator: separator,
      readMode: readMode
    ).compactMap(AgentSessionSQLiteRecord.init)
  }

  public static func queryThreadRecords(
    dbPath: String,
    query: AgentSessionSQLiteQuery,
    readMode: AgentSessionSQLiteReadMode = .compatibility
  ) -> [AgentSessionSQLiteRecord] {
    queryThreadRows(
      dbPath: dbPath,
      query: query,
      readMode: readMode
    ).compactMap(AgentSessionSQLiteRecord.init)
  }

  public static func selectThreadRows(
    dbPath: String,
    separator: String,
    readMode: AgentSessionSQLiteReadMode = .compatibility
  ) -> [[String: String]] {
    guard let rows = try? queryThreadRows(dbPath: dbPath, readMode: readMode) else {
      return []
    }
    return rows.map { row in
      Dictionary(uniqueKeysWithValues: threadColumns.map { column in
        (column, row.string(column))
      })
    }
  }

  public static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else {
      return nil
    }
    return value
  }

  public static func sqliteDate(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
  }

  private static func queryThreadRows(
    dbPath: String,
    readMode: AgentSessionSQLiteReadMode
  ) throws -> [SQLiteRow] {
    let db = try openReadOnlyDatabase(at: dbPath, readMode: readMode)
    let selectedColumns = threadColumns
      .map { "ifnull(\($0),'') AS \($0)" }
      .joined(separator: ", ")
    return try db.query("SELECT \(selectedColumns) FROM threads")
  }

  private static func queryThreadRows(
    dbPath: String,
    query: AgentSessionSQLiteQuery,
    readMode: AgentSessionSQLiteReadMode
  ) -> [[String: String]] {
    guard let rows = try? queryThreadRowsThrowing(
      dbPath: dbPath,
      query: query,
      readMode: readMode
    ) else {
      return []
    }
    return rows.map { row in
      Dictionary(uniqueKeysWithValues: threadColumns.map { column in
        (column, row.string(column))
      })
    }
  }

  private static func queryThreadRowsThrowing(
    dbPath: String,
    query: AgentSessionSQLiteQuery,
    readMode: AgentSessionSQLiteReadMode
  ) throws -> [SQLiteRow] {
    let db = try openReadOnlyDatabase(at: dbPath, readMode: readMode)
    let selectedColumns = threadColumns
      .map { "ifnull(\($0),'') AS \($0)" }
      .joined(separator: ", ")
    var predicates: [String] = []
    var bindings: [SQLiteValue] = []
    if let id = query.id {
      predicates.append("id = ?")
      bindings.append(.text(id))
    }
    if let cwd = query.cwd {
      predicates.append("cwd = ?")
      bindings.append(.text(cwd))
    }
    if let createdAfter = query.createdAfter {
      predicates.append("unixepoch(created_at) >= unixepoch(?)")
      bindings.append(.text(sqliteDateString(createdAfter)))
    }
    if let createdBefore = query.createdBefore {
      predicates.append("unixepoch(created_at) <= unixepoch(?)")
      bindings.append(.text(sqliteDateString(createdBefore)))
    }
    let whereClause = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
    bindings.append(.int(Int64(query.limit)))
    return try db.query(
      """
      SELECT \(selectedColumns)
      FROM threads\(whereClause)
      ORDER BY updated_at DESC, id
      LIMIT ?
      """,
      bindings: bindings
    )
  }

  private static func openReadOnlyDatabase(
    at path: String,
    readMode: AgentSessionSQLiteReadMode
  ) throws -> SQLiteDatabase {
    let openMode: SQLiteOpenMode = readMode == .strict ? .strictReadOnly : .readOnly
    return try SQLiteDatabase.open(
      path: path,
      mode: openMode,
      options: SQLiteOpenOptions(enableWAL: false, busyTimeoutMilliseconds: 3_000, requireJSONB: false)
    )
  }

  private static func sqliteDateString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
