import Foundation

extension SQLiteWorkflowActivityRecorder {
  public func requestPermission(
    sessionId: String, executionId: String, request: AdapterPermissionRequest, waitMs: Int, deadline: Date?
  ) async -> AdapterPermissionOutcome {
    let at = Date()
    let expiresAt = min(at.addingTimeInterval(Double(max(0, waitMs)) / 1_000), deadline ?? .distantFuture)
    let record = ActivityRequestRecord(sessionId: sessionId, executionId: executionId, request: request, at: at, expiresAt: expiresAt)
    do {
      let inserted = try store.write { db in
        var journal = try ActivityJournal(sessionId: sessionId, db: db)
        guard journal.state.currentExecutionId == executionId else { return false }
        flush(buffers[sessionId] ?? [], executionId: executionId, into: &journal, at: at, final: false)
        journal.state.source = "acp"
        journal.state.pendingRequestIds.append(record.requestId)
        journal.append([try record.insert(db: db)], executionId: executionId, at: at)
        if let reason = permissionDefault(waitMs: waitMs, now: at, expiresAt: expiresAt) {
          var pending = record
          let event = try pending.resolve(by: reason, at: at, db: db)
          journal.state.pendingRequestIds.removeAll { $0 == record.requestId }
          journal.append([event], executionId: executionId, at: at)
        }
        try journal.save(in: db, at: at, limits: limits)
        return true
      }
      guard inserted else { return .cancelled }
      if buffers[sessionId]?.contains(where: { $0.executionId == executionId }) == true {
        lastTextFlush[sessionId] = at
      }
      discardBuffers(sessionId: sessionId, executionId: executionId)
      return try await waitForPermission(record, waitMs: waitMs)
    } catch {
      log(error, sessionId: sessionId)
      return .cancelled
    }
  }

  private func waitForPermission(_ record: ActivityRequestRecord, waitMs: Int) async throws -> AdapterPermissionOutcome {
    var nextPoll = record.createdAt
    while true {
      guard let current = try store.read({ try ActivityRequestRecord.load(id: record.requestId, db: $0) }) ?? nil else {
        return .cancelled
      }
      if current.status != .pending { return Task.isCancelled ? .cancelled : current.outcome }
      let now = max(nextPoll, Date())
      if let reason = permissionDefault(waitMs: waitMs, now: now, expiresAt: record.expiresAt) {
        if reason == .settlement {
          _ = try await Task { try resolvePendingPermission(record, by: .settlement, at: now) }.value
          return .cancelled
        }
        let outcome = try resolvePendingPermission(record, by: reason, at: now)
        return Task.isCancelled ? .cancelled : outcome
      }
      let interval = min(
        Double(min(limits.requestPollIntervalMs, 60_000)) / 1_000, record.expiresAt.timeIntervalSince(now)
      )
      nextPoll = now.addingTimeInterval(interval)
      await sleep(UInt64((interval * 1_000_000_000).rounded(.up)))
    }
  }

  private func permissionDefault(waitMs: Int, now: Date, expiresAt: Date) -> ActivityRequestRecord.Resolution? {
    if Task.isCancelled { return .settlement }
    if waitMs <= 0 { return .policy }
    return now >= expiresAt ? .timeout : nil
  }

  private func resolvePendingPermission(
    _ record: ActivityRequestRecord, by reason: ActivityRequestRecord.Resolution, at: Date
  ) throws -> AdapterPermissionOutcome {
    try store.write { db in
      guard var latest = try ActivityRequestRecord.load(id: record.requestId, db: db) else { return .cancelled }
      if latest.status != .pending { return latest.outcome }
      var journal = try ActivityJournal(sessionId: record.sessionId, db: db)
      let event = try latest.resolve(by: reason, at: at, db: db)
      journal.state.pendingRequestIds.removeAll { $0 == record.requestId }
      journal.append([event], executionId: record.executionId, at: at)
      try journal.save(in: db, at: at, limits: limits)
      return latest.outcome
    }
  }
}
