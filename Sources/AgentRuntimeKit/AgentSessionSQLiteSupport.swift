import Foundation

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

  private static let sqliteExecutablePath = "/usr/bin/sqlite3"
  private static let threadsTableProbeSQL = "SELECT name FROM sqlite_master WHERE type='table' AND name='threads' LIMIT 1;"

  public static func openThreadsDatabase(at path: String) -> String? {
    guard
      FileManager.default.fileExists(atPath: path),
      sqliteQuery(dbPath: path, sql: threadsTableProbeSQL)?.contains("threads") == true
    else {
      return nil
    }
    return path
  }

  public static func listThreadRecords(dbPath: String, separator: String) -> [AgentSessionSQLiteRecord] {
    selectThreadRows(dbPath: dbPath, separator: separator).compactMap(AgentSessionSQLiteRecord.init)
  }

  public static func selectThreadRows(dbPath: String, separator: String) -> [[String: String]] {
    let selectedColumns = threadColumns
      .map { "ifnull(\($0),'')" }
      .joined(separator: " || '\(separator)' || ")
    let sql = "SELECT \(selectedColumns) FROM threads;"
    guard let output = sqliteQuery(dbPath: dbPath, sql: sql) else {
      return []
    }
    return output.split(separator: "\n", omittingEmptySubsequences: true).map { line in
      let values = String(line).components(separatedBy: separator)
      return Dictionary(uniqueKeysWithValues: zip(threadColumns, values))
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

  private static func sqliteQuery(dbPath: String, sql: String) -> String? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: sqliteExecutablePath)
    process.arguments = ["-readonly", dbPath, sql]
    process.standardOutput = output
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return nil
    }
    guard process.terminationStatus == 0 else {
      return nil
    }
    return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
  }
}
