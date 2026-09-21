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
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [decision])

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
    let cancel = Decision(
      id: DecisionID("cancel-decision"),
      taskId: task.id,
      attemptId: reservation.attempt.id,
      producer: .human(principal: "operator@example.com"),
      kind: .cancel,
      reason: "operator cancelled",
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

    let acknowledged = try store.acknowledgeAttemptCancellation(
      attemptId: reservation.attempt.id,
      outcome: AttemptOutcome(sessionStatus: .failed)
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
}
