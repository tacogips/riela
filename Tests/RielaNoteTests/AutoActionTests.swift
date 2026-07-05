import Foundation
import RielaNote
import RielaSQLite
import XCTest

final class AutoActionTests: NoteTestCase {
  func testCreateNoteDispatchesSeededNoteCreatedActionAfterCommit() throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)

    let note = try service.createNote(bodyMarkdown: "# Auto\nBody")

    let records = dispatcher.records()
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records.first?.action.actionId, "default-ai-tagging-note-created")
    XCTAssertEqual(records.first?.event.trigger, .noteCreated)
    XCTAssertEqual(records.first?.event.noteId, note.noteId)
    XCTAssertEqual(records.first?.event.noteBodyMarkdown, note.bodyMarkdown)
    XCTAssertEqual(try service.getNote(note.noteId).noteId, note.noteId)
    let attempts = try service.listAutoActionDispatchAttempts()
    XCTAssertEqual(attempts.count, 1)
    XCTAssertEqual(attempts.first?.status, .dispatched)
    XCTAssertEqual(attempts.first?.attemptCount, 1)
  }

  func testUpdateNoteSuppressesAllDispatchWhenOriginatingActionIsSet() throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)
    let note = try service.createNote(bodyMarkdown: "# Auto\nBody")
    dispatcher.removeAll()
    _ = try service.configureAutoAction(
      actionId: "custom-update",
      trigger: .noteUpdated,
      workflowId: "custom-workflow",
      position: -1
    )

    _ = try service.updateNoteBody(
      noteId: note.noteId,
      bodyMarkdown: "# Auto\nChanged",
      originatingActionId: "custom-update"
    )

    XCTAssertTrue(dispatcher.records().isEmpty)
  }

  func testConfiguredAutoActionCanBeDeleted() throws {
    let service = try makeService()
    _ = try service.configureAutoAction(
      actionId: "temporary-action",
      trigger: .noteCreated,
      workflowId: "temporary-workflow"
    )
    XCTAssertTrue(try service.listAutoActions().contains { $0.actionId == "temporary-action" })

    try service.deleteAutoAction(actionId: "temporary-action")

    XCTAssertFalse(try service.listAutoActions().contains { $0.actionId == "temporary-action" })
    XCTAssertThrowsError(try service.deleteAutoAction(actionId: "temporary-action")) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("auto action not found: temporary-action"))
    }
  }

  func testCreateNoteSuppressesDispatchWhenOriginatingActionIsSet() throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)

    _ = try service.createNote(
      bodyMarkdown: "# Auto\nBody",
      originatingActionId: "workflow-action"
    )

    XCTAssertTrue(dispatcher.records().isEmpty)
  }

  func testDispatchFailureDoesNotFailOriginatingWrite() throws {
    let dispatcher = RecordingAutoActionDispatcher(shouldThrow: true)
    let service = try makeService(autoActionDispatcher: dispatcher)

    let note = try service.createNote(bodyMarkdown: "# Durable\nBody")

    XCTAssertEqual(try service.getNote(note.noteId).title, "Durable")
    XCTAssertEqual(dispatcher.records().count, 1)
    let attempts = try service.listAutoActionDispatchAttempts(status: .pending)
    XCTAssertEqual(attempts.count, 1)
    XCTAssertEqual(attempts.first?.record.event.noteId, note.noteId)
    XCTAssertEqual(attempts.first?.attemptCount, 1)
    XCTAssertNotNil(attempts.first?.lastError)
  }

  func testPendingAutoActionDispatchCanBeRetried() throws {
    let dispatcher = RecordingAutoActionDispatcher(failuresBeforeSuccess: 1)
    let service = try makeService(autoActionDispatcher: dispatcher)

    let note = try service.createNote(bodyMarkdown: "# Retry\nBody")

    XCTAssertEqual(try service.listAutoActionDispatchAttempts(status: .pending).count, 1)
    XCTAssertEqual(try service.retryPendingAutoActionDispatches(), 1)
    let attempts = try service.listAutoActionDispatchAttempts()
    XCTAssertEqual(attempts.count, 1)
    XCTAssertEqual(attempts.first?.record.event.noteId, note.noteId)
    XCTAssertEqual(attempts.first?.status, .dispatched)
    XCTAssertEqual(attempts.first?.attemptCount, 2)
    XCTAssertNil(attempts.first?.lastError)
    XCTAssertEqual(dispatcher.records().count, 2)
  }

  func testInFlightAutoActionDispatchCannotBeClaimedAgain() throws {
    let dispatcher = DelayedAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)

    _ = try service.createNote(bodyMarkdown: "# In Flight\nBody")

    XCTAssertEqual(dispatcher.records().count, 1)
    XCTAssertEqual(try service.listAutoActionDispatchAttempts(status: .inFlight).count, 1)
    XCTAssertEqual(try service.retryPendingAutoActionDispatches(), 0)
    XCTAssertEqual(dispatcher.records().count, 1)

    dispatcher.completeAll(.succeeded)

    let attempts = try service.listAutoActionDispatchAttempts()
    XCTAssertEqual(attempts.first?.status, .dispatched)
    XCTAssertEqual(attempts.first?.attemptCount, 1)
  }

  func testInterruptedInFlightAutoActionDispatchRecoversOnNextServiceInit() throws {
    let noteRoot = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: noteRoot)
    let delayedDispatcher = DelayedAutoActionDispatcher()
    let service = try NoteService(driver: driver, autoActionDispatcher: delayedDispatcher)

    _ = try service.createNote(bodyMarkdown: "# Interrupted\nBody")
    XCTAssertEqual(try service.listAutoActionDispatchAttempts(status: .inFlight).count, 1)

    let retryDispatcher = RecordingAutoActionDispatcher()
    let recoveredService = try NoteService(driver: driver, autoActionDispatcher: retryDispatcher)

    XCTAssertEqual(retryDispatcher.records().count, 1)
    let attempts = try recoveredService.listAutoActionDispatchAttempts()
    XCTAssertEqual(attempts.first?.status, .dispatched)
    XCTAssertEqual(attempts.first?.attemptCount, 2)
    XCTAssertNil(attempts.first?.lastError)
  }

  func testAutoActionRetryStopsAtMaximumAttempts() throws {
    let dispatcher = RecordingAutoActionDispatcher(shouldThrow: true)
    let service = try makeService(autoActionDispatcher: dispatcher)

    _ = try service.createNote(bodyMarkdown: "# Exhausted\nBody")
    XCTAssertEqual(try service.retryPendingAutoActionDispatches(), 1)
    XCTAssertEqual(try service.retryPendingAutoActionDispatches(), 1)
    XCTAssertEqual(try service.retryPendingAutoActionDispatches(), 0)

    let attempts = try service.listAutoActionDispatchAttempts(status: .pending)
    XCTAssertEqual(attempts.first?.attemptCount, 3)
    XCTAssertEqual(dispatcher.records().count, 3)
  }

  func testDeletedDefaultAutoActionDoesNotReappearAfterSchemaPrepare() throws {
    let service = try makeService()

    try service.deleteAutoAction(actionId: "default-ai-tagging-note-created")
    _ = try makeService()

    XCTAssertFalse(try service.listAutoActions().contains { $0.actionId == "default-ai-tagging-note-created" })
    XCTAssertTrue(try service.listAutoActions().contains { $0.actionId == "default-ai-tagging-note-updated" })
  }

  func testAutoActionNoteTagFilterRestrictsDispatch() throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)
    _ = try service.configureAutoAction(
      actionId: "tag-filtered",
      trigger: .noteCreated,
      workflowId: "tagged-workflow",
      filterJSON: #"{"noteTags":["dispatch-me"]}"#,
      position: 10
    )

    _ = try service.createNote(bodyMarkdown: "# Other\nBody")
    _ = try service.createNote(
      bodyMarkdown: "# Tagged\nBody",
      tags: [NoteTagInput(name: "dispatch-me", classId: "topic")]
    )

    XCTAssertEqual(
      dispatcher.records().map(\.action.actionId),
      [
        "default-ai-tagging-note-created",
        "default-ai-tagging-note-created",
        "tag-filtered"
      ]
    )
  }

  func testAutoActionNotebookKindFilterRestrictsDispatch() throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)
    _ = try service.configureAutoAction(
      actionId: "memo-kind",
      trigger: .notebookCreated,
      workflowId: "memo-workflow",
      filterJSON: #"{"notebookKindTag":"notebook-kind:user-memo"}"#
    )

    _ = try service.createNotebook(title: "Plain")
    _ = try service.createNotebook(title: "Memo", kindTagName: "notebook-kind:user-memo")

    XCTAssertEqual(dispatcher.records().map(\.action.actionId), ["memo-kind"])
  }

  func testSaveConversationDispatchesNotebookAndNoteCreatedActions() throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)
    _ = try service.configureAutoAction(
      actionId: "conversation-notebook",
      trigger: .notebookCreated,
      workflowId: "conversation-workflow",
      filterJSON: #"{"notebookKindTag":"notebook-kind:agent-conversation"}"#,
      position: -1
    )

    let saved = try service.saveConversation(
      title: "Agent Conversation",
      transcript: [
        NoteConversationTurn(userMarkdown: "Hi", assistantMarkdown: "Hello")
      ]
    )

    XCTAssertEqual(
      dispatcher.records().map(\.action.actionId),
      ["conversation-notebook", "default-ai-tagging-note-created"]
    )
    XCTAssertEqual(dispatcher.records().first?.event.notebookId, saved.notebook.notebookId)
    XCTAssertEqual(dispatcher.records().last?.event.noteId, saved.notes.first?.noteId)
    let attempts = try service.listAutoActionDispatchAttempts()
    XCTAssertEqual(attempts.map(\.status), [.dispatched, .dispatched])
  }

  func testAppendConversationTurnDispatchesNoteCreatedAction() throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)
    let saved = try service.saveConversation(
      title: "Agent Conversation",
      transcript: [NoteConversationTurn(userMarkdown: "Hi", assistantMarkdown: "Hello")]
    )
    dispatcher.removeAll()

    let appended = try service.appendConversationTurn(
      notebookId: saved.notebook.notebookId,
      turn: NoteConversationTurn(userMarkdown: "Again", assistantMarkdown: "Still here")
    )

    XCTAssertEqual(dispatcher.records().map(\.action.actionId), ["default-ai-tagging-note-created"])
    XCTAssertEqual(dispatcher.records().first?.event.noteId, appended.noteId)
  }

  func testConversationWritesSuppressDispatchWhenOriginatingActionIsSet() throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)

    let saved = try service.saveConversation(
      title: "Agent Conversation",
      transcript: [NoteConversationTurn(userMarkdown: "Hi", assistantMarkdown: "Hello")],
      originatingActionId: "workflow-action"
    )
    _ = try service.appendConversationTurn(
      notebookId: saved.notebook.notebookId,
      turn: NoteConversationTurn(userMarkdown: "Again", assistantMarkdown: "Still here"),
      originatingActionId: "workflow-action"
    )

    XCTAssertTrue(dispatcher.records().isEmpty)
    XCTAssertTrue(try service.listAutoActionDispatchAttempts().isEmpty)
  }

  func testConfigureAutoActionRejectsMalformedFilterShape() throws {
    let service = try makeService()

    XCTAssertThrowsError(try service.configureAutoAction(
      actionId: "bad-filter",
      trigger: .noteCreated,
      workflowId: "bad-workflow",
      filterJSON: #"{"noteTags":"dispatch-me"}"#
    )) { error in
      guard case let NoteServiceError.invalidInput(message) = error else {
        return XCTFail("expected invalid input, got \(error)")
      }
      XCTAssertTrue(message.contains("invalid auto action filter JSON"))
    }
  }

  func testLegacyMalformedAutoActionFilterDoesNotSuppressOtherDispatches() throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let diagnostics = RecordingNoteAutoActionDiagnostics()
    let service = try makeService(autoActionDispatcher: dispatcher, autoActionDiagnosticRecorder: diagnostics)
    try insertLegacyAutoAction(
      service: service,
      actionId: "legacy-bad-filter",
      filterJSON: #"{"noteTags":"dispatch-me"}"#,
      position: -10
    )
    _ = try service.configureAutoAction(
      actionId: "good-filtered",
      trigger: .noteCreated,
      workflowId: "good-workflow",
      filterJSON: #"{"noteTags":["dispatch-me"]}"#,
      position: 10
    )

    _ = try service.createNote(
      bodyMarkdown: "# Tagged\nBody",
      tags: [NoteTagInput(name: "dispatch-me", classId: "topic")]
    )

    XCTAssertEqual(
      dispatcher.records().map(\.action.actionId),
      ["default-ai-tagging-note-created", "good-filtered"]
    )
    XCTAssertEqual(diagnostics.records().map(\.actionId), ["legacy-bad-filter"])
    XCTAssertEqual(diagnostics.records().first?.code, .filterEvaluationFailed)
    XCTAssertTrue(diagnostics.records().first?.message.contains("filter_json") == true)
  }
}

