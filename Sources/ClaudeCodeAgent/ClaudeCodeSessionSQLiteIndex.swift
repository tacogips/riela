import Foundation
import AgentRuntimeKit

public enum ClaudeCodeSessionSQLiteIndex {
  private static let sessionSQLiteSeparator = "|||riela-claudeCode-sqlite|||"

  public static func statePath(claudeCodeHome: String? = nil) -> String {
    URL(fileURLWithPath: claudeCodeHome ?? resolveClaudeCodeHome(), isDirectory: true).appendingPathComponent("state").path
  }

  public static func openClaudeCodeDb(
    claudeCodeHome: String? = nil,
    readMode: AgentSessionSQLiteReadMode = .compatibility
  ) -> String? {
    AgentSessionSQLiteSupport.openThreadsDatabase(
      at: statePath(claudeCodeHome: claudeCodeHome),
      readMode: readMode
    )
  }

  public static func listSessionsSqlite(
    claudeCodeHome: String? = nil,
    options: ClaudeCodeSessionListOptions = ClaudeCodeSessionListOptions(),
    readMode: AgentSessionSQLiteReadMode = .compatibility
  ) -> ClaudeCodeSessionListResult? {
    guard let dbPath = openClaudeCodeDb(claudeCodeHome: claudeCodeHome, readMode: readMode) else {
      return nil
    }
    let records = AgentSessionSQLiteSupport.listThreadRecords(
      dbPath: dbPath,
      separator: sessionSQLiteSeparator,
      readMode: readMode
    )
    let sessions = ClaudeCodeSessionQuery.sorted(
      records.map(recordToSession).filter { ClaudeCodeSessionQuery.matches($0, options: options) },
      options: options
    )
    let total = sessions.count
    let pageRange = ClaudeCodeSessionQuery.page(totalCount: total, offset: options.offset, limit: options.limit)
    return ClaudeCodeSessionListResult(sessions: Array(sessions[pageRange]), total: total, offset: options.offset, limit: options.limit)
  }

  public static func findSessionSqlite(id: String, claudeCodeHome: String? = nil) -> ClaudeCodeSession? {
    listSessionsSqlite(claudeCodeHome: claudeCodeHome, options: ClaudeCodeSessionListOptions(claudeCodeHome: claudeCodeHome, limit: Int.max)).map(\.sessions)?.first { $0.id == id }
  }

  public static func findLatestSessionSqlite(claudeCodeHome: String? = nil, cwd: String? = nil) -> ClaudeCodeSession? {
    listSessionsSqlite(claudeCodeHome: claudeCodeHome, options: ClaudeCodeSessionListOptions(claudeCodeHome: claudeCodeHome, cwd: cwd, limit: 1, sortBy: "updatedAt")).map(\.sessions.first) ?? nil
  }

  static func activitySessionsSqlite(
    claudeCodeHome: String,
    query: AgentSessionSQLiteQuery,
    readMode: AgentSessionSQLiteReadMode
  ) -> [ClaudeCodeSession] {
    guard let dbPath = openClaudeCodeDb(claudeCodeHome: claudeCodeHome, readMode: readMode) else {
      return []
    }
    return AgentSessionSQLiteSupport.queryThreadRecords(
      dbPath: dbPath,
      query: query,
      readMode: readMode
    ).map(recordToSession)
  }

  private static func recordToSession(_ record: AgentSessionSQLiteRecord) -> ClaudeCodeSession {
    let git = record.git.map {
      ClaudeCodeSessionGit(sha: $0.sha, branch: $0.branch, originURL: $0.originURL)
    }
    return ClaudeCodeSession(
      id: record.id,
      rolloutPath: record.rolloutPath,
      createdAt: record.createdAt,
      updatedAt: record.updatedAt,
      source: ClaudeCodeSessionSource(rawValue: record.source) ?? .unknown,
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
