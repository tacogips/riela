import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaWork

final class DecisionApplierStoreTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-work-decision-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testHumanAndPolicyDecisionsShareOptimisticReplaySafeApplier() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(
      id: TaskID("task-1"),
      intentId: IntentID("intent-1"),
      title: "Task",
      instruction: "Run",
      plan: .workflow(WorkflowReference(name: "workflow")),
      state: .verifying
    )
    try store.saveTask(task)
    let attempt = Attempt(
      id: AttemptID("attempt-1"),
      taskId: task.id,
      sessionId: "session-1",
      state: .terminal,
      outcome: AttemptOutcome(sessionStatus: .completed)
    )
    try store.saveAttempt(attempt)
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).save(
      WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
        workflowId: "workflow",
        sessionId: attempt.sessionId,
        status: .completed,
        entryStepId: "start",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
      ))
    )
    try store.saveEvidence(Evidence(
      id: EvidenceID("completion-evidence"), taskId: task.id, attemptId: attempt.id,
      kind: .gate, producedBy: .runtime, payloadRef: .inline([:]),
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    ))
    let decision = Decision(
      id: DecisionID("decision-1"),
      taskId: task.id,
      attemptId: attempt.id,
      producer: .human(principal: "operator@example.com"),
      kind: .accept,
      reason: "reviewed",
      causedBy: [EvidenceID("completion-evidence")],
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    XCTAssertThrowsError(try store.applyDecision(
      decision,
      expectedTaskVersion: 0,
      completion: .satisfied,
      decisionEvidenceId: EvidenceID("decision-evidence")
    ))
    let first = try store.applyDecision(
      decision,
      expectedTaskVersion: 1,
      completion: .satisfied,
      decisionEvidenceId: EvidenceID("decision-evidence")
    )
    XCTAssertEqual(first.task.state, .succeeded)
    XCTAssertEqual(first.task.version, 2)
    XCTAssertEqual(first.attempt?.state, .reconciled)

    let replay = try store.applyDecision(
      decision,
      expectedTaskVersion: 1,
      completion: .satisfied,
      decisionEvidenceId: EvidenceID("decision-evidence")
    )
    XCTAssertEqual(replay.task, first.task)
    XCTAssertEqual(replay, first)
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [decision])

    var retryWithNewTimestamp = decision
    retryWithNewTimestamp.createdAt = Date(timeIntervalSince1970: 1_800_000_999)
    XCTAssertEqual(
      try store.applyDecision(
        retryWithNewTimestamp,
        expectedTaskVersion: 1,
        completion: .unmet([]),
        decisionEvidenceId: EvidenceID("decision-evidence")
      ),
      first
    )
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [decision])

    var laterTask = first.task
    laterTask.state = .failed
    laterTask.version += 1
    try store.saveTask(laterTask)
    let reopenedReplay = try WorkStore(rootDirectory: root.path).applyDecision(
      decision, expectedTaskVersion: laterTask.version, completion: .unmet([]), decisionEvidenceId: EvidenceID("decision-evidence")
    )
    XCTAssertEqual(reopenedReplay, first)

    XCTAssertThrowsError(try store.applyDecision(
      decision, expectedTaskVersion: laterTask.version, completion: .unmet([]), decisionEvidenceId: EvidenceID("other")
    )) { error in
      XCTAssertTrue(String(describing: error).contains("causal evidence"))
    }

    var conflict = decision
    conflict.reason = "different delivery"
    XCTAssertThrowsError(try store.applyDecision(
      conflict,
      expectedTaskVersion: 2,
      completion: .satisfied,
      decisionEvidenceId: EvidenceID("different-evidence")
    )) { error in
      XCTAssertTrue(String(describing: error).contains("conflicts"))
    }
  }

  func testAcceptStillFailsClosedWhenCompletionIsUnmet() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(
      id: TaskID("task-1"),
      intentId: IntentID("intent-1"),
      title: "Task",
      instruction: "Run",
      plan: .workflow(WorkflowReference(name: "workflow")),
      state: .verifying
    )
    try store.saveTask(task)
    let decision = Decision(
      id: DecisionID("decision-1"),
      taskId: task.id,
      producer: .policy(rule: "completion-satisfied"),
      kind: .accept,
      reason: "incorrect",
      createdAt: Date()
    )
    XCTAssertThrowsError(try store.applyDecision(
      decision,
      expectedTaskVersion: 1,
      completion: .unmet([.verificationMissing(name: "tests")]),
      decisionEvidenceId: EvidenceID("decision-evidence")
    ))
    XCTAssertEqual(try store.loadTask(id: task.id), task)
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
  }

  func testAcceptRejectsMissingAndForeignCausalEvidence() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Task", instruction: "Run", state: .verifying)
    try store.saveTask(task)
    let attempt = Attempt(id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .terminal, outcome: AttemptOutcome(sessionStatus: .completed))
    try store.saveAttempt(attempt)
    let decision = Decision(id: DecisionID("decision-1"), taskId: task.id, attemptId: attempt.id, producer: .human(principal: "operator"), kind: .accept, reason: "reviewed", causedBy: [EvidenceID("missing")], createdAt: Date())
    XCTAssertThrowsError(try store.applyDecision(decision, expectedTaskVersion: task.version, completion: .satisfied, decisionEvidenceId: EvidenceID("decision-evidence")))
    try store.saveEvidence(Evidence(id: EvidenceID("foreign"), taskId: TaskID("other"), attemptId: attempt.id, kind: .gate, producedBy: .runtime, payloadRef: .inline([:]), createdAt: Date()))
    var foreign = decision
    foreign.causedBy = [EvidenceID("foreign")]
    XCTAssertThrowsError(try store.applyDecision(foreign, expectedTaskVersion: task.version, completion: .satisfied, decisionEvidenceId: EvidenceID("decision-evidence")))
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
  }

  func testDecisionRejectsCausalEvidenceFromAnotherAttemptOfTheSameTask() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Task", instruction: "Run", state: .verifying)
    try store.saveTask(task)
    let older = Attempt(id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .reconciled)
    let latest = Attempt(id: AttemptID("attempt-2"), taskId: task.id, sessionId: "session-2", state: .terminal, outcome: AttemptOutcome(sessionStatus: .completed))
    try store.saveAttempt(older)
    try store.saveAttempt(latest)
    try store.saveEvidence(Evidence(id: EvidenceID("older-evidence"), taskId: task.id, attemptId: older.id, kind: .gate, producedBy: .runtime, payloadRef: .inline([:]), createdAt: Date()))
    let decision = Decision(id: DecisionID("accept-latest"), taskId: task.id, attemptId: latest.id, producer: .human(principal: "operator"), kind: .accept, reason: "reviewed", causedBy: [EvidenceID("older-evidence")], createdAt: Date())

    XCTAssertThrowsError(try store.applyDecision(
      decision, expectedTaskVersion: task.version, completion: .satisfied,
      decisionEvidenceId: EvidenceID("decision-evidence")
    )) { error in
      XCTAssertTrue(String(describing: error).contains("outside the task attempt scope"))
    }
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
  }

  func testAgentDecisionReplayReturnsRecordedOutcomeAndRejectsChangedProducer() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Task", instruction: "Run", state: .ready)
    try store.saveTask(task)
    let decision = Decision(
      id: DecisionID("agent-wait"), taskId: task.id,
      producer: .agent(sessionId: "director-session"), kind: .wait(.human),
      reason: "needs operator", createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    let first = try store.applyDecision(
      decision, expectedTaskVersion: task.version, completion: .unmet([]),
      decisionEvidenceId: EvidenceID("agent-decision-evidence")
    )
    let replay = try store.applyDecision(
      decision, expectedTaskVersion: task.version, completion: .unmet([]),
      decisionEvidenceId: EvidenceID("agent-decision-evidence")
    )
    XCTAssertEqual(replay, first)

    var changed = decision
    changed.producer = .agent(sessionId: "different-session")
    XCTAssertThrowsError(try store.applyDecision(
      changed, expectedTaskVersion: task.version, completion: .unmet([]),
      decisionEvidenceId: EvidenceID("agent-decision-evidence")
    )) { error in
      XCTAssertTrue(String(describing: error).contains("conflicts"))
    }
  }

  func testAutomaticRerunRejectsMissingPersistedCausalEvidence() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(
      id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Task", instruction: "Run",
      plan: .workflow(WorkflowReference(name: "workflow")), state: .verifying
    )
    try store.saveTask(task)
    let attempt = Attempt(
      id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .terminal,
      outcome: AttemptOutcome(sessionStatus: .failed, failureKind: .adapterFailure)
    )
    try store.saveAttempt(attempt)
    let decision = Decision(
      id: DecisionID("automatic-rerun"), taskId: task.id, attemptId: attempt.id,
      producer: .policy(rule: "recoverable-attempt-failure"), kind: .rerun(fromStepId: "agent"),
      reason: "retry adapter failure", createdAt: Date()
    )

    XCTAssertThrowsError(try store.applyDecision(
      decision,
      expectedTaskVersion: task.version,
      completion: .unmet([]),
      decisionEvidenceId: EvidenceID("automatic-rerun-decision"),
      pendingReservation: PendingAttemptReservation(
        id: "pending-automatic-rerun", taskId: task.id, decisionId: decision.id,
        predecessorAttemptId: attempt.id, entry: .rerunFromStep("agent")
      )
    )) { error in
      XCTAssertTrue(String(describing: error).contains("requires causal evidence"))
    }
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
    XCTAssertEqual(try store.loadTask(id: task.id), task)
  }

  func testAcceptPropagatesCorruptRuntimeSnapshotAndRollsBack() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(
      id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Task", instruction: "Run",
      plan: .workflow(WorkflowReference(name: "workflow")), state: .verifying
    )
    try store.saveTask(task)
    let attempt = Attempt(
      id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .terminal,
      outcome: AttemptOutcome(sessionStatus: .completed)
    )
    try store.saveAttempt(attempt)
    let cause = Evidence(
      id: EvidenceID("completion-evidence"), taskId: task.id, attemptId: attempt.id,
      kind: .gate, producedBy: .runtime, payloadRef: .inline([:]), createdAt: Date()
    )
    try store.saveEvidence(cause)
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).save(
      WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
        workflowId: "workflow", sessionId: attempt.sessionId, status: .completed,
        entryStepId: "start", createdAt: Date(), updatedAt: Date()
      ))
    )
    try store.openWritable().execute(
      """
      UPDATE workflow_runtime_snapshots
      SET session_json = jsonb('{"workflowId":"workflow","status":"completed"}')
      WHERE workflow_execution_id = ?
      """,
      bindings: [.text(attempt.sessionId)]
    )
    let decision = Decision(
      id: DecisionID("accept-corrupt"), taskId: task.id, attemptId: attempt.id,
      producer: .human(principal: "operator"), kind: .accept, reason: "reviewed",
      causedBy: [cause.id], createdAt: Date()
    )

    XCTAssertThrowsError(try store.applyDecision(
      decision,
      expectedTaskVersion: task.version,
      completion: .satisfied,
      decisionEvidenceId: EvidenceID("accept-corrupt-decision")
    ))
    XCTAssertEqual(try store.loadTask(id: task.id), task)
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
    XCTAssertEqual(try store.listEvidence(taskId: task.id).map(\.id), [cause.id])
  }

  func testAcceptWithoutRuntimeSnapshotSucceedsWhenAcceptanceIsNotRequired() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(
      id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Task", instruction: "Run",
      plan: .workflow(WorkflowReference(name: "workflow")), state: .verifying
    )
    try store.saveTask(task)
    let attempt = Attempt(
      id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-without-snapshot", state: .terminal,
      outcome: AttemptOutcome(sessionStatus: .completed)
    )
    try store.saveAttempt(attempt)
    let cause = Evidence(
      id: EvidenceID("completion-evidence"), taskId: task.id, attemptId: attempt.id,
      kind: .gate, producedBy: .runtime, payloadRef: .inline([:]), createdAt: Date()
    )
    try store.saveEvidence(cause)
    let decision = Decision(
      id: DecisionID("accept-without-snapshot"), taskId: task.id, attemptId: attempt.id,
      producer: .human(principal: "operator"), kind: .accept, reason: "reviewed",
      causedBy: [cause.id], createdAt: Date()
    )

    let application = try store.applyDecision(
      decision,
      expectedTaskVersion: task.version,
      completion: .satisfied,
      decisionEvidenceId: EvidenceID("accept-without-snapshot-decision")
    )

    XCTAssertEqual(application.task.state, .succeeded)
    XCTAssertEqual(application.attempt?.state, .reconciled)
    XCTAssertEqual(try store.listDecisions(taskId: task.id).map(\.id), [decision.id])
  }

  func testAcceptRejectsFailedLatestAttemptEvenForAnEmptyContract() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(
      id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Task", instruction: "Run",
      plan: .workflow(WorkflowReference(name: "workflow")), state: .verifying
    )
    let attempt = Attempt(
      id: AttemptID("attempt-1"), taskId: task.id, sessionId: "failed-session", state: .terminal,
      outcome: AttemptOutcome(sessionStatus: .failed)
    )
    let cause = Evidence(
      id: EvidenceID("failed-attempt-evidence"), taskId: task.id, attemptId: attempt.id,
      kind: .gate, producedBy: .runtime, payloadRef: .inline([:]), createdAt: Date()
    )
    try store.saveTask(task)
    try store.saveAttempt(attempt)
    try store.saveEvidence(cause)
    let decision = Decision(
      id: DecisionID("accept-failed"), taskId: task.id, attemptId: attempt.id,
      producer: .human(principal: "operator"), kind: .accept, reason: "incorrect",
      causedBy: [cause.id], createdAt: Date()
    )

    XCTAssertThrowsError(try store.applyDecision(
      decision, expectedTaskVersion: task.version, completion: .satisfied,
      decisionEvidenceId: EvidenceID("accept-failed-evidence")
    ))
    XCTAssertEqual(try store.loadTask(id: task.id), task)
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
  }

  func testAcceptRejectsOlderAttemptAfterANewerAttemptExists() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Task", instruction: "Run", state: .verifying)
    try store.saveTask(task)
    let older = Attempt(id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .reconciled, outcome: AttemptOutcome(sessionStatus: .completed))
    let newer = Attempt(id: AttemptID("attempt-2"), taskId: task.id, sessionId: "session-2", state: .terminal, outcome: AttemptOutcome(sessionStatus: .failed))
    try store.saveAttempt(older)
    try store.saveAttempt(newer)
    try store.saveEvidence(Evidence(id: EvidenceID("older-evidence"), taskId: task.id, attemptId: older.id, kind: .gate, producedBy: .runtime, payloadRef: .inline([:]), createdAt: Date()))
    let decision = Decision(id: DecisionID("accept-old"), taskId: task.id, attemptId: older.id, producer: .human(principal: "operator"), kind: .accept, reason: "old success", causedBy: [EvidenceID("older-evidence")], createdAt: Date())

    XCTAssertThrowsError(try store.applyDecision(
      decision, expectedTaskVersion: task.version, completion: .satisfied,
      decisionEvidenceId: EvidenceID("decision-evidence")
    )) { error in
      XCTAssertTrue(String(describing: error).contains("latest attempt"))
    }
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
  }

  func testRerunDecisionAndPendingReservationCommitOrRollBackTogether() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(
      id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Task", instruction: "Run",
      plan: .workflow(WorkflowReference(name: "workflow")), state: .verifying
    )
    try store.saveTask(task)
    let attempt = Attempt(id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .terminal)
    try store.saveAttempt(attempt)
    let cause = Evidence(
      id: EvidenceID("rerun-cause"), taskId: task.id, attemptId: attempt.id,
      kind: .command, producedBy: .runtime, payloadRef: .inline([:]), createdAt: Date()
    )
    try store.saveEvidence(cause)
    let decision = Decision(
      id: DecisionID("rerun-decision"), taskId: task.id, attemptId: attempt.id,
      producer: .policy(rule: "recover"), kind: .rerun(fromStepId: "repair"),
      reason: "retry", causedBy: [cause.id], createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let request = PendingAttemptReservation(
      id: "pending-rerun", taskId: task.id, decisionId: decision.id,
      predecessorAttemptId: attempt.id, entry: .rerunFromStep("repair")
    )

    XCTAssertThrowsError(try store.applyDecision(
      decision, expectedTaskVersion: task.version, completion: .unmet([]),
      decisionEvidenceId: EvidenceID("decision-evidence"),
      pendingReservation: PendingAttemptReservation(
        id: "invalid", taskId: task.id, decisionId: decision.id,
        predecessorAttemptId: attempt.id, entry: .recoverFromGate("review")
      )
    ))
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [])

    let application = try store.applyDecision(
      decision, expectedTaskVersion: task.version, completion: .unmet([]),
      decisionEvidenceId: EvidenceID("decision-evidence"), pendingReservation: request
    )
    XCTAssertEqual(application.requestedEntry, .rerunFromStep("repair"))
    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(try database.query(
      "SELECT decision_id FROM work_pending_reservations WHERE request_id = 'pending-rerun'"
    ).first?["decision_id"], decision.id.rawValue)
    XCTAssertEqual(application.task.state, .scheduled)
    XCTAssertEqual(application.attempt?.state, .reconciled)
    XCTAssertEqual(try database.query("SELECT attempt_id FROM work_cancellations"), [])
  }

  func testRerunRollsBackWhenTheFinalDecisionEvidenceInsertFails() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(
      id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Task", instruction: "Run",
      plan: .workflow(WorkflowReference(name: "workflow")), state: .verifying
    )
    let attempt = Attempt(id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .terminal)
    let cause = Evidence(
      id: EvidenceID("rerun-cause"), taskId: task.id, attemptId: attempt.id,
      kind: .command, producedBy: .runtime, payloadRef: .inline([:]), createdAt: Date()
    )
    let duplicateDecisionEvidence = Evidence(
      id: EvidenceID("duplicate-decision-evidence"), taskId: task.id, attemptId: attempt.id,
      kind: .decision, producedBy: .runtime, payloadRef: .inline([:]), createdAt: Date()
    )
    try store.saveTask(task)
    try store.saveAttempt(attempt)
    try store.saveEvidence(cause)
    try store.saveEvidence(duplicateDecisionEvidence)
    let decision = Decision(
      id: DecisionID("rerun-decision"), taskId: task.id, attemptId: attempt.id,
      producer: .policy(rule: "recover"), kind: .rerun(fromStepId: "repair"),
      reason: "retry", causedBy: [cause.id], createdAt: Date()
    )
    let request = PendingAttemptReservation(
      id: "pending-rerun", taskId: task.id, decisionId: decision.id,
      predecessorAttemptId: attempt.id, entry: .rerunFromStep("repair")
    )

    XCTAssertThrowsError(try store.applyDecision(
      decision, expectedTaskVersion: task.version, completion: .unmet([]),
      decisionEvidenceId: duplicateDecisionEvidence.id, pendingReservation: request
    ))
    XCTAssertEqual(try store.loadTask(id: task.id), task)
    XCTAssertEqual(try store.loadAttempt(id: attempt.id), attempt)
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(try database.query("SELECT request_id FROM work_pending_reservations"), [])
    XCTAssertEqual(try database.query("SELECT decision_id FROM work_decision_applications"), [])
    XCTAssertEqual(
      Set(try store.listEvidence(taskId: task.id).map(\.id)),
      Set([cause.id, duplicateDecisionEvidence.id])
    )
  }

  func testRerunCannotBypassThePersistedAttemptBudget() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(
      id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Task", instruction: "Run",
      plan: .workflow(WorkflowReference(name: "workflow")),
      guardPolicy: GuardPolicy(budget: BudgetGuard(maxAttempts: 1)), state: .verifying
    )
    try store.saveTask(task)
    let attempt = Attempt(id: AttemptID("attempt-1"), taskId: task.id, sessionId: "session-1", state: .terminal)
    try store.saveAttempt(attempt)
    let decision = Decision(
      id: DecisionID("rerun-decision"), taskId: task.id, attemptId: attempt.id,
      producer: .human(principal: "operator"), kind: .rerun(fromStepId: "repair"),
      reason: "retry", createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    XCTAssertThrowsError(try store.applyDecision(
      decision, expectedTaskVersion: task.version, completion: .unmet([]),
      decisionEvidenceId: EvidenceID("decision-evidence"), pendingReservation: PendingAttemptReservation(
        id: "pending-rerun", taskId: task.id, decisionId: decision.id,
        predecessorAttemptId: attempt.id, entry: .rerunFromStep("repair")
      )
    ))
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
  }

  func testLiveDecisionRejectsAnAttemptFromAnotherTaskWithoutMutatingEitherTask() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Task", instruction: "Run", state: .ready)
    let foreignTask = WorkTask(id: TaskID("task-2"), intentId: IntentID("intent-1"), title: "Foreign", instruction: "Run", state: .running)
    let foreignAttempt = Attempt(id: AttemptID("attempt-2"), taskId: foreignTask.id, sessionId: "session-2", state: .running)
    try store.saveTask(task)
    try store.saveTask(foreignTask)
    try store.saveAttempt(foreignAttempt)
    let decision = Decision(
      id: DecisionID("foreign-cancel"), taskId: task.id, attemptId: foreignAttempt.id,
      producer: .human(principal: "operator"), kind: .cancel, reason: "cancel", createdAt: Date()
    )

    XCTAssertThrowsError(try store.applyDecision(
      decision, expectedTaskVersion: task.version, completion: .unmet([]),
      decisionEvidenceId: EvidenceID("foreign-cancel-evidence")
    )) { error in
      XCTAssertTrue(String(describing: error).contains("does not match the target task"))
    }
    XCTAssertEqual(try store.loadTask(id: task.id), task)
    XCTAssertEqual(try store.loadTask(id: foreignTask.id), foreignTask)
    XCTAssertEqual(try store.loadAttempt(id: foreignAttempt.id), foreignAttempt)
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
  }

  func testCancelDecisionRetainsLiveFenceUntilTerminalAcknowledgment() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = WorkTask(
      id: TaskID("task-1"),
      intentId: IntentID("intent-1"),
      title: "Task",
      instruction: "Run",
      plan: .workflow(WorkflowReference(name: "workflow")),
      state: .ready
    )
    try store.saveTask(task)
    let reservation = try store.reserveAttempt(AttemptReservationRequest(
      taskId: task.id,
      expectedTaskVersion: task.version,
      attemptId: AttemptID("attempt-1"),
      sessionId: "session-1",
      workflowId: "workflow",
      entryStepId: "start",
      entry: .start,
      decisionId: DecisionID("start-decision"),
      producer: .policy(rule: "start-ready-task"),
      reason: "start",
      launchToken: "launch-token"
    ))
    _ = try store.authorizeAttemptLaunch(
      attemptId: reservation.attempt.id,
      launchToken: reservation.launchToken
    )
    let cause = Evidence(
      id: EvidenceID("cancel-cause"), taskId: task.id, attemptId: reservation.attempt.id,
      kind: .command, producedBy: .runtime, payloadRef: .inline([:]),
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    try store.saveEvidence(cause)
    let cancel = Decision(
      id: DecisionID("cancel-decision"),
      taskId: task.id,
      attemptId: reservation.attempt.id,
      producer: .human(principal: "operator@example.com"),
      kind: .cancel,
      reason: "operator cancelled",
      causedBy: [cause.id],
      createdAt: Date(timeIntervalSince1970: 1_800_000_001)
    )

    let pending = try store.applyDecision(
      cancel,
      expectedTaskVersion: reservation.task.version,
      completion: .unmet([]),
      decisionEvidenceId: EvidenceID("cancel-evidence")
    )

    XCTAssertEqual(pending.task.state, .running)
    XCTAssertEqual(pending.task.version, 3)
    XCTAssertEqual(pending.attempt?.state, .running)
    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(try database.query("SELECT attempt_id FROM work_leases").count, 1)
    XCTAssertNil(try database.query(
      "SELECT acknowledged_at FROM work_cancellations WHERE attempt_id = 'attempt-1'"
    ).first?["acknowledged_at"])

    XCTAssertThrowsError(try store.acknowledgeAttemptCancellation(
      attemptId: reservation.attempt.id,
      outcome: AttemptOutcome(sessionStatus: .failed, failureKind: .cancelled)
    )) { error in
      XCTAssertTrue(String(describing: error).contains("matching cancelled workflow snapshot"))
    }
    XCTAssertEqual(try store.loadTask(id: task.id)?.state, .running)

    let terminalSession = WorkflowSession(
      workflowId: "workflow",
      sessionId: reservation.attempt.sessionId,
      status: .failed,
      entryStepId: "start",
      currentStepId: "finish",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_800_000_001),
      failureKind: .cancelled
    )
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).save(
      WorkflowRuntimePersistenceSnapshot(session: terminalSession)
    )

    let acknowledged = try store.acknowledgeAttemptCancellation(
      attemptId: reservation.attempt.id,
      outcome: AttemptOutcome(sessionStatus: .failed, failureKind: .cancelled)
    )
    XCTAssertEqual(acknowledged.state, .reconciled)
    XCTAssertEqual(try store.loadTask(id: task.id)?.state, .cancelled)
    XCTAssertEqual(try database.query("SELECT attempt_id FROM work_leases"), [])
    let cancellation = try XCTUnwrap(database.query(
      "SELECT acknowledged_at, terminal_status FROM work_cancellations WHERE attempt_id = 'attempt-1'"
    ).first)
    XCTAssertNotNil(cancellation["acknowledged_at"])
    XCTAssertEqual(cancellation["terminal_status"], "failed")
  }

  func testLiveActionsRetainFenceUntilAcknowledgmentAndPreserveReplacementRequests() throws {
    struct LiveActionCase {
      let name: String
      let kind: DecisionKind
      let entry: AttemptEntry?
      let terminalState: TaskState
    }
    let cases = [
      LiveActionCase(name: "stop", kind: .stop(GuardViolationRef(evidenceId: EvidenceID("guard"), summary: "limit")), entry: nil, terminalState: .failed),
      LiveActionCase(name: "reject", kind: .reject(reason: "rejected"), entry: nil, terminalState: .failed),
      LiveActionCase(name: "rerun", kind: .rerun(fromStepId: "repair"), entry: .rerunFromStep("repair"), terminalState: .scheduled),
      LiveActionCase(name: "recover", kind: .recover(fromGateId: "review"), entry: .recoverFromGate("review"), terminalState: .scheduled)
    ]
    for action in cases {
      let name = action.name
      let kind: DecisionKind = name == "stop"
        ? .stop(GuardViolationRef(evidenceId: EvidenceID("cause-stop"), summary: "limit"))
        : action.kind
      let entry = action.entry
      let terminalState = action.terminalState
      let caseRoot = root.appendingPathComponent(name, isDirectory: true)
      try FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: true)
      let store = WorkStore(rootDirectory: caseRoot.path)
      let task = WorkTask(
        id: TaskID("task-\(name)"), intentId: IntentID("intent-1"), title: "Task",
        instruction: "Run", plan: .workflow(WorkflowReference(name: "workflow")), state: .ready
      )
      try store.saveTask(task)
      let reservation = try store.reserveAttempt(AttemptReservationRequest(
        taskId: task.id, expectedTaskVersion: task.version, attemptId: AttemptID("attempt-\(name)"),
        sessionId: "session-\(name)", workflowId: "workflow", entryStepId: "start", entry: .start,
        decisionId: DecisionID("start-\(name)"), producer: .policy(rule: "start"), reason: "start",
        launchToken: "launch-\(name)"
      ))
      _ = try store.authorizeAttemptLaunch(attemptId: reservation.attempt.id, launchToken: reservation.launchToken)
      let cause = Evidence(
        id: EvidenceID("cause-\(name)"), taskId: task.id, attemptId: reservation.attempt.id,
        kind: name == "stop" ? .guardViolation : .command, producedBy: .runtime,
        payloadRef: .inline([:]), createdAt: Date(timeIntervalSince1970: 1_800_000_000)
      )
      try store.saveEvidence(cause)
      let decision = Decision(
        id: DecisionID("decision-\(name)"), taskId: task.id, attemptId: reservation.attempt.id,
        producer: .human(principal: "operator"), kind: kind, reason: name,
        causedBy: [cause.id],
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
      )
      let pendingReservation = entry.map {
        PendingAttemptReservation(
          id: "pending-\(name)", taskId: task.id, decisionId: decision.id,
          predecessorAttemptId: reservation.attempt.id, entry: $0
        )
      }

      let pending = try store.applyDecision(
        decision, expectedTaskVersion: reservation.task.version, completion: .unmet([]),
        decisionEvidenceId: EvidenceID("decision-evidence-\(name)"), pendingReservation: pendingReservation
      )
      XCTAssertEqual(pending.task.state, .running, name)
      XCTAssertEqual(pending.attempt?.state, .running, name)
      let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
      XCTAssertEqual(try database.query("SELECT attempt_id FROM work_leases").count, 1, name)
      XCTAssertEqual(try database.query("SELECT request_id FROM work_pending_reservations").count, entry == nil ? 0 : 1, name)

      try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: caseRoot.path).save(
        WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
          workflowId: "workflow", sessionId: reservation.attempt.sessionId, status: .failed,
          entryStepId: "start", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
          updatedAt: Date(timeIntervalSince1970: 1_800_000_001), failureKind: .cancelled
        ))
      )
      let acknowledged = try store.acknowledgeAttemptCancellation(
        attemptId: reservation.attempt.id,
        outcome: AttemptOutcome(sessionStatus: .failed, failureKind: .cancelled)
      )
      XCTAssertEqual(acknowledged.state, .reconciled, name)
      XCTAssertEqual(try store.loadTask(id: task.id)?.state, terminalState, name)
      XCTAssertEqual(try database.query("SELECT attempt_id FROM work_leases"), [], name)
      XCTAssertEqual(try database.query("SELECT request_id FROM work_pending_reservations").count, entry == nil ? 0 : 1, name)
    }
  }

  func testLiveActionsRequireTheLatestAttemptBeforeAnyMutation() throws {
    struct ActionCase {
      let name: String
      let kind: DecisionKind
      let entry: AttemptEntry?
    }
    let actions = [
      ActionCase(name: "cancel", kind: .cancel, entry: nil),
      ActionCase(name: "stop", kind: .stop(GuardViolationRef(evidenceId: EvidenceID("guard"), summary: "limit")), entry: nil),
      ActionCase(name: "reject", kind: .reject(reason: "rejected"), entry: nil),
      ActionCase(name: "rerun", kind: .rerun(fromStepId: "repair"), entry: .rerunFromStep("repair")),
      ActionCase(name: "recover", kind: .recover(fromGateId: "review"), entry: .recoverFromGate("review"))
    ]
    for action in actions {
      for reference in ["omitted", "stale"] {
        let caseRoot = root.appendingPathComponent("\(action.name)-\(reference)", isDirectory: true)
        try FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: true)
        let store = WorkStore(rootDirectory: caseRoot.path)
        let task = WorkTask(
          id: TaskID("task-\(action.name)-\(reference)"), intentId: IntentID("intent-1"), title: "Task",
          instruction: "Run", plan: .workflow(WorkflowReference(name: "workflow")), state: .ready
        )
        let older = Attempt(
          id: AttemptID("older-\(action.name)-\(reference)"), taskId: task.id,
          sessionId: "older-session", state: .reconciled, outcome: AttemptOutcome(sessionStatus: .failed)
        )
        try store.saveTask(task)
        try store.saveAttempt(older)
        let reservation = try store.reserveAttempt(AttemptReservationRequest(
          taskId: task.id, expectedTaskVersion: task.version,
          attemptId: AttemptID("aaa-newer-\(action.name)-\(reference)"), sessionId: "newer-session",
          workflowId: "workflow", entryStepId: "start", entry: .start,
          decisionId: DecisionID("start-\(action.name)-\(reference)"), producer: .policy(rule: "start"),
          reason: "start", launchToken: "launch-\(action.name)-\(reference)",
          now: Date(timeIntervalSince1970: 1)
        ))
        _ = try store.authorizeAttemptLaunch(
          attemptId: reservation.attempt.id, launchToken: reservation.launchToken
        )
        let attemptId = reference == "omitted" ? nil : older.id
        let decision = Decision(
          id: DecisionID("decision-\(action.name)-\(reference)"), taskId: task.id, attemptId: attemptId,
          producer: .human(principal: "operator"), kind: action.kind, reason: action.name, createdAt: Date()
        )
        let request = action.entry.map {
          PendingAttemptReservation(
            id: "pending-\(action.name)-\(reference)", taskId: task.id, decisionId: decision.id,
            predecessorAttemptId: attemptId, entry: $0
          )
        }
        let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readOnly, options: .readOnlyDefault)
        let beforeTask = try store.loadTask(id: task.id)
        let beforeOlder = try store.loadAttempt(id: older.id)
        let beforeNewer = try store.loadAttempt(id: reservation.attempt.id)
        let counts = try Self.mutationCounts(database)

        XCTAssertThrowsError(try store.applyDecision(
          decision, expectedTaskVersion: reservation.task.version, completion: .unmet([]),
          decisionEvidenceId: EvidenceID("decision-evidence-\(action.name)-\(reference)"), pendingReservation: request
        )) { error in
          XCTAssertTrue(String(describing: error).contains("latest attempt"), action.name + " " + reference)
        }
        XCTAssertEqual(try store.loadTask(id: task.id), beforeTask)
        XCTAssertEqual(try store.loadAttempt(id: older.id), beforeOlder)
        XCTAssertEqual(try store.loadAttempt(id: reservation.attempt.id), beforeNewer)
        XCTAssertEqual(try Self.mutationCounts(database), counts)
      }
    }
  }

  private static func mutationCounts(_ database: SQLiteDatabase) throws -> [Int] {
    try [
      "work_leases", "work_cancellations", "work_pending_reservations", "work_decisions",
      "work_decision_applications", "work_evidence"
    ].map { table in
      try database.query("SELECT COUNT(*) AS count FROM \(table)").first?["count"].flatMap(Int.init) ?? 0
    }
  }
}
