extension BotStore {
  /// Looks up the existing permission record by ID for proposal validation.
  public func askActivityRequest(id: String) throws -> ActivityRequestRecord? {
    try read { try ActivityRequestRecord.load(id: id, db: $0) } ?? nil
  }
}

extension BotStore {
  public func askActivityPage(conversationId: String, afterSequence: Int, limit: Int) async throws -> ActivityPage {
    let cursor = max(0, afterSequence)
    let page = try await Self.waitForActivity(
      store: self, sessionId: AskActivityKey.sessionId(conversationId), afterSequence: cursor, limit: limit, waitMs: 0
    )
    return ActivityPage(
      events: page.events, state: page.state, lastSequence: page.events.last?.seq ?? cursor,
      firstRetainedSequence: page.firstRetainedSequence, truncated: page.truncated, activitySource: page.activitySource
    )
  }
}
