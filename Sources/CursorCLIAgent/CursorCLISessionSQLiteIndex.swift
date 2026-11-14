import Foundation
import AgentRuntimeKit

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
    let records = AgentSessionSQLiteSupport.listThreadRecords(
      dbPath: dbPath,
      separator: sessionSQLiteSeparator
    )
    let sessions = CursorCLISessionQuery.sorted(
      records.map(recordToSession).filter { CursorCLISessionQuery.matches($0, options: options) },
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

  private static func recordToSession(_ record: AgentSessionSQLiteRecord) -> CursorCLISession {
    let git = record.git.map {
      CursorCLISessionGit(sha: $0.sha, branch: $0.branch, originURL: $0.originURL)
    }
    return CursorCLISession(
      id: record.id,
      rolloutPath: record.rolloutPath,
      createdAt: record.createdAt,
      updatedAt: record.updatedAt,
      source: CursorCLISessionSource(rawValue: record.source) ?? .unknown,
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
