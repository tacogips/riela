import Foundation
import RielaAdapters

public enum ClaudeCodeSessionSQLiteIndex {
  private static let sessionSQLiteSeparator = "|||riela-claudeCode-sqlite|||"

  public static func statePath(claudeCodeHome: String? = nil) -> String {
    URL(fileURLWithPath: claudeCodeHome ?? resolveClaudeCodeHome(), isDirectory: true).appendingPathComponent("state").path
  }

  public static func openClaudeCodeDb(claudeCodeHome: String? = nil) -> String? {
    AgentSessionSQLiteSupport.openThreadsDatabase(at: statePath(claudeCodeHome: claudeCodeHome))
  }

  public static func listSessionsSqlite(claudeCodeHome: String? = nil, options: ClaudeCodeSessionListOptions = ClaudeCodeSessionListOptions()) -> ClaudeCodeSessionListResult? {
    guard let dbPath = openClaudeCodeDb(claudeCodeHome: claudeCodeHome) else {
      return nil
    }
    let rows = selectRows(dbPath: dbPath)
    let sessions = rows.compactMap(rowToSession).filter { session in
      if let source = options.source, session.source != source {
        return false
      }
      if let cwd = options.cwd, session.cwd != cwd {
        return false
      }
      if let branch = options.branch, session.git?.branch != branch {
        return false
      }
      return true
    }.sorted { lhs, rhs in
      let left = options.sortBy == "updatedAt" ? lhs.updatedAt : lhs.createdAt
      let right = options.sortBy == "updatedAt" ? rhs.updatedAt : rhs.createdAt
      return options.sortOrder == "asc" ? left < right : left > right
    }
    let total = sessions.count
    let start = min(max(options.offset, 0), sessions.count)
    let end = min(start + max(options.limit, 0), sessions.count)
    return ClaudeCodeSessionListResult(sessions: Array(sessions[start..<end]), total: total, offset: options.offset, limit: options.limit)
  }

  public static func findSessionSqlite(id: String, claudeCodeHome: String? = nil) -> ClaudeCodeSession? {
    listSessionsSqlite(claudeCodeHome: claudeCodeHome, options: ClaudeCodeSessionListOptions(claudeCodeHome: claudeCodeHome, limit: Int.max)).map(\.sessions)?.first { $0.id == id }
  }

  public static func findLatestSessionSqlite(claudeCodeHome: String? = nil, cwd: String? = nil) -> ClaudeCodeSession? {
    listSessionsSqlite(claudeCodeHome: claudeCodeHome, options: ClaudeCodeSessionListOptions(claudeCodeHome: claudeCodeHome, cwd: cwd, limit: 1, sortBy: "updatedAt")).map(\.sessions.first) ?? nil
  }

  private static func selectRows(dbPath: String) -> [[String: String]] {
    AgentSessionSQLiteSupport.selectThreadRows(dbPath: dbPath, separator: sessionSQLiteSeparator)
  }

  private static func rowToSession(_ row: [String: String]) -> ClaudeCodeSession? {
    guard
      let id = AgentSessionSQLiteSupport.nonEmpty(row["id"]),
      let rolloutPath = AgentSessionSQLiteSupport.nonEmpty(row["rollout_path"]),
      let createdAt = AgentSessionSQLiteSupport.nonEmpty(row["created_at"]).flatMap(AgentSessionSQLiteSupport.sqliteDate),
      let updatedAt = AgentSessionSQLiteSupport.nonEmpty(row["updated_at"]).flatMap(AgentSessionSQLiteSupport.sqliteDate),
      let cwd = AgentSessionSQLiteSupport.nonEmpty(row["cwd"])
    else {
      return nil
    }
    let git = [row["git_sha"], row["git_branch"], row["git_origin_url"]].contains { AgentSessionSQLiteSupport.nonEmpty($0) != nil }
      ? ClaudeCodeSessionGit(
        sha: AgentSessionSQLiteSupport.nonEmpty(row["git_sha"]),
        branch: AgentSessionSQLiteSupport.nonEmpty(row["git_branch"]),
        originURL: AgentSessionSQLiteSupport.nonEmpty(row["git_origin_url"])
      )
      : nil
    return ClaudeCodeSession(
      id: id,
      rolloutPath: rolloutPath,
      createdAt: createdAt,
      updatedAt: updatedAt,
      source: ClaudeCodeSessionSource(rawValue: row["source"] ?? "") ?? .unknown,
      modelProvider: AgentSessionSQLiteSupport.nonEmpty(row["model_provider"]),
      cwd: cwd,
      cliVersion: AgentSessionSQLiteSupport.nonEmpty(row["cli_version"]) ?? "unknown",
      title: AgentSessionSQLiteSupport.nonEmpty(row["title"]) ?? AgentSessionSQLiteSupport.nonEmpty(row["first_user_message"]) ?? id,
      firstUserMessage: AgentSessionSQLiteSupport.nonEmpty(row["first_user_message"]),
      archivedAt: AgentSessionSQLiteSupport.nonEmpty(row["archived_at"]).flatMap(AgentSessionSQLiteSupport.sqliteDate),
      git: git
    )
  }
}
