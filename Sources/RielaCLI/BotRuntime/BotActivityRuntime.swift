import Foundation
import RielaCore
import RielaObservability
import RielaSQLite

enum BotActivityRuntime {
  static func recorder(sessionStoreRoot: String) -> any WorkflowActivityRecording {
    SQLiteWorkflowActivityRecorder(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot))
  }

  static func botContext(forExistingSession sessionId: String, sessionStoreRoot: String) -> BotRunContext? {
    let runtimeRoot = canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot)
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot)
    let store = BotStore(sessionStoreRoot: runtimeRoot)
    let session = try? runtime.loadStrictReadOnly(sessionId: sessionId).session
    let rootId = session?.rootSessionId ?? sessionId
    guard let link = try? store.link(forSession: rootId),
          let bot = try? store.load(botId: link.botId) else {
      return nil
    }
    return BotRunContext(botId: bot.botId, permissionWaitMs: bot.permissionWaitMs)
  }

  static func rerunEventHandler(
    _ handler: @escaping WorkflowRunEventHandler,
    sourceSessionId: String,
    botContext: BotRunContext,
    sessionStoreRoot: String,
    runtimeStore: InMemoryWorkflowRuntimeStore
  ) -> WorkflowRunEventHandler {
    let linker = BotRunLinker(sessionStoreRoot: sessionStoreRoot)
    return { event in
      if event.type == .sessionStarted,
         let session = try? await runtimeStore.loadSession(id: event.sessionId),
         session.parentSessionId == nil || session.parentSessionId == sourceSessionId {
        linker.link(sessionId: event.sessionId, botId: botContext.botId,
          source: "run", sourceRef: sourceSessionId, at: session.createdAt)
      }
      await handler(event)
    }
  }

  static func settleProcessExit(sessionId: String, sessionStoreRoot: String, now: Date) {
    let store = BotStore(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot))
    do {
      _ = try store.settleOpenActivity(sessionId: sessionId, reason: .processExit, at: now)
    } catch {
      RielaStandardStreams.writeError("riela activity settle: \(error)\n")
    }
  }

  static func deleteRuntimeRows(sessionIds: [String], in db: SQLiteDatabase) throws {
    try BotStore.deleteActivity(sessionIds: sessionIds, in: db)
    if try db.tableExists("bot_session_links") {
      for sessionId in Set(sessionIds).sorted() {
        try db.execute("DELETE FROM bot_session_links WHERE session_id = ?", bindings: [.text(sessionId)])
      }
    }
  }
}
