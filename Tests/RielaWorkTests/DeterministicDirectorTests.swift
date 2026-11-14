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

  func testViolationSelectionIsIndependentOfCallerOrder() {
    let evidence = [
      evidence(.budget(.wallClock, used: 10, limit: 10), id: "wall"),
      evidence(.budget(.tokens, used: 10, limit: 10), id: "tokens")
    ]
    let forward = DeterministicDirector.decide(input(guardEvidence: evidence))
    let reverse = DeterministicDirector.decide(input(guardEvidence: evidence.reversed()))
    XCTAssertEqual(forward, reverse)
    XCTAssertEqual(forward.causedBy, [EvidenceID("tokens")])
  }

  func testConvergenceSelectionUsesViolationKindBeforeEvidenceID() {
    let visits = evidence(.gateVisitsExceeded(gateId: "review", visits: 3), id: "z-visits")
    let repeated = evidence(.repeatedFindings(gateId: "review", rounds: 3), id: "a-repeated")
    let forward = DeterministicDirector.decide(input(guardEvidence: [repeated, visits]))
    let reverse = DeterministicDirector.decide(input(guardEvidence: [visits, repeated]))

    XCTAssertEqual(forward, reverse)
    XCTAssertEqual(forward.causedBy, [visits.evidenceId])
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
    let result = DeterministicDirector.decide(input(
      latestAttempt: attempt,
      failedStepId: "agent",
      attemptFailureEvidenceId: EvidenceID("attempt-failure")
    ))
    XCTAssertEqual(result.kind, .rerun(fromStepId: "agent"))
    XCTAssertEqual(result.causedBy, [EvidenceID("attempt-failure")])
  }

  func testRecoverableFailureWithoutPersistedEvidenceWaitsForHuman() {
    let attempt = Attempt(
      id: AttemptID("attempt-1"),
      taskId: TaskID("task-1"),
      sessionId: "session-1",
      state: .terminal,
      outcome: AttemptOutcome(sessionStatus: .failed, failureKind: .adapterFailure)
    )
    XCTAssertEqual(
      DeterministicDirector.decide(input(latestAttempt: attempt, failedStepId: "agent")).kind,
      .wait(.human)
    )
  }

  func testFailedAttemptCannotFallThroughToCompletionAcceptance() {
    let attempt = Attempt(
      id: AttemptID("attempt-1"), taskId: TaskID("task-1"), sessionId: "session-1", state: .terminal,
      outcome: AttemptOutcome(sessionStatus: .failed, failureKind: .adapterFailure)
    )
    XCTAssertEqual(
      DeterministicDirector.decide(input(latestAttempt: attempt, completion: .satisfied)).kind,
      .wait(.human)
    )
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
      DeterministicDirector.decide(input(
        latestAttempt: attempt,
        gateEvidenceIds: ["review": EvidenceID("gate-review")]
      )).kind,
      .recover(fromGateId: "review")
    )
    XCTAssertEqual(
      DeterministicDirector.decide(input(
        latestAttempt: attempt,
        gateEvidenceIds: ["review": EvidenceID("gate-review")]
      )).causedBy,
      [EvidenceID("gate-review")]
    )
  }

  func testRejectedGateWaitsWhenNoAttemptCapacityRemains() {
    let gate = LoopGateResult(
      gateId: "review", stepId: "review", stepExecutionId: "review-1", decision: .needsWork
    )
    let attempt = Attempt(
      id: AttemptID("attempt-1"), taskId: TaskID("task-1"), sessionId: "session-1", state: .terminal,
      outcome: AttemptOutcome(sessionStatus: .completed, gateResults: [gate])
    )
    XCTAssertEqual(
      DeterministicDirector.decide(input(latestAttempt: attempt, attemptCount: 2)).kind,
      .wait(.human)
    )
  }

  func testRejectedGateWithoutPersistedEvidenceWaitsForHuman() {
    let gate = LoopGateResult(
      gateId: "review", stepId: "review", stepExecutionId: "review-1", decision: .needsWork
    )
    let attempt = Attempt(
      id: AttemptID("attempt-1"), taskId: TaskID("task-1"), sessionId: "session-1", state: .terminal,
      outcome: AttemptOutcome(sessionStatus: .completed, gateResults: [gate])
    )
    XCTAssertEqual(
      DeterministicDirector.decide(input(latestAttempt: attempt)).kind,
      .wait(.human)
    )
  }

  func testSatisfiedCompletionAcceptsUnlessHumanAcceptanceIsRequired() {
    XCTAssertEqual(
      DeterministicDirector.decide(input(completion: .satisfied)).kind,
      .wait(.human)
    )
    let completionEvidenceId = EvidenceID("completion")
    let acceptance = DeterministicDirector.decide(input(
      completion: .satisfied,
      completionEvidenceIds: [completionEvidenceId]
    ))
    XCTAssertEqual(acceptance.kind, .accept)
    XCTAssertEqual(acceptance.causedBy, [completionEvidenceId])
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
    attemptFailureEvidenceId: EvidenceID? = nil,
    gateEvidenceIds: [String: EvidenceID] = [:],
    completion: CompletionVerdict = .unmet([]),
    completionEvidenceIds: [EvidenceID] = [],
    guardEvidence: [GuardViolationEvidence] = []
  ) -> DeterministicDirectorInput {
    DeterministicDirectorInput(
      task: makeTask(),
      latestAttempt: latestAttempt,
      attemptCount: attemptCount,
      failedStepId: failedStepId,
      attemptFailureEvidenceId: attemptFailureEvidenceId,
      gateEvidenceIds: gateEvidenceIds,
      completion: completion,
      completionEvidenceIds: completionEvidenceIds,
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
