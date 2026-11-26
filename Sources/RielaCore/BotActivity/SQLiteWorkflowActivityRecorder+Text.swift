import Foundation

extension SQLiteWorkflowActivityRecorder {
  func recordText(sessionId: String, buffer: TextBuffer) throws {
    guard activeExecutions[sessionId] == buffer.executionId else { return }
    let at = buffer.openedAt
    var pending = buffers[sessionId] ?? []
    var combined = buffer
    if let last = pending.last, last.kind == buffer.kind, last.messageId == buffer.messageId {
      pending.removeLast()
      if !buffer.replacesMessage {
        combined = last
        combined.text += buffer.text
      }
    }
    let baseline = lastTextFlush[sessionId] ?? combined.openedAt
    let shouldFlush = combined.text.utf8.count >= limits.textFlushBytes
      || at.timeIntervalSince(baseline) >= Double(limits.textFlushIntervalMs) / 1_000
    if !pending.isEmpty || shouldFlush {
      let flushed = shouldFlush ? pending + [combined] : pending
      let executionId = buffer.executionId
      try withWriter { db in
        var journal = try ActivityJournal(sessionId: sessionId, db: db)
        guard journal.state.currentExecutionId == executionId else { return }
        flush(flushed, executionId: executionId, into: &journal, at: at, final: false)
        try journal.save(in: db, at: at, limits: limits)
      }
      lastTextFlush[sessionId] = at
    }
    buffers[sessionId] = shouldFlush ? nil : [combined]
  }

  func flush(
    _ buffers: [TextBuffer], executionId: String, into journal: inout ActivityJournal, at: Date, final: Bool
  ) {
    for buffer in buffers where buffer.executionId == executionId {
      var payload: JSONObject = ["text": .string(buffer.text)]
      let update: AdapterActivityUpdate
      if buffer.kind == .message {
        payload["messageId"] = buffer.messageId.map(JSONValue.string)
        payload["final"] = .bool(final)
        if buffer.replacesMessage { payload["replace"] = .bool(true) }
        update = .message(messageId: buffer.messageId, text: buffer.text, replace: false)
      } else {
        update = .thought(text: buffer.text)
      }
      _ = ActivityReducer.apply(update, to: &journal.state, executionId: executionId, at: at)
      journal.append([.init(kind: buffer.kind, payload: payload)], executionId: executionId, at: at)
    }
  }
}
