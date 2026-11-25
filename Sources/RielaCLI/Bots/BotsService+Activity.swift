import Foundation
import RielaCore
import RielaGraphQL

extension BotsService {
  func activity(
    sessionId: String, afterSequence: Int = 0, limit: Int = 200, waitMs: Int = 0,
    isStillAuthorized: @Sendable () async -> Bool = { true }
  ) async throws -> BotActivityPage {
    let wait = min(BotActivityPage.maximumWaitMs, max(0, waitMs))
    let limit = min(BotActivityPage.maximumLimit, max(1, limit))
    let cursor = max(0, afterSequence)
    let holdsSlot = wait > 0 && activityWaiters.acquire()
    defer { if holdsSlot { activityWaiters.release() } }

    let deadline = activityClock().advanced(by: .milliseconds(holdsSlot ? wait : 0))
    let store = store
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.sessionStoreRoot)
    while true {
      try Task.checkCancellation()
      guard await isStillAuthorized() else {
        throw BotStoreError(code: "activity_wait_revoked", message: "Activity access was revoked")
      }
      let status = try activitySessionStatus(sessionId, store: store, runtime: runtime)
      // The storage poll also returns between executions. Only a terminal or removed session ends the surface wait.
      let page = try await BotStore.waitForActivity(
        store: store, sessionId: sessionId, afterSequence: cursor, limit: limit, waitMs: 0
      )
      let remaining = activityClock().duration(to: deadline)
      let settled = status?.isTerminal == true && page.state?.currentExecutionId == nil
      if !page.events.isEmpty || status == nil || settled || remaining <= .zero {
        return BotActivityPage(
          events: page.events, state: page.state, lastSequence: page.events.last?.seq ?? cursor,
          firstRetainedSequence: page.firstRetainedSequence, truncated: page.truncated,
          activitySource: page.activitySource, sessionStatus: status?.rawValue ?? "unknown", origin: origin(now())
        )
      }
      try await activitySleep(min(.milliseconds(250), remaining))
    }
  }

  func activitySessionId(botId: String) throws -> String {
    let board = BotBoardProjector.board(try projection(botId: botId).input)
    for group in [BotBoardGroup.needsYou, .inProgress, .closed] {
      let newest = board.groups[group]?.filter { $0.sessionId != nil }.max {
        let lhs = $0.bumpedAt ?? $0.lastActivityAt ?? .distantPast
        let rhs = $1.bumpedAt ?? $1.lastActivityAt ?? .distantPast
        return lhs == rhs ? $0.itemId > $1.itemId : lhs < rhs
      }
      if let sessionId = newest?.sessionId { return sessionId }
    }
    throw BotStoreError(code: "bot_no_activity", message: "Bot '\(botId)' has no session activity")
  }

  func answer(requestId: String, optionId: String?, decline: Bool) throws -> BotRequestPayload {
    do {
      return BotRequestPayload(try store.answerActivityRequest(
        requestId: requestId, optionId: optionId, decline: decline, now: now()
      ))
    } catch let error as BotStoreError where error.code == "request_not_found" {
      throw BotStoreError(
        code: error.code, message: "not a permission request; answer handover questions with riela task answer"
      )
    }
  }

  private func activitySessionStatus(
    _ sessionId: String, store: BotStore, runtime: SQLiteWorkflowRuntimePersistenceStore
  ) throws -> WorkflowSessionStatus? {
    guard FileManager.default.fileExists(atPath: store.databasePath) else { return nil }
    do {
      return try runtime.loadStatus(sessionId: sessionId).status
    } catch WorkflowRuntimePersistenceStoreError.notFound {
      return nil
    }
  }
}
