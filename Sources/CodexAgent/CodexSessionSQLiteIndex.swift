import Foundation
import AgentRuntimeKit

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
    let records = AgentSessionSQLiteSupport.listThreadRecords(
      dbPath: dbPath,
      separator: sessionSQLiteSeparator
    )
    let sessions = CodexSessionQuery.sorted(
      records.map(recordToSession).filter { CodexSessionQuery.matches($0, options: options) },
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

  private static func recordToSession(_ record: AgentSessionSQLiteRecord) -> CodexSession {
    let git = record.git.map {
      CodexSessionGit(sha: $0.sha, branch: $0.branch, originURL: $0.originURL)
    }
    return CodexSession(
      id: record.id,
      rolloutPath: record.rolloutPath,
      createdAt: record.createdAt,
      updatedAt: record.updatedAt,
      source: CodexSessionSource(rawValue: record.source) ?? .unknown,
      modelProvider: record.modelProvider,
      cwd: record.cwd,
      cliVersion: record.cliVersion,
      title: record.title,
      firstUserMessage: record.firstUserMessage,
      archivedAt: record.archivedAt,
      git: git
    )
  }
}
