import Foundation
import RielaWork
import XCTest

final class DecisionApplierTests: XCTestCase {
  func testPolicyAcceptFailsClosedWhenCompletionIsUnmet() {
    XCTAssertThrowsError(try DecisionApplier.apply(
      decision(.accept),
      to: task(),
      attempt: attempt(),
      completion: .unmet([.verificationMissing(name: "tests")])
    ))
  }

  func testHumanAcceptMaySatisfyOnlyTheHumanRequirement() throws {
    var human = decision(.accept)
    human.producer = .human(principal: "operator")
    let result = try DecisionApplier.apply(
      human,
      to: task(),
      attempt: attempt(),
      completion: .unmet([.humanAcceptRequired])
    )
    XCTAssertEqual(result.task.state, .succeeded)
    XCTAssertEqual(result.attempt?.state, .reconciled)

    XCTAssertThrowsError(try DecisionApplier.apply(
      human,
      to: task(),
      attempt: attempt(),
      completion: .unmet([.humanAcceptRequired, .acceptanceNotMet])
    ))
  }

  func testRerunReconcilesTheOldAttemptAndRequestsANewEntry() throws {
    let result = try DecisionApplier.apply(
      decision(.rerun(fromStepId: "agent")),
      to: task(),
      attempt: attempt(),
      completion: .unmet([])
    )
    XCTAssertEqual(result.task.state, .scheduled)
    XCTAssertEqual(result.attempt?.state, .reconciled)
    XCTAssertEqual(result.requestedEntry, .rerunFromStep("agent"))
  }

  func testStartRequiresAnExecutablePlan() {
    var value = task()
    value.plan = nil
    XCTAssertThrowsError(try DecisionApplier.apply(
      decision(.start, attemptId: nil),
      to: value,
      attempt: nil,
      completion: .unmet([])
    ))
  }

  func testHumanAndPolicyDecisionsUseTheSameTerminalTransitions() throws {
    let rows: [(DecisionKind, TaskState)] = [
      (.reject(reason: "no"), .failed),
      (.cancel, .cancelled),
      (.stop(GuardViolationRef(evidenceId: EvidenceID("guard"), summary: "limit")), .failed)
    ]
    for (kind, state) in rows {
      let result = try DecisionApplier.apply(
        decision(kind),
        to: task(),
        attempt: attempt(),
        completion: .unmet([])
      )
      XCTAssertEqual(result.task.state, state)
      XCTAssertEqual(result.attempt?.state, .reconciled)
    }
  }

  func testTerminalAndMismatchedTargetsAreRejected() {
    var terminal = task()
    terminal.state = .succeeded
    XCTAssertThrowsError(try DecisionApplier.apply(
      decision(.cancel),
      to: terminal,
      attempt: attempt(),
      completion: .satisfied
    ))

    var wrong = decision(.cancel)
    wrong.taskId = TaskID("other")
    XCTAssertThrowsError(try DecisionApplier.apply(
      wrong,
      to: task(),
      attempt: attempt(),
      completion: .unmet([])
    ))
  }

  private func task() -> WorkTask {
    WorkTask(
      id: TaskID("task-1"),
      intentId: IntentID("intent-1"),
      title: "Task",
      instruction: "Do it",
      plan: .workflow(WorkflowReference(name: "example")),
      state: .needsDecision,
      version: 2
    )
  }

  private func attempt() -> Attempt {
    Attempt(
      id: AttemptID("attempt-1"),
      taskId: TaskID("task-1"),
      sessionId: "session-1",
      state: .terminal
    )
  }

  private func decision(_ kind: DecisionKind, attemptId: AttemptID? = AttemptID("attempt-1")) -> Decision {
    Decision(
      id: DecisionID("decision-1"),
      taskId: TaskID("task-1"),
      attemptId: attemptId,
      producer: .policy(rule: "test"),
      kind: kind,
      reason: "test",
      createdAt: Date(timeIntervalSince1970: 1)
    )
  }
}