private func makeService(
  function: String = #function,
  autoActionDispatcher: AutoActionDispatching? = nil,
  autoActionDiagnosticRecorder: NoteAutoActionFilterDiagnosticRecording? = nil
) throws -> NoteService {
  try NoteService(
    driver: try makeNoteDriver(function: function),
    autoActionDispatcher: autoActionDispatcher,
    autoActionDiagnosticRecorder: autoActionDiagnosticRecorder
  )
}

private func insertLegacyAutoAction(
  service: NoteService,
  actionId: String,
  filterJSON: String,
  position: Int
) throws {
  try service.driver.withDatabase { database in
    try database.execute(
      """
      INSERT INTO auto_actions (
        action_id, trigger, workflow_id, filter_json, enabled, position, created_at
      ) VALUES (?, ?, ?, jsonb(?), 1, ?, ?)
      """,
      bindings: [
        .text(actionId),
        .text(NoteAutoActionTrigger.noteCreated.rawValue),
        .text("legacy-workflow"),
        .text(filterJSON),
        .int(Int64(position)),
        .text("2026-07-04T00:00:00Z")
      ]
    )
  }
}

private final class RecordingAutoActionDispatcher: AutoActionDispatching, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [AutoActionDispatchRecord] = []
  private var remainingFailures: Int

  init(shouldThrow: Bool = false, failuresBeforeSuccess: Int = 0) {
    remainingFailures = shouldThrow ? Int.max : failuresBeforeSuccess
  }

  func dispatch(
    _ record: AutoActionDispatchRecord,
    completion: @escaping @Sendable (AutoActionDispatchOutcome) -> Void
  ) throws {
    lock.lock()
    recorded.append(record)
    let shouldThrow = remainingFailures > 0
    if remainingFailures > 0 {
      remainingFailures -= 1
    }
    lock.unlock()
    if shouldThrow {
      throw NSError(domain: "RecordingAutoActionDispatcher", code: 1)
    }
    completion(.succeeded)
  }

  func records() -> [AutoActionDispatchRecord] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func removeAll() {
    lock.lock()
    recorded.removeAll()
    lock.unlock()
  }
}

