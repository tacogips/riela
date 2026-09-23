import RielaWork
import XCTest

final class WorkGuardTests: XCTestCase {
  func testEvaluatesEveryDetectorInStablePrecedenceOrder() {
    let policy = GuardPolicy(
      inactivity: InactivityGuard(
        stallTimeoutMs: 100,
        monitorIntervalMs: 10,
        heartbeatBackends: ["codex-agent"]
      ),
      convergence: ConvergenceGuard(maxGateVisits: 2, maxRepeatedFindingRounds: 3),
      budget: BudgetGuard(maxAttempts: 2, maxTotalTokens: 10, maxWallClockMs: 20, maxProposals: 1)
    )
    let violations = WorkGuard.evaluate(
      policy: policy,
      snapshot: GuardSnapshot(
        attemptCount: 2,
        totalTokens: 10,
        wallClockMs: 20,
        proposalCount: 1,
        activeStepId: "implement",
        heartbeatBackend: "codex-agent",
        idleMs: 100,
        gateVisits: ["z": 4, "a": 3],
        repeatedFindingRounds: ["review": 3]
      )
    )

    XCTAssertEqual(violations, [
      .budget(.tokens, used: 10, limit: 10),
      .budget(.wallClock, used: 20, limit: 20),
      .budget(.proposals, used: 1, limit: 1),
      .gateVisitsExceeded(gateId: "a", visits: 3),
      .gateVisitsExceeded(gateId: "z", visits: 4),
      .repeatedFindings(gateId: "review", rounds: 3),
      .inactivity(stepId: "implement", idleMs: 100)
    ])
  }

  func testInactivityRequiresAHeartbeatCapableBackend() {
    let policy = GuardPolicy(inactivity: InactivityGuard(
      stallTimeoutMs: 100,
      monitorIntervalMs: 10,
      heartbeatBackends: ["codex-agent"]
    ))
    XCTAssertTrue(WorkGuard.evaluate(
      policy: policy,
      snapshot: GuardSnapshot(
        activeStepId: "step",
        heartbeatBackend: "official-openai-sdk",
        idleMs: 1_000
      )
    ).isEmpty)
  }

  func testOfficialSDKHeartbeatIsExemptEvenWhenExplicitlyConfigured() {
    let policy = GuardPolicy(inactivity: InactivityGuard(
      stallTimeoutMs: 100,
      monitorIntervalMs: 10,
      heartbeatBackends: ["official/openai-sdk"]
    ))
    XCTAssertTrue(WorkGuard.evaluate(
      policy: policy,
      snapshot: GuardSnapshot(
        activeStepId: "step",
        heartbeatBackend: "official/openai-sdk",
        idleMs: 1_000
      )
    ).isEmpty)
  }

  func testValuesBelowLimitsDoNotViolate() {
    let policy = GuardPolicy(
      convergence: ConvergenceGuard(maxGateVisits: 2, maxRepeatedFindingRounds: 2),
      budget: BudgetGuard(maxAttempts: 2, maxTotalTokens: 20, maxWallClockMs: 30, maxProposals: 2)
    )
    XCTAssertTrue(WorkGuard.evaluate(
      policy: policy,
      snapshot: GuardSnapshot(
        attemptCount: 1,
        totalTokens: 19,
        wallClockMs: 29,
        proposalCount: 1,
        gateVisits: ["gate": 1],
        repeatedFindingRounds: ["gate": 1]
      )
    ).isEmpty)
  }

  func testGateVisitsAtTheConfiguredLimitRemainAllowed() {
    let policy = GuardPolicy(convergence: ConvergenceGuard(maxGateVisits: 2))
    XCTAssertTrue(WorkGuard.evaluate(
      policy: policy,
      snapshot: GuardSnapshot(gateVisits: ["review": 2])
    ).isEmpty)
  }

  func testViolationRoundTrips() throws {
    let value = GuardViolation.budget(.tokens, used: 10, limit: 10)
    let data = try JSONEncoder().encode(value)
    XCTAssertEqual(try JSONDecoder().decode(GuardViolation.self, from: data), value)
  }
}
