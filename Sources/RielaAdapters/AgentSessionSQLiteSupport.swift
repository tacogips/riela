import Foundation

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

  public static func selectThreadRows(dbPath: String, separator: String) -> [[String: String]] {
    let sql = "SELECT \(threadColumns.map { "ifnull(\($0),'')" }.joined(separator: " || '\(separator)' || ")) FROM threads;"
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
