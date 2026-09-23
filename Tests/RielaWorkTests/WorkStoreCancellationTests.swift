import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaWork

extension WorkStoreReservationTests {
  private struct TerminalSnapshotRejection {
    let status: WorkflowSessionStatus; let failureKind: WorkflowSessionFailureKind?; let outcome: AttemptOutcome
  }

  func testCancellationRetainsFenceUntilDurableAcknowledgment() throws {
    let store = WorkStore(rootDirectory: root.path)
    try store.saveTask(sampleTask())
    let reservation = try store.reserveAttempt(request(token: "cancel-token"))
    try store.saveDecision(Decision(
      id: DecisionID("cancel-decision"),
      taskId: reservation.task.id,
      attemptId: reservation.attempt.id,
      producer: .policy(rule: "cancel"),
      kind: .cancel,
      reason: "cancel live attempt",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    ))
    try store.requestAttemptCancellation(
      attemptId: reservation.attempt.id,
      decisionId: DecisionID("cancel-decision")
    )
    XCTAssertThrowsError(try store.reconcileAttempt(
      attemptId: reservation.attempt.id,
      outcome: AttemptOutcome(sessionStatus: .failed)
    ))
    XCTAssertThrowsError(try store.reserveAttempt(request(
      expectedVersion: 2,
      attemptId: "replacement",
      sessionId: "replacement-session",
      decisionId: "replacement-decision"
    )))
    XCTAssertThrowsError(try store.acknowledgeAttemptCancellation(
      attemptId: reservation.attempt.id,
      outcome: AttemptOutcome(sessionStatus: .created)
    )) { error in
      XCTAssertTrue(String(describing: error).contains("cancelled workflow snapshot"))
    }
    XCTAssertEqual(try store.loadAttempt(id: reservation.attempt.id)?.state, .prepared)
    XCTAssertEqual(try store.loadTask(id: reservation.task.id)?.state, .running)
    XCTAssertEqual(try SQLiteDatabase.open(
      path: store.databasePath, mode: .readOnly, options: .readOnlyDefault
    ).query("SELECT attempt_id FROM work_leases").count, 1)
    XCTAssertNil(try SQLiteDatabase.open(
      path: store.databasePath, mode: .readOnly, options: .readOnlyDefault
    ).query("SELECT acknowledged_at FROM work_cancellations WHERE attempt_id = 'attempt-1'").first?["acknowledged_at"])

    let completedSession = WorkflowSession(
      workflowId: "repair-workflow",
      sessionId: reservation.attempt.sessionId,
      status: .completed,
      entryStepId: "start",
      currentStepId: "finish",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_800_000_001)
    )
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).save(
      WorkflowRuntimePersistenceSnapshot(session: completedSession)
    )
    XCTAssertThrowsError(try store.acknowledgeAttemptCancellation(
      attemptId: reservation.attempt.id,
      outcome: AttemptOutcome(sessionStatus: .failed)
    )) { error in
      XCTAssertTrue(String(describing: error).contains("cancelled workflow snapshot"))
    }
    XCTAssertEqual(try store.loadAttempt(id: reservation.attempt.id)?.state, .prepared)
    XCTAssertEqual(try store.loadTask(id: reservation.task.id)?.state, .running)
    XCTAssertEqual(try SQLiteDatabase.open(
      path: store.databasePath, mode: .readOnly, options: .readOnlyDefault
    ).query("SELECT attempt_id FROM work_leases").count, 1)
    XCTAssertNil(try SQLiteDatabase.open(
      path: store.databasePath, mode: .readOnly, options: .readOnlyDefault
    ).query("SELECT acknowledged_at FROM work_cancellations WHERE attempt_id = 'attempt-1'").first?["acknowledged_at"])
    let unrelatedFailureSession = WorkflowSession(
      workflowId: "repair-workflow",
      sessionId: reservation.attempt.sessionId,
      status: .failed,
      entryStepId: "start",
      currentStepId: "finish",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_800_000_001),
      failureKind: .adapterFailure
    )
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).save(
      WorkflowRuntimePersistenceSnapshot(session: unrelatedFailureSession)
    )
    XCTAssertThrowsError(try store.acknowledgeAttemptCancellation(
      attemptId: reservation.attempt.id,
      outcome: AttemptOutcome(sessionStatus: .failed)
    )) { error in
      XCTAssertTrue(String(describing: error).contains("cancelled workflow snapshot"))
    }
    XCTAssertEqual(try store.loadAttempt(id: reservation.attempt.id)?.state, .prepared)
    XCTAssertEqual(try store.loadTask(id: reservation.task.id)?.state, .running)
    XCTAssertEqual(try SQLiteDatabase.open(
      path: store.databasePath, mode: .readOnly, options: .readOnlyDefault
    ).query("SELECT attempt_id FROM work_leases").count, 1)
    XCTAssertNil(try SQLiteDatabase.open(
      path: store.databasePath, mode: .readOnly, options: .readOnlyDefault
    ).query("SELECT acknowledged_at FROM work_cancellations WHERE attempt_id = 'attempt-1'").first?["acknowledged_at"])
    let terminalSession = WorkflowSession(
      workflowId: "repair-workflow",
      sessionId: reservation.attempt.sessionId,
      status: .failed,
      entryStepId: "start",
      currentStepId: "finish",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_800_000_001),
      failureKind: .cancelled
    )
    let gate = LoopGateResult(
      gateId: "verification",
      stepId: "verification",
      stepExecutionId: "verification-1",
      decision: .rejected
    )
    let cost = LoopCostEvidence(stepExecutionId: "verification-1", totalTokens: 7)
    let manifest = LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "cancellation-manifest",
      workflowId: "repair-workflow",
      sessionId: reservation.attempt.sessionId,
      workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow-directory", mutable: false),
      policy: LoopPolicyEvidence(),
      costs: [cost],
      gates: [gate],
      redaction: LoopRedactionSummary(policyName: "default", status: "clean"),
      createdAt: Date(timeIntervalSince1970: 1_800_000_001),
      updatedAt: Date(timeIntervalSince1970: 1_800_000_001)
    )
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).save(
      WorkflowRuntimePersistenceSnapshot(session: terminalSession, loopEvidence: manifest)
    )
    XCTAssertThrowsError(try store.acknowledgeAttemptCancellation(
      attemptId: reservation.attempt.id,
      outcome: AttemptOutcome(sessionStatus: .failed, failureKind: .adapterFailure)
    )) { error in
      XCTAssertTrue(String(describing: error).contains("cancelled workflow snapshot"))
    }
    XCTAssertEqual(try store.loadAttempt(id: reservation.attempt.id)?.state, .prepared)
    XCTAssertEqual(try SQLiteDatabase.open(
      path: store.databasePath, mode: .readOnly, options: .readOnlyDefault
    ).query("SELECT attempt_id FROM work_leases").count, 1)
    let forgedGateOutcome = AttemptOutcome(
      sessionStatus: .failed,
      failureKind: .cancelled,
      gateResults: [LoopGateResult(
        gateId: "verification",
        stepId: "verification",
        stepExecutionId: "verification-1",
        decision: .accepted
      )],
      costs: [cost]
    )
    XCTAssertThrowsError(try store.acknowledgeAttemptCancellation(
      attemptId: reservation.attempt.id,
      outcome: forgedGateOutcome
    )) { error in
      XCTAssertTrue(String(describing: error).contains("cancelled workflow snapshot"))
    }
    try assertCancellationRemainsPending(for: reservation, in: store)
    let forgedCostOutcome = AttemptOutcome(
      sessionStatus: .failed,
      failureKind: .cancelled,
      gateResults: [gate],
      costs: [LoopCostEvidence(stepExecutionId: "verification-1", totalTokens: 999)]
    )
    XCTAssertThrowsError(try store.acknowledgeAttemptCancellation(
      attemptId: reservation.attempt.id,
      outcome: forgedCostOutcome
    )) { error in
      XCTAssertTrue(String(describing: error).contains("cancelled workflow snapshot"))
    }
    try assertCancellationRemainsPending(for: reservation, in: store)
    let acknowledged = try store.acknowledgeAttemptCancellation(
      attemptId: reservation.attempt.id,
      outcome: AttemptOutcome(
        sessionStatus: .failed,
        failureKind: .cancelled,
        gateResults: [gate],
        costs: [cost]
      )
    )
    XCTAssertEqual(acknowledged.state, .reconciled)
    XCTAssertEqual(acknowledged.outcome?.gateResults, [gate])
    XCTAssertEqual(acknowledged.outcome?.costs, [cost])
    let persisted = try store.loadAttempt(id: reservation.attempt.id)
    XCTAssertEqual(persisted?.outcome?.sessionStatus, .failed)
    XCTAssertEqual(persisted?.outcome?.failureKind, .cancelled)
    XCTAssertEqual(persisted?.outcome?.gateResults, [gate])
    XCTAssertEqual(persisted?.outcome?.costs, [cost])
    XCTAssertEqual(try store.loadTask(id: reservation.task.id)?.state, .cancelled)
    XCTAssertEqual(try SQLiteDatabase.open(
      path: store.databasePath, mode: .readOnly, options: .readOnlyDefault
    ).query("SELECT attempt_id FROM work_leases").count, 0)
  }

  func testCancellationRequiresMatchingCancelDecisionAndAcknowledgmentFailsClosed() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    let foreignTask = sampleTask(id: "foreign-task")
    try store.saveTask(task)
    try store.saveTask(foreignTask)
    let reservation = try store.reserveAttempt(request(token: "cancel-token"))

    let nonCancel = Decision(
      id: DecisionID("non-cancel"), taskId: task.id, attemptId: reservation.attempt.id,
      producer: .policy(rule: "continue"), kind: .start, reason: "not cancellation",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let foreign = Decision(
      id: DecisionID("foreign-cancel"), taskId: foreignTask.id, attemptId: reservation.attempt.id,
      producer: .policy(rule: "cancel"), kind: .cancel, reason: "wrong task",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let wrongAttempt = Decision(
      id: DecisionID("wrong-attempt-cancel"), taskId: task.id, attemptId: AttemptID("other-attempt"),
      producer: .policy(rule: "cancel"), kind: .cancel, reason: "wrong attempt",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    try store.saveDecision(nonCancel)
    try store.saveDecision(foreign)
    try store.saveDecision(wrongAttempt)

    for decisionId in [DecisionID("missing"), nonCancel.id, foreign.id, wrongAttempt.id] {
      XCTAssertThrowsError(try store.requestAttemptCancellation(
        attemptId: reservation.attempt.id, decisionId: decisionId
      ))
    }
    let cancelledSession = WorkflowSession(
      workflowId: "repair-workflow",
      sessionId: reservation.attempt.sessionId,
      status: .failed,
      entryStepId: "start",
      currentStepId: "finish",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_800_000_001),
      failureKind: .cancelled
    )
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).save(
      WorkflowRuntimePersistenceSnapshot(session: cancelledSession)
    )
    let database = try store.openWritable()
    for decisionId in ["missing", nonCancel.id.rawValue, foreign.id.rawValue, wrongAttempt.id.rawValue] {
      try database.execute(
        "INSERT INTO work_cancellations (attempt_id, task_id, decision_id, requested_at) VALUES (?, ?, ?, ?)",
        bindings: [.text(reservation.attempt.id.rawValue), .text(task.id.rawValue), .text(decisionId), .text("2027-01-01T00:00:00Z")]
      )
      XCTAssertThrowsError(try store.acknowledgeAttemptCancellation(
        attemptId: reservation.attempt.id,
        outcome: AttemptOutcome(sessionStatus: .failed, failureKind: .cancelled)
      ))
      try database.execute(
        "DELETE FROM work_cancellations WHERE attempt_id = ?",
        bindings: [.text(reservation.attempt.id.rawValue)]
      )
    }
    XCTAssertEqual(try store.loadAttempt(id: reservation.attempt.id)?.state, .prepared)
    XCTAssertEqual(try store.loadTask(id: task.id)?.state, .running)
    let readOnly = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(try readOnly.query("SELECT attempt_id FROM work_leases").count, 1)
    XCTAssertEqual(try readOnly.query("SELECT attempt_id FROM work_cancellations"), [])
  }

  func testPendingCancellationBlocksAuthorizationAndNodeStart() throws {
    let preparedStore = WorkStore(rootDirectory: root.path)
    try preparedStore.saveTask(sampleTask())
    let prepared = try preparedStore.reserveAttempt(request(token: "prepared-token"))
    try preparedStore.saveDecision(cancellationDecision(for: prepared))
    try preparedStore.requestAttemptCancellation(attemptId: prepared.attempt.id, decisionId: DecisionID("cancel-decision"))
    XCTAssertThrowsError(try preparedStore.authorizeAttemptLaunch(
      attemptId: prepared.attempt.id, launchToken: prepared.launchToken
    )) { error in
      XCTAssertTrue(String(describing: error).contains("pending cancellation"))
    }
    XCTAssertEqual(try preparedStore.loadAttempt(id: prepared.attempt.id)?.state, .prepared)
    let preparedCounts = try pendingCancellationAndLeaseCount(for: preparedStore, attemptId: prepared.attempt.id)
    XCTAssertEqual(preparedCounts.cancellations, 1)
    XCTAssertEqual(preparedCounts.leases, 1)

    let runningRoot = root.appendingPathComponent("authorized-cancellation", isDirectory: true)
    let runningStore = WorkStore(rootDirectory: runningRoot.path)
    try runningStore.saveTask(sampleTask())
    let running = try runningStore.reserveAttempt(request(token: "running-token"))
    _ = try runningStore.authorizeAttemptLaunch(attemptId: running.attempt.id, launchToken: running.launchToken)
    try runningStore.saveDecision(cancellationDecision(for: running))
    try runningStore.requestAttemptCancellation(attemptId: running.attempt.id, decisionId: DecisionID("cancel-decision"))
    XCTAssertThrowsError(try runningStore.markAttemptNodeStarted(attemptId: running.attempt.id)) { error in
      XCTAssertTrue(String(describing: error).contains("pending cancellation"))
    }
    XCTAssertEqual(try runningStore.loadAttempt(id: running.attempt.id)?.launch?.phase, .authorized)
    let runningCounts = try pendingCancellationAndLeaseCount(for: runningStore, attemptId: running.attempt.id)
    XCTAssertEqual(runningCounts.cancellations, 1)
    XCTAssertEqual(runningCounts.leases, 1)
  }

  func testPendingCancellationBlocksPreLaunchRecovery() throws {
    let store = WorkStore(rootDirectory: root.path)
    try store.saveTask(sampleTask())
    let reservation = try store.reserveAttempt(request(token: "recovery-token"))
    try store.saveDecision(cancellationDecision(for: reservation))
    try store.requestAttemptCancellation(
      attemptId: reservation.attempt.id,
      decisionId: DecisionID("cancel-decision")
    )

    XCTAssertThrowsError(try store.recoverPreLaunchReservation(
      attemptId: reservation.attempt.id,
      launchToken: reservation.launchToken,
      expectedTaskVersion: reservation.task.version
    )) { error in
      XCTAssertTrue(String(describing: error).contains("pending cancellation"))
    }

    let attempt = try store.loadAttempt(id: reservation.attempt.id)
    XCTAssertEqual(attempt?.state, .prepared)
    XCTAssertEqual(attempt?.launch?.phase, .reserved)
    XCTAssertEqual(try store.loadTask(id: reservation.task.id)?.state, .running)
    let counts = try pendingCancellationAndLeaseCount(for: store, attemptId: reservation.attempt.id)
    XCTAssertEqual(counts.cancellations, 1)
    XCTAssertEqual(counts.leases, 1)
  }

  func testReconciliationRequiresMatchingTerminalSnapshot() throws {
    let store = WorkStore(rootDirectory: root.path)
    try store.saveTask(sampleTask())
    let reservation = try store.reserveAttempt(request(token: "terminal-token"))
    _ = try store.authorizeAttemptLaunch(
      attemptId: reservation.attempt.id,
      launchToken: reservation.launchToken
    )

    let rejectedSnapshots = [
      TerminalSnapshotRejection(status: .created, failureKind: nil, outcome: AttemptOutcome(sessionStatus: .completed)),
      TerminalSnapshotRejection(status: .running, failureKind: nil, outcome: AttemptOutcome(sessionStatus: .completed)),
      TerminalSnapshotRejection(status: .completed, failureKind: nil, outcome: AttemptOutcome(sessionStatus: .failed)),
      TerminalSnapshotRejection(
        status: .failed,
        failureKind: .adapterFailure,
        outcome: AttemptOutcome(sessionStatus: .failed, failureKind: .cancelled)
      )
    ]
    for rejection in rejectedSnapshots {
      try saveTerminalSnapshot(for: reservation, status: rejection.status, failureKind: rejection.failureKind)
      XCTAssertThrowsError(try store.reconcileAttempt(attemptId: reservation.attempt.id, outcome: rejection.outcome)) { error in
        XCTAssertTrue(String(describing: error).contains("matching terminal workflow snapshot"))
      }
      XCTAssertEqual(try store.loadAttempt(id: reservation.attempt.id)?.state, .running)
      XCTAssertEqual(try store.loadAttempt(id: reservation.attempt.id)?.launch?.phase, .authorized)
      XCTAssertNil(try store.loadAttempt(id: reservation.attempt.id)?.outcome)
      XCTAssertEqual(try store.loadTask(id: reservation.task.id)?.state, .running)
      XCTAssertEqual(try pendingCancellationAndLeaseCount(for: store, attemptId: reservation.attempt.id).leases, 1)
    }

    let date = Date(timeIntervalSince1970: 1_800_000_001)
    let gate = LoopGateResult(
      gateId: "verification",
      stepId: "verification",
      stepExecutionId: "verification-1",
      decision: .rejected
    )
    let cost = LoopCostEvidence(stepExecutionId: "verification-1", totalTokens: 7)
    let manifest = LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "reconciliation-manifest",
      workflowId: "repair-workflow",
      sessionId: reservation.attempt.sessionId,
      workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow-directory", mutable: false),
      policy: LoopPolicyEvidence(),
      costs: [cost],
      gates: [gate],
      redaction: LoopRedactionSummary(policyName: "default", status: "clean"),
      createdAt: date,
      updatedAt: date
    )
    try saveTerminalSnapshot(
      for: reservation,
      status: .failed,
      failureKind: .adapterFailure,
      loopEvidence: manifest
    )
    let forgedGateOutcome = AttemptOutcome(
      sessionStatus: .failed,
      failureKind: .adapterFailure,
      gateResults: [LoopGateResult(
        gateId: "verification",
        stepId: "verification",
        stepExecutionId: "verification-1",
        decision: .accepted
      )],
      costs: [cost]
    )
    XCTAssertThrowsError(try store.reconcileAttempt(attemptId: reservation.attempt.id, outcome: forgedGateOutcome)) { error in
      XCTAssertTrue(String(describing: error).contains("matching terminal workflow snapshot"))
    }
    try assertReconciliationRemainsFenced(for: reservation, in: store)
    let forgedCostOutcome = AttemptOutcome(
      sessionStatus: .failed,
      failureKind: .adapterFailure,
      gateResults: [gate],
      costs: [LoopCostEvidence(stepExecutionId: "verification-1", totalTokens: 999)]
    )
    XCTAssertThrowsError(try store.reconcileAttempt(attemptId: reservation.attempt.id, outcome: forgedCostOutcome)) { error in
      XCTAssertTrue(String(describing: error).contains("matching terminal workflow snapshot"))
    }
    try assertReconciliationRemainsFenced(for: reservation, in: store)

    let reconciled = try store.reconcileAttempt(
      attemptId: reservation.attempt.id,
      outcome: AttemptOutcome(
        sessionStatus: .failed,
        failureKind: .adapterFailure,
        gateResults: [gate],
        costs: [cost]
      )
    )
    XCTAssertEqual(reconciled.state, .reconciled)
    let persisted = try store.loadAttempt(id: reservation.attempt.id)
    XCTAssertEqual(persisted?.outcome?.sessionStatus, .failed)
    XCTAssertEqual(persisted?.outcome?.failureKind, .adapterFailure)
    XCTAssertEqual(persisted?.outcome?.gateResults, [gate])
    XCTAssertEqual(persisted?.outcome?.costs, [cost])
  }

  private func cancellationDecision(for reservation: AttemptReservation) -> Decision {
    Decision(
      id: DecisionID("cancel-decision"), taskId: reservation.task.id, attemptId: reservation.attempt.id,
      producer: .policy(rule: "cancel"), kind: .cancel, reason: "cancel live attempt",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
  }

  private func cancellationDecision(for result: AttemptReservationResult) -> Decision {
    guard let reservation = result.reservation else {
      preconditionFailure("cancellation fixture requires a reserved attempt")
    }
    return cancellationDecision(for: reservation)
  }

  private func pendingCancellationAndLeaseCount(for store: WorkStore, attemptId: AttemptID) throws -> (cancellations: Int, leases: Int) {
    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    let cancellations = try database.query(
      "SELECT attempt_id FROM work_cancellations WHERE attempt_id = ? AND acknowledged_at IS NULL",
      bindings: [.text(attemptId.rawValue)]
    ).count
    let leases = try database.query(
      "SELECT attempt_id FROM work_leases WHERE attempt_id = ?",
      bindings: [.text(attemptId.rawValue)]
    ).count
    return (cancellations, leases)
  }

  private func assertCancellationRemainsPending(
    for reservation: AttemptReservation,
    in store: WorkStore
  ) throws {
    XCTAssertEqual(try store.loadAttempt(id: reservation.attempt.id)?.state, .prepared)
    XCTAssertNil(try store.loadAttempt(id: reservation.attempt.id)?.outcome)
    XCTAssertEqual(try store.loadTask(id: reservation.task.id)?.state, .running)
    let counts = try pendingCancellationAndLeaseCount(for: store, attemptId: reservation.attempt.id)
    XCTAssertEqual(counts.cancellations, 1)
    XCTAssertEqual(counts.leases, 1)
  }

  private func assertCancellationRemainsPending(
    for result: AttemptReservationResult,
    in store: WorkStore
  ) throws {
    try assertCancellationRemainsPending(for: XCTUnwrap(result.reservation), in: store)
  }

  private func assertReconciliationRemainsFenced(for reservation: AttemptReservation, in store: WorkStore) throws {
    XCTAssertEqual(try store.loadAttempt(id: reservation.attempt.id)?.state, .running)
    XCTAssertEqual(try store.loadAttempt(id: reservation.attempt.id)?.launch?.phase, .authorized)
    XCTAssertNil(try store.loadAttempt(id: reservation.attempt.id)?.outcome)
    XCTAssertEqual(try store.loadTask(id: reservation.task.id)?.state, .running)
    XCTAssertEqual(try pendingCancellationAndLeaseCount(for: store, attemptId: reservation.attempt.id).leases, 1)
  }

  private func assertReconciliationRemainsFenced(for result: AttemptReservationResult, in store: WorkStore) throws {
    try assertReconciliationRemainsFenced(for: XCTUnwrap(result.reservation), in: store)
  }

  func saveTerminalSnapshot(
    for reservation: AttemptReservation,
    status: WorkflowSessionStatus,
    failureKind: WorkflowSessionFailureKind? = nil,
    loopEvidence: LoopEvidenceManifest? = nil
  ) throws {
    let session = WorkflowSession(
      workflowId: "repair-workflow",
      sessionId: reservation.attempt.sessionId,
      status: status,
      entryStepId: "start",
      currentStepId: "finish",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_800_000_001),
      failureKind: failureKind
    )
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).save(
      WorkflowRuntimePersistenceSnapshot(session: session, loopEvidence: loopEvidence)
    )
  }

  func saveTerminalSnapshot(
    for result: AttemptReservationResult,
    status: WorkflowSessionStatus,
    failureKind: WorkflowSessionFailureKind? = nil,
    loopEvidence: LoopEvidenceManifest? = nil
  ) throws {
    try saveTerminalSnapshot(for: XCTUnwrap(result.reservation), status: status, failureKind: failureKind, loopEvidence: loopEvidence)
  }

  func sampleTask(id: String = "task-1") -> WorkTask {
    WorkTask(
      id: TaskID(id),
      intentId: IntentID("intent-1"),
      title: "Repair task",
      instruction: "Run the repair workflow",
      plan: .workflow(WorkflowReference(name: "repair-workflow")),
      state: .ready
    )
  }

  func request(
    expectedVersion: Int = 1,
    attemptId: String = "attempt-1",
    sessionId: String = "session-1",
    decisionId: String = "decision-1",
    token: String? = nil
  ) -> AttemptReservationRequest {
    AttemptReservationRequest(
      taskId: TaskID("task-1"),
      expectedTaskVersion: expectedVersion,
      attemptId: AttemptID(attemptId),
      sessionId: sessionId,
      workflowId: "repair-workflow",
      entryStepId: "start",
      entry: .start,
      decisionId: DecisionID(decisionId),
      producer: .policy(rule: "start-ready-task"),
      reason: "ready task dispatch",
      launchToken: token,
      now: Date(timeIntervalSince1970: 1_800_000_000)
    )
  }
}
