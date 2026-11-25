import Foundation
import RielaSQLite

public struct BotJobRun: Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case running, succeeded, failed, skipped
  }

  public let botId: String
  public let job: BotJobKind
  public let periodKey: String
  public let status: Status
  public let sessionId: String?
  public let detail: String?
  public let startedAt: String
  public let finishedAt: String?
}

extension BotStore {
  public func claimJobRun(
    botId: String, job: BotJobKind, periodKey: String, sessionId: String?, at date: Date
  ) throws -> Bool {
    try write { database in
      try Self.requireJobBot(botId, in: database)
      return try database.executeAndReturnChangedRowCount(
        """
        INSERT INTO bot_job_runs (bot_id, job, period_key, status, session_id, started_at)
        VALUES (?, ?, ?, 'running', ?, ?)
        ON CONFLICT (bot_id, job, period_key) DO NOTHING
        """,
        bindings: [
          .text(botId), .text(job.rawValue), .text(periodKey),
          SQLiteValue.optionalText(sessionId), .text(RoutineStore.timestamp(date))
        ]
      ) == 1
    }
  }

  public func finishJobRun(
    botId: String, job: BotJobKind, periodKey: String, status: BotJobRun.Status, detail: String?, at date: Date
  ) throws {
    guard status != .running else {
      throw BotStoreError(code: "bot_job_status_invalid", message: "Finishing a job requires a terminal status")
    }
    try write { database in
      let changed = try database.executeAndReturnChangedRowCount(
        """
        UPDATE bot_job_runs SET status = ?, detail = ?, finished_at = ?
        WHERE bot_id = ? AND job = ? AND period_key = ? AND status = 'running'
        """,
        bindings: [
          .text(status.rawValue), SQLiteValue.optionalText(detail), .text(RoutineStore.timestamp(date)),
          .text(botId), .text(job.rawValue), .text(periodKey)
        ]
      )
      guard changed == 1 else {
        throw BotStoreError(code: "bot_job_not_running", message: "Job '\(job.rawValue)' is not running for period '\(periodKey)'")
      }
    }
  }

  public func recordSkippedJobRuns(
    botId: String, job: BotJobKind, periodKeys: [String], reason: String, at date: Date
  ) throws {
    guard !periodKeys.isEmpty else { return }
    let timestamp = RoutineStore.timestamp(date)
    try write { database in
      try Self.requireJobBot(botId, in: database)
      for key in periodKeys {
        try database.execute(
          """
          INSERT OR IGNORE INTO bot_job_runs (bot_id, job, period_key, status, detail, started_at, finished_at)
          VALUES (?, ?, ?, 'skipped', ?, ?, ?)
          """,
          bindings: [.text(botId), .text(job.rawValue), .text(key), .text(reason), .text(timestamp), .text(timestamp)]
        )
      }
    }
  }

  public func jobRuns(botId: String, job: BotJobKind, limit: Int) throws -> [BotJobRun] {
    guard limit > 0 else { return [] }
    return try read { database in
      try database.query(
        """
        SELECT * FROM bot_job_runs WHERE bot_id = ? AND job = ?
        ORDER BY started_at DESC, period_key DESC LIMIT ?
        """,
        bindings: [.text(botId), .text(job.rawValue), .int(Int64(limit))]
      ).map(Self.decodeJobRun)
    } ?? []
  }

  public func lastSuccessfulJobRun(botId: String, job: BotJobKind) throws -> BotJobRun? {
    try read { database in
      try database.query(
        """
        SELECT * FROM bot_job_runs WHERE bot_id = ? AND job = ? AND status = 'succeeded'
        ORDER BY finished_at DESC, period_key DESC LIMIT 1
        """,
        bindings: [.text(botId), .text(job.rawValue)]
      ).first.map(Self.decodeJobRun)
    } ?? nil
  }

  static func requireJobBot(_ botId: String, in database: SQLiteDatabase) throws {
    guard try !database.query("SELECT 1 FROM bots WHERE bot_id = ?", bindings: [.text(botId)]).isEmpty else {
      throw BotStoreError(code: "bot_not_found", message: "Bot '\(botId)' was not found")
    }
  }

  private static func decodeJobRun(_ row: SQLiteRow) throws -> BotJobRun {
    guard let botId = row["bot_id"], let job = row["job"].flatMap(BotJobKind.init(rawValue:)),
      let key = row["period_key"], let status = row["status"].flatMap(BotJobRun.Status.init(rawValue:)),
      let startedAt = row["started_at"]
    else {
      throw BotStoreError(code: "bot_job_invalid", message: "Job ledger row is missing valid required fields")
    }
    return BotJobRun(
      botId: botId, job: job, periodKey: key, status: status, sessionId: row["session_id"],
      detail: row["detail"], startedAt: startedAt, finishedAt: row["finished_at"]
    )
  }
}
