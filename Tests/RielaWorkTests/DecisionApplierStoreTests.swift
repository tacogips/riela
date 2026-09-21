import Foundation
import RielaCore
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
}
