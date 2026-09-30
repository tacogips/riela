import Foundation
import RielaCore
import XCTest
@testable import RielaWork

final class DeterministicDirectorHandoverTests: XCTestCase {
  func testInactivityHandsOverWhenEnabledAndBudgetRemains() {
    let violation = GuardViolation.inactivity(stepId: "work", idleMs: 12_345)
    let result = DeterministicDirector.decide(input(
      rules: DeterministicDirectorRules(handoverOnInactivity: true),
      attemptCount: 1,
      guardEvidence: [evidence(violation, id: "idle")]
    ))

    XCTAssertEqual(result.kind, .handover(.inactivity(stepId: "work", idleMs: 12_345)))
    XCTAssertEqual(result.rule, "inactivity-handover")
    XCTAssertEqual(result.reason, violation.summary)
    XCTAssertEqual(result.causedBy, [EvidenceID("idle")])
  }

  func testDisabledInactivityHandoverPreservesRerunAndStopRules() {
    let violation = evidence(.inactivity(stepId: "work", idleMs: 500), id: "idle")
    let rerun = DeterministicDirector.decide(input(attemptCount: 1, guardEvidence: [violation]))
    XCTAssertEqual(rerun.rule, "inactivity-rerun")
    XCTAssertEqual(rerun.kind, .rerun(fromStepId: "work"))

    let stopped = DeterministicDirector.decide(input(
      rules: DeterministicDirectorRules(rerunOnInactivity: false),
      guardEvidence: [violation]
    ))
    XCTAssertEqual(stopped.rule, "inactivity-stop")
    XCTAssertEqual(stopped.kind, .stop(GuardViolationRef(evidenceId: EvidenceID("idle"), summary: violation.violation.summary)))
  }

  func testBudgetViolationPrecedesEnabledInactivityHandover() {
    let result = DeterministicDirector.decide(input(
      rules: DeterministicDirectorRules(handoverOnInactivity: true),
      attemptCount: 2,
      guardEvidence: [
        evidence(.inactivity(stepId: "work", idleMs: 500), id: "idle"),
        evidence(.budget(.attempts, used: 2, limit: 2), id: "budget")
      ]
    ))

    XCTAssertEqual(result.rule, "budget-exhausted")
    XCTAssertEqual(result.causedBy, [EvidenceID("budget")])
  }

  private func input(
    rules: DeterministicDirectorRules = DeterministicDirectorRules(),
    attemptCount: Int = 0,
    guardEvidence: [GuardViolationEvidence]
  ) -> DeterministicDirectorInput {
    DeterministicDirectorInput(
      task: WorkTask(
        id: TaskID("task-1"),
        intentId: IntentID("intent-1"),
        title: "Task",
        instruction: "Do it",
        guardPolicy: GuardPolicy(budget: BudgetGuard(maxAttempts: 2)),
        director: DirectorPolicy(deterministic: rules),
        state: .verifying
      ),
      attemptCount: attemptCount,
      guardEvidence: guardEvidence
    )
  }

  private func evidence(_ violation: GuardViolation, id: String) -> GuardViolationEvidence {
    GuardViolationEvidence(violation: violation, evidenceId: EvidenceID(id))
  }
}
