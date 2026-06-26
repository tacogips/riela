import Foundation
import RielaAdapters

public enum CodexSessionSQLiteIndex {
  private static let sessionSQLiteSeparator = "|||riela-codex-sqlite|||"

  public static func statePath(codexHome: String? = nil) -> String {
    URL(fileURLWithPath: codexHome ?? resolveCodexHome(), isDirectory: true).appendingPathComponent("state").path
  }

  public static func openCodexDb(codexHome: String? = nil) -> String? {
    AgentSessionSQLiteSupport.openThreadsDatabase(at: statePath(codexHome: codexHome))
  }

  public static func listSessionsSqlite(codexHome: String? = nil, options: CodexSessionListOptions = CodexSessionListOptions()) -> CodexSessionListResult? {
    guard let dbPath = openCodexDb(codexHome: codexHome) else {
      return nil
    }
    let rows = selectRows(dbPath: dbPath)
    let sessions = CodexSessionQuery.sorted(
      rows.compactMap(rowToSession).filter { CodexSessionQuery.matches($0, options: options) },
      options: options
    )
    let total = sessions.count
    let pageRange = CodexSessionQuery.page(totalCount: total, offset: options.offset, limit: options.limit)
    return CodexSessionListResult(sessions: Array(sessions[pageRange]), total: total, offset: options.offset, limit: options.limit)
  }

  public static func findSessionSqlite(id: String, codexHome: String? = nil) -> CodexSession? {
    listSessionsSqlite(codexHome: codexHome, options: CodexSessionListOptions(codexHome: codexHome, limit: Int.max)).map(\.sessions)?.first { $0.id == id }
  }

  public static func findLatestSessionSqlite(codexHome: String? = nil, cwd: String? = nil) -> CodexSession? {
    listSessionsSqlite(codexHome: codexHome, options: CodexSessionListOptions(codexHome: codexHome, cwd: cwd, limit: 1, sortBy: "updatedAt")).map(\.sessions.first) ?? nil
  }

  private static func selectRows(dbPath: String) -> [[String: String]] {
    AgentSessionSQLiteSupport.selectThreadRows(dbPath: dbPath, separator: sessionSQLiteSeparator)
  }

  private static func rowToSession(_ row: [String: String]) -> CodexSession? {
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
      ? CodexSessionGit(
        sha: AgentSessionSQLiteSupport.nonEmpty(row["git_sha"]),
        branch: AgentSessionSQLiteSupport.nonEmpty(row["git_branch"]),
        originURL: AgentSessionSQLiteSupport.nonEmpty(row["git_origin_url"])
      )
      : nil
    return CodexSession(
      id: id,
      rolloutPath: rolloutPath,
      createdAt: createdAt,
      updatedAt: updatedAt,
      source: CodexSessionSource(rawValue: row["source"] ?? "") ?? .unknown,
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
