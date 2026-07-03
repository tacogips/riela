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

public enum AgentSessionSQLiteSupport {
  public static let threadColumns = [
    "id", "rollout_path", "created_at", "updated_at", "source", "model_provider", "cwd",
    "cli_version", "title", "first_user_message", "archived_at", "git_sha", "git_branch",
    "git_origin_url"
  ]

  public static func openThreadsDatabase(at path: String) -> String? {
    guard
      FileManager.default.fileExists(atPath: path),
      (try? openReadOnlyDatabase(at: path).tableExists("threads")) == true
    else {
      return nil
    }
    return path
  }

  public static func listThreadRecords(dbPath: String, separator: String) -> [AgentSessionSQLiteRecord] {
    selectThreadRows(dbPath: dbPath, separator: separator).compactMap(AgentSessionSQLiteRecord.init)
  }

  public static func selectThreadRows(dbPath: String, separator: String) -> [[String: String]] {
    guard let rows = try? queryThreadRows(dbPath: dbPath) else {
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

  private static func queryThreadRows(dbPath: String) throws -> [SQLiteRow] {
    let db = try openReadOnlyDatabase(at: dbPath)
    let selectedColumns = threadColumns
      .map { "ifnull(\($0),'') AS \($0)" }
      .joined(separator: ", ")
    return try db.query("SELECT \(selectedColumns) FROM threads")
  }

  private static func openReadOnlyDatabase(at path: String) throws -> SQLiteDatabase {
    try SQLiteDatabase.open(
      path: path,
      mode: .readOnly,
      options: SQLiteOpenOptions(enableWAL: false, busyTimeoutMilliseconds: 3_000, requireJSONB: false)
    )
  }
}
