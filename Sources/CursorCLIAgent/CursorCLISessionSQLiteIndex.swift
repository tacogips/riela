import Foundation
import RielaAdapters

public enum CursorCLISessionSQLiteIndex {
  private static let sessionSQLiteSeparator = "|||riela-cursorCLI-sqlite|||"

  public static func statePath(cursorCLIHome: String? = nil) -> String {
    URL(fileURLWithPath: cursorCLIHome ?? resolveCursorCLIHome(), isDirectory: true).appendingPathComponent("state").path
  }

  public static func openCursorCLIDb(cursorCLIHome: String? = nil) -> String? {
    AgentSessionSQLiteSupport.openThreadsDatabase(at: statePath(cursorCLIHome: cursorCLIHome))
  }

  public static func listSessionsSqlite(cursorCLIHome: String? = nil, options: CursorCLISessionListOptions = CursorCLISessionListOptions()) -> CursorCLISessionListResult? {
    guard let dbPath = openCursorCLIDb(cursorCLIHome: cursorCLIHome) else {
      return nil
    }
    let rows = selectRows(dbPath: dbPath)
    let sessions = CursorCLISessionQuery.sorted(
      rows.compactMap(rowToSession).filter { CursorCLISessionQuery.matches($0, options: options) },
      options: options
    )
    let total = sessions.count
    let pageRange = CursorCLISessionQuery.page(totalCount: total, offset: options.offset, limit: options.limit)
    return CursorCLISessionListResult(sessions: Array(sessions[pageRange]), total: total, offset: options.offset, limit: options.limit)
  }

  public static func findSessionSqlite(id: String, cursorCLIHome: String? = nil) -> CursorCLISession? {
    listSessionsSqlite(cursorCLIHome: cursorCLIHome, options: CursorCLISessionListOptions(cursorCLIHome: cursorCLIHome, limit: Int.max)).map(\.sessions)?.first { $0.id == id }
  }

  public static func findLatestSessionSqlite(cursorCLIHome: String? = nil, cwd: String? = nil) -> CursorCLISession? {
    listSessionsSqlite(cursorCLIHome: cursorCLIHome, options: CursorCLISessionListOptions(cursorCLIHome: cursorCLIHome, cwd: cwd, limit: 1, sortBy: "updatedAt")).map(\.sessions.first) ?? nil
  }

  private static func selectRows(dbPath: String) -> [[String: String]] {
    AgentSessionSQLiteSupport.selectThreadRows(dbPath: dbPath, separator: sessionSQLiteSeparator)
  }

  private static func rowToSession(_ row: [String: String]) -> CursorCLISession? {
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
      ? CursorCLISessionGit(
        sha: AgentSessionSQLiteSupport.nonEmpty(row["git_sha"]),
        branch: AgentSessionSQLiteSupport.nonEmpty(row["git_branch"]),
        originURL: AgentSessionSQLiteSupport.nonEmpty(row["git_origin_url"])
      )
      : nil
    return CursorCLISession(
      id: id,
      rolloutPath: rolloutPath,
      createdAt: createdAt,
      updatedAt: updatedAt,
      source: CursorCLISessionSource(rawValue: row["source"] ?? "") ?? .unknown,
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
