import Foundation
import RielaSQLite

public struct ActivityPage: Equatable, Sendable {
  public let events: [ActivityEvent]
  public let state: ActivityState?
  public let lastSequence: Int
  public let firstRetainedSequence: Int
  public let truncated: Bool
  public let activitySource: String
}

extension BotStore {
  public func activityPage(sessionId: String, afterSequence: Int = 0, limit: Int = 200) throws -> ActivityPage {
    try read { db in
      try db.transaction(begin: "BEGIN") { db in
        let journal = try ActivityJournal(sessionId: sessionId, db: db)
        let events = try db.query(
          """
          SELECT seq, execution_id, at, kind, json(payload_json) AS payload_json
          FROM activity_events WHERE session_id = ? AND seq > ? ORDER BY seq LIMIT ?
          """, bindings: [.text(sessionId), .int(Int64(afterSequence)), .int(Int64(min(500, max(1, limit))))]
        ).map { row in
          guard let seq = row["seq"].flatMap(Int.init), let kind = row["kind"].flatMap(ActivityEventKind.init(rawValue:)) else {
            throw BotStoreError(code: "activity_record_invalid", message: "Invalid activity event sequence or kind")
          }
          return try ActivityEvent(
            sessionId: sessionId, seq: seq, executionId: row["execution_id"],
            at: ActivityJournal.date(column: "at", row: row), kind: kind,
            payload: ActivityJournal.decode(JSONObject.self, column: "payload_json", row: row)
          )
        }
        return ActivityPage(
          events: events, state: journal.lastSequence == 0 ? nil : journal.state,
          lastSequence: journal.lastSequence, firstRetainedSequence: journal.firstRetainedSequence,
          truncated: journal.firstRetainedSequence > 1 && afterSequence < journal.firstRetainedSequence - 1,
          activitySource: journal.state.source
        )
      }
    } ?? ActivityPage(
      events: [], state: nil, lastSequence: 0, firstRetainedSequence: 1, truncated: false, activitySource: "session"
    )
  }

  public func activityStates(sessionIds: [String]) throws -> [String: ActivityState] {
    try read { db in
      try db.transaction(begin: "BEGIN") { db in
        var states: [String: ActivityState] = [:]
        for id in Set(sessionIds) {
          let journal = try ActivityJournal(sessionId: id, db: db)
          if journal.lastSequence > 0 { states[id] = journal.state }
        }
        return states
      }
    } ?? [:]
  }

  public func pendingActivityRequests(sessionIds: [String]) throws -> [ActivityRequestRecord] {
    try read { db in
      try db.transaction(begin: "BEGIN") { db in
        try Set(sessionIds).sorted().flatMap { id in
          try ActivityRequestRecord.pending(sessionId: id, db: db)
        }
      }
    } ?? []
  }

  public func settleOpenActivity(sessionId: String, reason: ActivitySettleReason, at: Date) throws -> Bool {
    try write { db in
      var journal = try ActivityJournal(sessionId: sessionId, db: db)
      guard let executionId = journal.state.currentExecutionId else { return false }
      try journal.settle(executionId: executionId, reason: reason, stepStatus: "failed", at: at, db: db)
      try journal.save(in: db, at: at)
      return true
    }
  }

  public static func deleteActivity(sessionIds: [String], in db: SQLiteDatabase) throws {
    for table in ["activity_requests", "activity_events", "activity_state"] where try db.tableExists(table) {
      for sessionId in Set(sessionIds) {
        try db.execute("DELETE FROM \(table) WHERE session_id = ?", bindings: [.text(sessionId)])
      }
    }
  }

  public static func waitForActivity(
    store: BotStore, sessionId: String, afterSequence: Int, limit: Int = 200, waitMs: Int, pollMs: Int = 250,
    sleep: @Sendable (UInt64) async -> Void = ActivityLimits.sleep,
    isStillAuthorized: @Sendable () async -> Bool = { true }
  ) async throws -> ActivityPage {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(min(25_000, max(0, waitMs))))
    while true {
      try Task.checkCancellation()
      guard await isStillAuthorized() else {
        throw BotStoreError(code: "activity_wait_revoked", message: "Activity access was revoked")
      }
      let page = try store.activityPage(sessionId: sessionId, afterSequence: afterSequence, limit: limit)
      if page.lastSequence > afterSequence || page.state.map({ $0.currentExecutionId == nil }) == true {
        return page
      }
      let now = clock.now
      guard now < deadline else { return page }
      let remaining = now.duration(to: deadline).components
      let nanoseconds = UInt64(remaining.seconds) * 1_000_000_000 + UInt64(remaining.attoseconds / 1_000_000_000)
      await sleep(min(nanoseconds, UInt64(min(25_000, max(1, pollMs))) * 1_000_000))
    }
  }
}
