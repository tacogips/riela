import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaWork

/// P0-3: schema creation, per-table CRUD, optimistic concurrency, filter
/// bounds, and the no-migration discard.
final class WorkStoreTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-work-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func makeStore() -> WorkStore {
    WorkStore(rootDirectory: root.path)
  }

  // MARK: - Schema

  func testSchemaIsCreatedOnAnEmptyDatabaseAndStampsTheRuntimeGeneration() throws {
    let store = makeStore()
    try store.saveIntent(sampleIntent())

    let db = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    for table in WorkStore.tableNames {
      XCTAssertTrue(try db.tableExists(table), "\(table) must exist after the first write")
    }
    XCTAssertEqual(
      try SQLiteSchemaMigrator.stampedGeneration(in: db),
      SQLiteWorkflowRuntimePersistenceStore.schemaGeneration,
      "the work tables live behind the runtime store's single user_version"
    )
  }

  func testReadsOnAMissingDatabaseAreEmptyRatherThanAnError() throws {
    let store = makeStore()
    XCTAssertEqual(try store.listTasks(), [])
    XCTAssertEqual(try store.listIntents(), [])
    XCTAssertNil(try store.loadTask(id: TaskID("task-absent")))
    XCTAssertEqual(try store.listEvidence(taskId: TaskID("task-absent")), [])
    XCTAssertEqual(try store.listFindings(taskId: TaskID("task-absent")), [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.databasePath))
  }

  func testTheWorkSchemaDoesNotTouchRuntimeTables() throws {
    let store = makeStore()
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let db = try SQLiteDatabase.open(path: store.databasePath, mode: .readWriteCreate, options: .writableDefault)
    try persistence.prepareSchema(in: db)
    try db.execute(
      """
      INSERT INTO workflow_runtime_snapshots
        (workflow_execution_id, session_json, diagnostics_json, created_at, updated_at)
      VALUES ('session-keep', jsonb('{"workflowId":"w","status":"completed"}'), jsonb('[]'), '2026-09-21', '2026-09-21')
      """
    )

    try store.saveTask(sampleTask())

    let rows = try SQLiteDatabase
      .open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
      .query("SELECT workflow_execution_id FROM workflow_runtime_snapshots")
    XCTAssertEqual(rows.compactMap { $0["workflow_execution_id"] }, ["session-keep"])
  }

  /// Design decision 12: no migration path means the store is discarded and
  /// recreated, never upgraded in place.
  func testAStoreAtAnOlderGenerationIsDiscardedAndRecreated() throws {
    let store = makeStore()
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: store.databasePath).deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let stale = try SQLiteDatabase.open(path: store.databasePath, mode: .readWriteCreate, options: .writableDefault)
    try stale.execute("CREATE TABLE workflow_runtime_snapshots (workflow_execution_id TEXT PRIMARY KEY)")
    try stale.execute("INSERT INTO workflow_runtime_snapshots VALUES ('stale-session')")
    try stale.execute("PRAGMA user_version = 4")

    XCTAssertFalse(
      SQLiteSchemaMigrator.hasCompletePath(
        from: 4,
        to: SQLiteWorkflowRuntimePersistenceStore.schemaGeneration,
        migrations: SQLiteWorkflowRuntimePersistenceStore.schemaMigrations
      ),
      "generation 4 must have no migration path, so the store is discarded"
    )

    try store.saveTask(sampleTask())

    let fresh = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(
      try SQLiteSchemaMigrator.stampedGeneration(in: fresh),
      SQLiteWorkflowRuntimePersistenceStore.schemaGeneration
    )
    XCTAssertFalse(
      try fresh.tableExists("workflow_runtime_snapshots"),
      "the stale database must be deleted, not upgraded"
    )
    XCTAssertEqual(try store.listTasks().map(\.id), [sampleTask().id])
  }

  func testGenerationSixPendingReservationSchemaIsDiscardedAndRecreated() throws {
    let store = makeStore()
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: store.databasePath).deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let stale = try SQLiteDatabase.open(path: store.databasePath, mode: .readWriteCreate, options: .writableDefault)
    try stale.execute("CREATE TABLE workflow_runtime_snapshots (workflow_execution_id TEXT PRIMARY KEY)")
    try stale.execute("CREATE TABLE work_pending_reservations (request_id TEXT PRIMARY KEY, task_id TEXT UNIQUE)")
    try stale.execute("PRAGMA user_version = 6")

    XCTAssertFalse(
      SQLiteSchemaMigrator.hasCompletePath(
        from: 6,
        to: SQLiteWorkflowRuntimePersistenceStore.schemaGeneration,
        migrations: SQLiteWorkflowRuntimePersistenceStore.schemaMigrations
      )
    )

    try store.saveTask(sampleTask())

    let rebuilt = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(try SQLiteSchemaMigrator.stampedGeneration(in: rebuilt), SQLiteWorkflowRuntimePersistenceStore.schemaGeneration)
    let indexes = try rebuilt.query("PRAGMA index_list('work_pending_reservations')")
    XCTAssertTrue(indexes.contains { $0["name"] == "idx_work_pending_reservations_one_unconsumed_task" })
    XCTAssertEqual(try store.listTasks().map(\.id), [sampleTask().id])
  }

  func testOnlyOneUnconsumedPendingReservationCanExistPerTask() throws {
    let store = makeStore()
    let task = sampleTask(state: .scheduled)
    try store.saveTask(task)
    let firstDecision = Decision(
      id: DecisionID("first-rerun-decision"),
      taskId: task.id,
      attemptId: AttemptID("first-predecessor"),
      producer: .policy(rule: "recover"),
      kind: .rerun(fromStepId: "repair"),
      reason: "first retry request",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    try store.saveDecision(firstDecision)
    XCTAssertThrowsError(try store.enqueuePendingReservation(PendingAttemptReservation(
      id: "wrong-predecessor-request",
      taskId: task.id,
      decisionId: firstDecision.id,
      predecessorAttemptId: AttemptID("wrong-predecessor"),
      entry: .rerunFromStep("repair")
    )))
    let firstRequest = PendingAttemptReservation(
      id: "first-pending-request",
      taskId: task.id,
      decisionId: firstDecision.id,
      predecessorAttemptId: firstDecision.attemptId,
      entry: .rerunFromStep("repair")
    )
    try store.enqueuePendingReservation(firstRequest)
    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    let firstRow = try XCTUnwrap(database.query(
      "SELECT request_id, decision_id, consumed_attempt_id FROM work_pending_reservations WHERE request_id = ?",
      bindings: [.text(firstRequest.id)]
    ).first)

    let secondDecision = Decision(
      id: DecisionID("second-rerun-decision"),
      taskId: task.id,
      attemptId: AttemptID("second-predecessor"),
      producer: .policy(rule: "recover"),
      kind: .rerun(fromStepId: "repair"),
      reason: "competing retry request",
      createdAt: Date(timeIntervalSince1970: 1_800_000_001)
    )
    try store.saveDecision(secondDecision)
    XCTAssertThrowsError(try store.enqueuePendingReservation(PendingAttemptReservation(
      id: "second-pending-request",
      taskId: task.id,
      decisionId: secondDecision.id,
      predecessorAttemptId: secondDecision.attemptId,
      entry: .rerunFromStep("repair")
    )))

    XCTAssertEqual(try database.query(
      "SELECT request_id, decision_id, consumed_attempt_id FROM work_pending_reservations WHERE task_id = ?",
      bindings: [.text(task.id.rawValue)]
    ), [firstRow])
  }

  func testReservationRejectsPersistedPendingRequestWithWrongPredecessor() throws {
    let store = makeStore()
    let task = sampleTask(state: .scheduled)
    try store.saveTask(task)
    let decision = Decision(
      id: DecisionID("rerun"), taskId: task.id, attemptId: AttemptID("predecessor"),
      producer: .policy(rule: "recover"), kind: .rerun(fromStepId: "repair"), reason: "retry", createdAt: Date()
    )
    try store.saveDecision(decision)
    try store.enqueuePendingReservation(PendingAttemptReservation(
      id: "pending", taskId: task.id, decisionId: decision.id,
      predecessorAttemptId: decision.attemptId, entry: .rerunFromStep("repair")
    ))
    let database = try store.openWritable()
    try database.execute("UPDATE work_pending_reservations SET predecessor_attempt_id = 'wrong' WHERE request_id = 'pending'")
    XCTAssertThrowsError(try store.reserveAttempt(AttemptReservationRequest(
      taskId: task.id, expectedTaskVersion: task.version, attemptId: AttemptID("attempt"),
      sessionId: "session", workflowId: "workflow", entryStepId: "repair", entry: .rerunFromStep("repair"),
      decisionId: decision.id, producer: .policy(rule: "recover"), reason: "retry", pendingRequestId: "pending"
    )))
    XCTAssertEqual(try store.listAttempts(taskId: task.id), [])
    XCTAssertEqual(try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault).query("SELECT attempt_id FROM work_leases"), [])
  }

  // MARK: - CRUD

  func testIntentUpsertLoadAndList() throws {
    let store = makeStore()
    var intent = sampleIntent()
    try store.saveIntent(intent)
    XCTAssertEqual(try store.loadIntent(id: intent.id), intent)

    intent.state = .fulfilled
    intent.title = "Vendor import fixed"
    try store.saveIntent(intent)
    XCTAssertEqual(try store.loadIntent(id: intent.id), intent)
    XCTAssertEqual(try store.listIntents().count, 1)
    XCTAssertEqual(try store.listIntents(state: .fulfilled), [intent])
    XCTAssertEqual(try store.listIntents(state: .open), [])
    XCTAssertNil(try store.loadIntent(id: IntentID("intent-missing")))
  }

  func testTaskUpsertLoadAndFilteredList() throws {
    let store = makeStore()
    let first = sampleTask()
    var second = sampleTask(id: TaskID("task-second"), state: .succeeded)
    second.plan = .workflow(WorkflowReference(name: "required-loop-gate-failure"))
    var third = sampleTask(id: TaskID("task-third"), state: .running)
    third.intentId = IntentID("intent-other")

    for task in [first, second, third] {
      try store.saveTask(task)
    }

    XCTAssertEqual(try store.loadTask(id: first.id), first)
    XCTAssertEqual(Set(try store.listTasks().map(\.id)), [first.id, second.id, third.id])
    XCTAssertEqual(try store.listTasks(filter: TaskListFilter(state: .succeeded)).map(\.id), [second.id])
    XCTAssertEqual(
      Set(try store.listTasks(filter: TaskListFilter(intentId: first.intentId)).map(\.id)),
      [first.id, second.id]
    )
    XCTAssertEqual(
      try store.listTasks(filter: TaskListFilter(workflowId: "required-loop-gate-failure")).map(\.id),
      [second.id]
    )
    XCTAssertEqual(try store.listTasks(filter: TaskListFilter(limit: 1)).count, 1)
  }

  func testTaskFilterColumnsAreGeneratedFromTheRecord() throws {
    let store = makeStore()
    var task = sampleTask()
    task.parentId = TaskID("task-parent")
    try store.saveTask(task)

    let row = try SQLiteDatabase
      .open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
      .query("SELECT intent_id, parent_id, state, workflow_id, version FROM work_tasks")
      .first
    XCTAssertEqual(row?["intent_id"], task.intentId.rawValue)
    XCTAssertEqual(row?["parent_id"], "task-parent")
    XCTAssertEqual(row?["state"], task.state.rawValue)
    XCTAssertEqual(row?["workflow_id"], "loop-engineer-quality-loop")
    XCTAssertEqual(row?["version"], String(task.version))
  }

  func testUpdateTaskBumpsTheVersionAndRejectsAStaleExpectation() throws {
    let store = makeStore()
    var task = sampleTask()
    try store.saveTask(task)

    task.state = .running
    let updated = try store.updateTask(task, expectedVersion: 1)
    XCTAssertEqual(updated.version, 2)
    XCTAssertEqual(try store.loadTask(id: task.id)?.version, 2)
    XCTAssertEqual(try store.loadTask(id: task.id)?.state, .running)

    // A second writer that still believes the task is at version 1 loses.
    var stale = task
    stale.state = .cancelled
    XCTAssertThrowsError(try store.updateTask(stale, expectedVersion: 1)) { error in
      guard let error = error as? WorkStoreError else {
        return XCTFail("expected a WorkStoreError, got \(error)")
      }
      XCTAssertTrue(error.isVersionConflict)
      XCTAssertTrue(error.message.contains(task.id.rawValue))
    }
    XCTAssertEqual(try store.loadTask(id: task.id)?.state, .running)

    // The winner's next update still succeeds from the new version.
    var next = updated
    next.state = .succeeded
    XCTAssertEqual(try store.updateTask(next, expectedVersion: 2).version, 3)
  }

  func testUpdatingAnAbsentTaskIsAVersionConflictNotASilentInsert() throws {
    let store = makeStore()
    try store.saveTask(sampleTask())
    let absent = sampleTask(id: TaskID("task-absent"))
    XCTAssertThrowsError(try store.updateTask(absent, expectedVersion: 1))
    XCTAssertNil(try store.loadTask(id: absent.id))
  }

  func testAttemptUpsertListAndUniqueSessionMapping() throws {
    let store = makeStore()
    let task = sampleTask()
    try store.saveTask(task)
    var attempt = Attempt(
      id: AttemptID("attempt-1"),
      taskId: task.id,
      sessionId: "session-1",
      entry: .start
    )
    try store.saveAttempt(attempt)
    attempt.state = .terminal
    attempt.outcome = AttemptOutcome(sessionStatus: .completed)
    try store.saveAttempt(attempt)

    XCTAssertEqual(try store.loadAttempt(id: attempt.id), attempt)
    XCTAssertEqual(try store.loadAttempt(sessionId: "session-1"), attempt)
    XCTAssertEqual(try store.listAttempts(taskId: task.id), [attempt])

    let duplicate = Attempt(id: AttemptID("attempt-2"), taskId: task.id, sessionId: "session-1")
    XCTAssertThrowsError(try store.saveAttempt(duplicate), "one session belongs to exactly one attempt")
  }

  func testDecisionUpsertAndListAreOrderedAndCarryFilterColumns() throws {
    let store = makeStore()
    let task = sampleTask()
    let first = Decision(
      id: DecisionID("decision-1"),
      taskId: task.id,
      attemptId: AttemptID("attempt-1"),
      producer: .policy(rule: "gate-rejected"),
      kind: .recover(fromGateId: "implementation-review"),
      reason: "gate rejected",
      createdAt: Date(timeIntervalSince1970: 1_000)
    )
    let second = Decision(
      id: DecisionID("decision-2"),
      taskId: task.id,
      producer: .human(principal: "tacogips"),
      kind: .accept,
      reason: "looks good",
      createdAt: Date(timeIntervalSince1970: 2_000)
    )
    try store.saveDecision(second)
    try store.saveDecision(first)

    XCTAssertEqual(try store.listDecisions(taskId: task.id).map(\.id), [first.id, second.id])
    let rows = try SQLiteDatabase
      .open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
      .query("SELECT decision_id, kind, producer_kind, attempt_id FROM work_decisions ORDER BY decision_id")
    XCTAssertEqual(rows.map { $0.string("kind") }, ["recover", "accept"])
    XCTAssertEqual(rows.map { $0.string("producer_kind") }, ["policy", "human"])
    XCTAssertEqual(rows.map { $0["attempt_id"] }, ["attempt-1", nil])
  }

  func testEvidenceIsWrittenInOneTransactionAndFiltersByKind() throws {
    let store = makeStore()
    let task = sampleTask()
    let gate = sampleEvidence(id: "evidence-gate", task: task.id, kind: .gate, at: 1_000)
    let finding = sampleEvidence(id: "evidence-finding", task: task.id, kind: .finding, at: 2_000)
    let cost = sampleEvidence(id: "evidence-cost", task: task.id, kind: .cost, at: 3_000)
    try store.saveEvidence([gate, finding, cost])

    XCTAssertEqual(try store.listEvidence(taskId: task.id).map(\.id), [gate.id, finding.id, cost.id])
    XCTAssertEqual(try store.listEvidence(taskId: task.id, kind: .finding), [finding])
    XCTAssertEqual(try store.listEvidence(taskId: TaskID("task-other")), [])
    XCTAssertEqual(try store.listEvidence(taskId: task.id, kind: .delivery), [])

    // Re-projecting the same attempt must be idempotent, not duplicated.
    try store.saveEvidence([gate, finding, cost])
    XCTAssertEqual(try store.listEvidence(taskId: task.id).count, 3)
  }

  func testFindingsAreKeyedByTaskAndFingerprint() throws {
    let store = makeStore()
    let task = sampleTask()
    var finding = sampleFinding(id: "review-1")
    try store.saveFindings([finding, sampleFinding(id: "review-2", severity: .low)], taskId: task.id)
    XCTAssertEqual(try store.listFindings(taskId: task.id).map(\.id), ["review-1", "review-2"])

    finding.status = .addressed
    try store.saveFindings([finding], taskId: task.id)
    XCTAssertEqual(try store.listFindings(taskId: task.id).count, 2)
    XCTAssertEqual(try store.listFindings(taskId: task.id, status: .open).map(\.id), ["review-2"])
    XCTAssertEqual(try store.listFindings(taskId: task.id, status: .addressed).map(\.id), ["review-1"])

    // The same fingerprint under another task is a different row.
    try store.saveFindings([finding], taskId: TaskID("task-second"))
    XCTAssertEqual(try store.listFindings(taskId: TaskID("task-second")).count, 1)
  }

  func testFindingFilterColumnsAreGeneratedFromTheRecord() throws {
    let store = makeStore()
    try store.saveFindings([sampleFinding(id: "review-1")], taskId: sampleTask().id)
    let row = try SQLiteDatabase
      .open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
      .query("SELECT severity, status, gate_id, fingerprint FROM work_findings")
      .first
    XCTAssertEqual(row?["severity"], "high")
    XCTAssertEqual(row?["status"], "open")
    XCTAssertEqual(row?["gate_id"], "implementation-review")
    XCTAssertEqual(row?["fingerprint"], "id:review-1")
  }

  // MARK: - Filter bounds

  func testListLimitBounds() throws {
    let store = makeStore()
    try store.saveTask(sampleTask())
    XCTAssertThrowsError(try store.listTasks(filter: TaskListFilter(limit: 0)))
    XCTAssertThrowsError(try store.listTasks(filter: TaskListFilter(limit: -1)))
    XCTAssertThrowsError(try store.listTasks(filter: TaskListFilter(limit: WorkStore.maximumListLimit + 1)))
    XCTAssertNoThrow(try store.listTasks(filter: TaskListFilter(limit: WorkStore.maximumListLimit)))
    XCTAssertThrowsError(try store.listIntents(limit: 0))
  }

  // MARK: - Samples

  private func sampleIntent() -> Intent {
    Intent(
      id: IntentID("intent-1"),
      title: "Vendor import drops rows",
      instruction: "Fix the vendor import.",
      acceptance: [AcceptanceCriterion(id: "criterion-1", statement: "no rows are dropped")],
      origin: .cli
    )
  }

  private func sampleTask(id: TaskID = TaskID("task-1"), state: TaskState = .ready) -> WorkTask {
    WorkTask(
      id: id,
      intentId: IntentID("intent-1"),
      title: "Fix the vendor importer",
      instruction: "Fix the vendor import.",
      plan: .workflow(WorkflowReference(name: "loop-engineer-quality-loop")),
      state: state
    )
  }

  private func sampleEvidence(
    id: String,
    task: TaskID,
    kind: EvidenceKind,
    at seconds: TimeInterval
  ) -> Evidence {
    Evidence(
      id: EvidenceID(id),
      taskId: task,
      attemptId: AttemptID("attempt-1"),
      kind: kind,
      producedBy: .runtime,
      payloadRef: .inline(["k": .string(kind.rawValue)]),
      createdAt: Date(timeIntervalSince1970: seconds)
    )
  }

  private func sampleFinding(id: String, severity: FindingSeverity = .high) -> Finding {
    let blocking = LoopBlockingFinding(id: id, severity: severity.rawValue, message: "m")
    return Finding(
      id: id,
      fingerprint: LoopFindingFingerprint.make(from: blocking),
      severity: severity,
      gateId: "implementation-review",
      sourceStepExecutionId: "exec-1",
      message: "m"
    )
  }
}
