import Foundation
import RielaSQLite
import XCTest
@testable import RielaCore

final class AskStoreTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  func testWritesAddTablesWithoutChangingGenerationOrExistingRecords() throws {
    try withStore { store in
      let session = WorkflowSession(
        workflowId: "workflow", sessionId: "session", status: .completed, entryStepId: "entry", createdAt: now, updatedAt: now
      )
      let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.sessionStoreRoot)
      try persistence.save(WorkflowRuntimePersistenceSnapshot(session: session))
      let at = RoutineStore.timestamp(now)
      let bot = BotRecord(botId: "fixture-bot", name: "Fixture", createdAt: at, updatedAt: at)
      try store.write { db in
        try db.execute(
          "INSERT INTO bots (bot_id, record_json, updated_at) VALUES (?, jsonb(?), ?)",
          bindings: [.text(bot.botId), .text(try BotStore.askJSON(bot)), .text(at)]
        )
        for table in ["ask_actions", "ask_messages", "ask_conversations"] {
          try db.execute("DROP TABLE \(table)")
        }
      }

      let db = try SQLiteDatabase.open(path: store.databasePath, mode: .strictReadOnly)
      let snapshotQuery = "SELECT workflow_execution_id, json(session_json) FROM workflow_runtime_snapshots"
      let snapshots = try db.query(snapshotQuery)
      XCTAssertEqual(snapshots.count, 1)
      XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: db), 13)
      XCTAssertEqual(try store.askConversations(), [])
      XCTAssertNil(try store.askConversation(id: "missing"))
      XCTAssertEqual(try store.askMessages(conversationId: "missing"), [])
      XCTAssertEqual(try store.askActions(conversationId: "missing"), [])
      XCTAssertNil(try store.askAction(id: "missing"))
      for table in ["ask_conversations", "ask_messages", "ask_actions"] {
        XCTAssertFalse(try db.tableExists(table))
      }

      let conversation = try create(store)
      XCTAssertEqual(try store.askConversation(id: conversation.conversationId), conversation)
      XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: db), 13)
      XCTAssertEqual(try db.query(snapshotQuery), snapshots)
      XCTAssertEqual(try store.list(), [bot])
      for table in ["ask_conversations", "ask_messages", "ask_actions"] {
        XCTAssertTrue(try db.tableExists(table))
      }
    }
  }

  func testReadMissingDatabaseDoesNotCreateIt() throws {
    try withStore { store in
      XCTAssertEqual(try store.askConversations(), [])
      XCTAssertFalse(FileManager.default.fileExists(atPath: store.databasePath))
    }
  }

  func testTurnAndMessageLimitsAndMonotonicSequences() throws {
    try withStore { store in
      var limits = AskLimits.standard
      limits.turnsPerConversation = 2
      limits.messagesPerConversation = 4
      limits.userMessageBytes = 7
      let id = try create(store, limits: limits).conversationId
      assertCode("ask_message_too_large") { try begin(store, id, message: "éééé", limits: limits) }
      for number in 1...3 {
        let turnId = try begin(store, id, limits: limits)
        XCTAssertEqual(turnId, "turn-\(number)")
        assertCode("ask_turn_running") { try begin(store, id, limits: limits) }
        XCTAssertTrue(try store.finishAskTurn(conversationId: id, turnId: turnId, status: .completed, assistantText: "reply", limits: limits, now: now))
        if number == 2 {
          assertCode("ask_budget_exceeded") { try begin(store, id, limits: limits) }
          limits.turnsPerConversation = 3
        }
      }
      XCTAssertEqual(try store.askMessages(conversationId: id).map(\.seq), [3, 4, 5, 6])
      XCTAssertEqual(try store.askConversation(id: id)?.usage.turns, 3)
    }
  }

  func testFailureWritesNoAssistantAndCompletionTruncatesOnCharacterBoundary() throws {
    try withStore { store in
      var limits = AskLimits.standard
      limits.assistantMessageBytes = 4
      let id = try create(store).conversationId
      let failed = try begin(store, id)
      XCTAssertTrue(try store.finishAskTurn(conversationId: id, turnId: failed, status: .failed, assistantText: "discard", now: now))
      XCTAssertFalse(try store.finishAskTurn(conversationId: id, turnId: failed, status: .completed, assistantText: "late", now: now))
      XCTAssertEqual(try store.askMessages(conversationId: id).map(\.role), [.user])

      let done = try begin(store, id)
      let refs = [AskRef(kind: .session, id: "session")]
      XCTAssertTrue(try store.finishAskTurn(
        conversationId: id, turnId: done, status: .completed, assistantText: "a🇯🇵", citations: refs, limits: limits, now: now
      ))
      let reply = try XCTUnwrap(store.askMessages(conversationId: id).last)
      XCTAssertEqual(reply.text, "a")
      XCTAssertEqual(reply.citations, refs)
      XCTAssertTrue(reply.truncated)
    }
  }

  func testStoreRetentionKeepsRunningAndPrunesOldestInactive() throws {
    try withStore { store in
      var limits = AskLimits.standard
      limits.conversationsPerStore = 2
      let running = try create(store, limits: limits)
      _ = try begin(store, running.conversationId)
      let old = try create(store, limits: limits, offset: 1)
      let new = try create(store, limits: limits, offset: 2)
      XCTAssertEqual(try store.askConversations().map(\.conversationId), [new.conversationId, running.conversationId])
      XCTAssertNil(try store.askConversation(id: old.conversationId))
      _ = try begin(store, new.conversationId)
      assertCode("ask_budget_exceeded") { try create(store, limits: limits, offset: 3) }
      assertCode("ask_turn_running") { try store.removeAskConversation(id: running.conversationId) }
      XCTAssertEqual(try store.askConversations().count, 2)
    }
  }

  func testStaleHeartbeatFailsOnlyForAnotherRunner() throws {
    try withStore { store in
      let id = try create(store).conversationId
      let turn = try begin(store, id)
      let later = now.addingTimeInterval(60)
      XCTAssertFalse(try store.touchAskTurn(conversationId: id, turnId: turn, runnerId: "other", now: later))
      XCTAssertTrue(try store.touchAskTurn(conversationId: id, turnId: turn, runnerId: "runner", now: now.addingTimeInterval(30)))
      XCTAssertFalse(try store.failStaleAskTurn(conversationId: id, currentRunnerId: "other", now: later))
      XCTAssertFalse(try store.failStaleAskTurn(conversationId: id, currentRunnerId: "runner", now: later.addingTimeInterval(1)))
      XCTAssertTrue(try store.failStaleAskTurn(conversationId: id, currentRunnerId: "other", now: later.addingTimeInterval(1)))
      XCTAssertEqual(try store.askConversation(id: id)?.turn?.error?.code, "ask_interrupted")
      XCTAssertEqual(try store.askConversation(id: id)?.turn?.status, .failed)
      XCTAssertEqual(try store.askMessages(conversationId: id).map(\.role), [.user])
    }
  }

  func testToolBudgetPersistsAcrossStoreHandlesAndResetsPerTurnOnly() throws {
    try withStore { store in
      let other = BotStore(sessionStoreRoot: store.sessionStoreRoot)
      let id = try create(store).conversationId
      var limits = AskLimits.standard
      limits.toolCallsPerTurn = 1
      limits.toolCallsPerConversation = 2
      limits.toolBytesPerTurn = 5
      limits.toolBytesPerConversation = 6
      let turn = try begin(store, id)
      try store.reserveAskToolCall(conversationId: id, turnId: turn, limits: limits)
      assertCode("budget_exceeded") { try other.reserveAskToolCall(conversationId: id, turnId: turn, limits: limits) }
      XCTAssertFalse(try other.addAskToolBytes(conversationId: id, turnId: turn, bytes: 6, limits: limits))
      XCTAssertTrue(try other.addAskToolBytes(conversationId: id, turnId: turn, bytes: 5, limits: limits))
      try store.finishAskTurn(conversationId: id, turnId: turn, status: .completed, now: now)
      let next = try begin(other, id)
      try other.reserveAskToolCall(conversationId: id, turnId: next, limits: limits)
      XCTAssertFalse(try store.addAskToolBytes(conversationId: id, turnId: next, bytes: 2, limits: limits))
      XCTAssertTrue(try store.addAskToolBytes(conversationId: id, turnId: next, bytes: 1, limits: limits))
      let saved = try XCTUnwrap(store.askConversation(id: id))
      XCTAssertEqual(saved.usage, AskUsage(turns: 2, toolCalls: 2, toolBytes: 6))
      XCTAssertEqual(saved.turn?.toolBytes, 1)
      XCTAssertEqual(saved.turn?.toolCalls, 1)
    }
  }

  func testRemovalKeepsConfirmedAuditAndLeavesOtherActivityUntouched() async throws {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try create(store).conversationId
    let turn = try begin(store, id)
    let proposed = try store.insertAskAction(makeAction(conversationId: id, turnId: turn))
    let confirmed = try store.insertAskAction(makeAction(conversationId: id, turnId: turn))
    _ = try store.decideAskAction(conversationId: id, actionId: confirmed.actionId, decision: .confirm, decidedBy: "local", now: now)
    _ = try store.completeAskAction(actionId: confirmed.actionId, result: AskActionResult(ok: true), now: now)
    try store.finishAskTurn(conversationId: id, turnId: turn, status: .completed, now: now)

    let recorder = SQLiteWorkflowActivityRecorder(sessionStoreRoot: root.path)
    let key = AskActivityKey.sessionId(id)
    for sessionId in [key, "other"] {
      await recorder.stepStarted(sessionId: sessionId, executionId: turn, stepId: "ask", nodeId: "ask", backend: nil, requestedModel: nil, at: now)
      XCTAssertGreaterThan(try store.activityPage(sessionId: sessionId).lastSequence, 0)
    }
    try store.removeAskConversation(id: id)
    XCTAssertNil(try store.askConversation(id: id))
    XCTAssertEqual(try store.askMessages(conversationId: id), [])
    XCTAssertNil(try store.askAction(id: proposed.actionId))
    XCTAssertEqual(try store.askAction(id: confirmed.actionId)?.status, .confirmed)
    XCTAssertEqual(try store.askAction(id: confirmed.actionId)?.decidedBy, "local")
    XCTAssertEqual(try store.activityPage(sessionId: key).lastSequence, 0)
    XCTAssertGreaterThan(try store.activityPage(sessionId: "other").lastSequence, 0)
  }

  func testRemovalDuringConfirmationKeepsSuccessfulAuditOnly() throws {
    try withStore { store in
      let id = try create(store).conversationId
      let turn = try begin(store, id)
      let succeeds = try store.insertAskAction(makeAction(conversationId: id, turnId: turn))
      let fails = try store.insertAskAction(makeAction(conversationId: id, turnId: turn))
      for action in [succeeds, fails] {
        _ = try store.decideAskAction(conversationId: id, actionId: action.actionId, decision: .confirm, decidedBy: "local", now: now)
      }
      try store.finishAskTurn(conversationId: id, turnId: turn, status: .completed, now: now)
      try store.removeAskConversation(id: id)
      XCTAssertNil(try store.askConversation(id: id))
      XCTAssertEqual(try store.completeAskAction(actionId: succeeds.actionId, result: .init(ok: true), now: now).status, .confirmed)
      XCTAssertEqual(try store.completeAskAction(actionId: fails.actionId, result: .init(ok: false), now: now).status, .failed)
      XCTAssertEqual(try store.askActions(conversationId: id).map(\.actionId), [succeeds.actionId])
    }
  }

  private func makeAction(conversationId: String, turnId: String) -> AskAction {
    AskAction(
      conversationId: conversationId, turnId: turnId, kind: .setBotPaused, target: ["botId": .string("fixture"), "paused": .bool(true)],
      reason: "fixture", createdAt: RoutineStore.timestamp(now), expiresAt: RoutineStore.timestamp(now.addingTimeInterval(60))
    )
  }

  private func create(_ store: BotStore, limits: AskLimits = .standard, offset: TimeInterval = 0) throws -> AskConversation {
    try store.createAskConversation(context: AskContext(), selection: AskSelection(), firstMessage: "fixture", limits: limits, now: now.addingTimeInterval(offset))
  }

  private func begin(_ store: BotStore, _ id: String, message: String = "hello", limits: AskLimits = .standard) throws -> String {
    let record = try store.beginAskTurn(
      conversationId: id, message: message,
      turn: AskTurn(backend: "scripted", providerInstanceId: "fixture", toolTransport: .rounds, runnerId: "runner"),
      limits: limits, now: now
    )
    return try XCTUnwrap(record.turn?.turnId)
  }

  private func makeStore() -> (BotStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (BotStore(sessionStoreRoot: root.path), root)
  }

  private func withStore(_ body: (BotStore) throws -> Void) rethrows {
    let (store, root) = makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    try body(store)
  }

  private func assertCode<Result>(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ execute: () throws -> Result) {
    XCTAssertThrowsError(try execute(), file: file, line: line) {
      XCTAssertEqual(($0 as? AskError)?.code, code, file: file, line: line)
    }
  }
}