private final class DelayedAutoActionDispatcher: AutoActionDispatching, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [AutoActionDispatchRecord] = []
  private var completions: [@Sendable (AutoActionDispatchOutcome) -> Void] = []

  func dispatch(
    _ record: AutoActionDispatchRecord,
    completion: @escaping @Sendable (AutoActionDispatchOutcome) -> Void
  ) throws {
    lock.lock()
    recorded.append(record)
    completions.append(completion)
    lock.unlock()
  }

  func records() -> [AutoActionDispatchRecord] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func completeAll(_ outcome: AutoActionDispatchOutcome) {
    lock.lock()
    let pending = completions
    completions.removeAll()
    lock.unlock()
    for completion in pending {
      completion(outcome)
    }
  }
}

private final class RecordingNoteAutoActionDiagnostics: NoteAutoActionFilterDiagnosticRecording, @unchecked Sendable {
  private let lock = NSLock()
  private var diagnostics: [NoteAutoActionDiagnostic] = []

  func record(_ diagnostic: NoteAutoActionDiagnostic) {
    lock.lock()
    diagnostics.append(diagnostic)
    lock.unlock()
  }

  func records() -> [NoteAutoActionDiagnostic] {
    lock.lock()
    defer { lock.unlock() }
    return diagnostics
  }
}
