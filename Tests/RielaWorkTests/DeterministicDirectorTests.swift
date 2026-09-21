import Foundation
import RielaCore
import RielaWork
import XCTest

final class DeterministicDirectorTests: XCTestCase {
  func testBudgetPrecedesConvergenceAndInactivity() {
    let result = DeterministicDirector.decide(input(
      guardEvidence: [
        evidence(.inactivity(stepId: "run", idleMs: 200), id: "idle"),
        evidence(.gateVisitsExceeded(gateId: "review", visits: 3), id: "convergence"),
        evidence(.budget(.tokens, used: 10, limit: 10), id: "budget")
      ]
    ))
    XCTAssertEqual(result.rule, "budget-exhausted")
    XCTAssertEqual(result.causedBy, [EvidenceID("budget")])
  }

  func testInactivityRerunsTheStalledStepWhenBudgetRemains() {
    let result = DeterministicDirector.decide(input(
      attemptCount: 1,
      guardEvidence: [evidence(.inactivity(stepId: "run", idleMs: 200), id: "idle")]
    ))
    XCTAssertEqual(result.kind, .rerun(fromStepId: "run"))
  }

  func testRecoverableFailureRerunsFromFailedStep() {
    let attempt = Attempt(
      id: AttemptID("attempt-1"),
      taskId: TaskID("task-1"),
      sessionId: "session-1",
      state: .terminal,
      outcome: AttemptOutcome(sessionStatus: .failed, failureKind: .adapterFailure)
    )
    let result = DeterministicDirector.decide(input(latestAttempt: attempt, failedStepId: "agent"))
    XCTAssertEqual(result.kind, .rerun(fromStepId: "agent"))
  }

  func testRejectedGateRecoversByGateIdentity() {
    let gate = LoopGateResult(
      gateId: "review",
      stepId: "review",
      stepExecutionId: "review-1",
      decision: .needsWork
    )
    let attempt = Attempt(
      id: AttemptID("attempt-1"),
      taskId: TaskID("task-1"),
      sessionId: "session-1",
      state: .terminal,
      outcome: AttemptOutcome(sessionStatus: .completed, gateResults: [gate])
    )
    XCTAssertEqual(
      DeterministicDirector.decide(input(latestAttempt: attempt)).kind,
      .recover(fromGateId: "review")
    )
  }

  func testSatisfiedCompletionAcceptsUnlessHumanAcceptanceIsRequired() {
    XCTAssertEqual(DeterministicDirector.decide(input(completion: .satisfied)).kind, .accept)
    var task = makeTask()
    task.completion.requiresHumanAccept = true
    XCTAssertEqual(
      DeterministicDirector.decide(DeterministicDirectorInput(
        task: task,
        completion: .unmet([.humanAcceptRequired])
      )).kind,
      .wait(.human)
    )
  }

  func testUnknownStateFailsSafeToHumanWait() {
    XCTAssertEqual(
      DeterministicDirector.decide(input(completion: .unmet([.acceptanceAbsent]))).kind,
      .wait(.human)
    )
  }

  private func input(
    latestAttempt: Attempt? = nil,
    attemptCount: Int = 0,
    failedStepId: String? = nil,
    completion: CompletionVerdict = .unmet([]),
    guardEvidence: [GuardViolationEvidence] = []
  ) -> DeterministicDirectorInput {
    DeterministicDirectorInput(
      task: makeTask(),
      latestAttempt: latestAttempt,
      attemptCount: attemptCount,
      failedStepId: failedStepId,
      completion: completion,
      guardEvidence: guardEvidence
    )
  }

  private func makeTask() -> WorkTask {
    WorkTask(
      id: TaskID("task-1"),
      intentId: IntentID("intent-1"),
      title: "Task",
      instruction: "Do it",
      guardPolicy: GuardPolicy(budget: BudgetGuard(maxAttempts: 2)),
      state: .verifying
    )
  }

  private func evidence(_ violation: GuardViolation, id: String) -> GuardViolationEvidence {
    GuardViolationEvidence(violation: violation, evidenceId: EvidenceID(id))
  }
}
