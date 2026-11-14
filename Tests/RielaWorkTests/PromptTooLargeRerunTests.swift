import XCTest
import RielaCore
@testable import RielaWork

final class PromptTooLargeRerunTests: XCTestCase {
  func testDirectorRerunsPromptTooLargeOnlyWhenAdapterFailureRerunsAreEnabled() {
    let enabled = DeterministicDirector.decide(input(rerunOnAdapterFailure: true))
    XCTAssertEqual(enabled.kind, .rerun(fromStepId: "agent"))

    let disabled = DeterministicDirector.decide(input(rerunOnAdapterFailure: false))
    XCTAssertNotEqual(disabled.kind, .rerun(fromStepId: "agent"))
  }

  func testAttemptsBudgetCountsPromptTooLargeLikeAdapterFailure() {
    let task = makeTask(rerunOnAdapterFailure: true, maxAttempts: 1)
    let attempt = Attempt(
      id: AttemptID("attempt-1"),
      taskId: task.id,
      sessionId: "session-1",
      state: .reconciled,
      outcome: AttemptOutcome(sessionStatus: .failed, failureKind: .promptTooLarge)
    )
    let violations = TaskGuardCoordinator.violations(
      task: task,
      latestAttempt: attempt,
      snapshot: GuardSnapshot(attemptCount: 1),
      terminal: true
    )

    XCTAssertTrue(violations.contains(.budget(.attempts, used: 1, limit: 1)))
  }

  private func input(rerunOnAdapterFailure: Bool) -> DeterministicDirectorInput {
    let task = makeTask(rerunOnAdapterFailure: rerunOnAdapterFailure, maxAttempts: 2)
    let attempt = Attempt(
      id: AttemptID("attempt-1"),
      taskId: task.id,
      sessionId: "session-1",
      state: .terminal,
      outcome: AttemptOutcome(sessionStatus: .failed, failureKind: .promptTooLarge)
    )
    return DeterministicDirectorInput(
      task: task,
      latestAttempt: attempt,
      attemptCount: 1,
      failedStepId: "agent",
      attemptFailureEvidenceId: EvidenceID("attempt-failure")
    )
  }

  private func makeTask(rerunOnAdapterFailure: Bool, maxAttempts: Int) -> WorkTask {
    WorkTask(
      id: TaskID("task-1"),
      intentId: IntentID("intent-1"),
      title: "Task",
      instruction: "Run",
      guardPolicy: GuardPolicy(budget: BudgetGuard(maxAttempts: maxAttempts)),
      director: DirectorPolicy(deterministic: DeterministicDirectorRules(
        rerunOnAdapterFailure: rerunOnAdapterFailure
      ))
    )
  }
}
