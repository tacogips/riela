import Foundation
import RielaCore
import XCTest
@testable import RielaWork

/// P0-5: the design section 5 completion rule, table-driven over every unmet
/// kind plus the satisfied path.
final class CompletionEvaluatorTests: XCTestCase {
  func testTheSatisfiedPath() {
    XCTAssertEqual(
      CompletionEvaluator.evaluate(
        contract: contract(),
        attemptOutcome: outcome(gates: [gate("implementation-review", .accepted)]),
        ledger: CompletionLedger(
          verification: [VerificationOutcome(name: "unit-tests", passed: true)],
          findings: [finding(severity: .high, status: .addressed)],
          acceptance: GateAcceptance(met: true)
        )
      ),
      .satisfied
    )
  }

  func testEveryUnmetKind() {
    struct Row {
      var name: String
      var contract: CompletionContract
      var outcome: AttemptOutcome
      var ledger: CompletionLedger
      var expected: [UnmetRequirement]
    }

    let rows: [Row] = [
      Row(
        name: "a required gate was rejected",
        contract: contract(),
        outcome: outcome(gates: [gate("implementation-review", .rejected)]),
        ledger: passingLedger(),
        expected: [.gateNotAccepted(gateId: "implementation-review")]
      ),
      Row(
        name: "a required gate never ran",
        contract: contract(),
        outcome: outcome(gates: []),
        ledger: passingLedger(),
        expected: [.gateNotAccepted(gateId: "implementation-review")]
      ),
      Row(
        name: "a required gate was accepted while carrying blocking findings",
        contract: contract(),
        outcome: outcome(gates: [
          gate(
            "implementation-review",
            .accepted,
            findings: [LoopBlockingFinding(id: "f", severity: "high", message: "m")]
          )
        ]),
        ledger: passingLedger(),
        expected: [.gateNotAccepted(gateId: "implementation-review")]
      ),
      Row(
        name: "a verification requirement has no evidence",
        contract: contract(),
        outcome: acceptedOutcome(),
        ledger: CompletionLedger(verification: [], acceptance: GateAcceptance(met: true)),
        expected: [.verificationMissing(name: "unit-tests")]
      ),
      Row(
        name: "a verification requirement failed",
        contract: contract(),
        outcome: acceptedOutcome(),
        ledger: CompletionLedger(
          verification: [VerificationOutcome(name: "unit-tests", passed: false)],
          acceptance: GateAcceptance(met: true)
        ),
        expected: [.verificationFailed(name: "unit-tests")]
      ),
      Row(
        name: "an open blocking finding remains",
        contract: contract(),
        outcome: acceptedOutcome(),
        ledger: CompletionLedger(
          verification: [VerificationOutcome(name: "unit-tests", passed: true)],
          findings: [finding(severity: .mid, status: .open)],
          acceptance: GateAcceptance(met: true)
        ),
        expected: [.openBlockingFinding(fingerprint: "id:finding-1")]
      ),
      Row(
        name: "the gate payload says acceptance was not met",
        contract: contract(),
        outcome: acceptedOutcome(),
        ledger: CompletionLedger(
          verification: [VerificationOutcome(name: "unit-tests", passed: true)],
          acceptance: GateAcceptance(met: false, note: "the importer still drops rows")
        ),
        expected: [.acceptanceNotMet]
      ),
      Row(
        name: "the task declares criteria and the gate payload carries no acceptance",
        contract: contract(),
        outcome: acceptedOutcome(),
        ledger: CompletionLedger(
          verification: [VerificationOutcome(name: "unit-tests", passed: true)],
          acceptance: nil
        ),
        expected: [.acceptanceAbsent]
      ),
      Row(
        name: "a human must accept",
        contract: contract(requiresHumanAccept: true),
        outcome: acceptedOutcome(),
        ledger: passingLedger(),
        expected: [.humanAcceptRequired]
      )
    ]

    for row in rows {
      XCTAssertEqual(
        CompletionEvaluator.evaluate(
          contract: row.contract,
          attemptOutcome: row.outcome,
          ledger: row.ledger
        ),
        .unmet(row.expected),
        row.name
      )
    }
  }

  func testEveryUnmetRequirementIsReportedNotJustTheFirst() {
    let verdict = CompletionEvaluator.evaluate(
      contract: contract(requiresHumanAccept: true),
      attemptOutcome: outcome(gates: [gate("implementation-review", .needsWork)]),
      ledger: CompletionLedger(
        verification: [VerificationOutcome(name: "unit-tests", passed: false)],
        findings: [finding(severity: .high, status: .open)],
        acceptance: GateAcceptance(met: false)
      )
    )
    XCTAssertEqual(verdict, .unmet([
      .gateNotAccepted(gateId: "implementation-review"),
      .verificationFailed(name: "unit-tests"),
      .openBlockingFinding(fingerprint: "id:finding-1"),
      .acceptanceNotMet,
      .humanAcceptRequired
    ]))
  }

  func testAnAdvisoryGateDoesNotBlockCompletion() {
    var contract = contract()
    contract.gates.append(GateDeclaration(id: "design-review", stepId: "design-review", required: false))
    XCTAssertEqual(
      CompletionEvaluator.evaluate(
        contract: contract,
        attemptOutcome: outcome(gates: [
          gate("implementation-review", .accepted),
          gate("design-review", .rejected)
        ]),
        ledger: passingLedger()
      ),
      .satisfied
    )
  }

  func testOnlyTheLatestVisitOfARepeatedGateCounts() {
    XCTAssertEqual(
      CompletionEvaluator.evaluate(
        contract: contract(),
        attemptOutcome: outcome(gates: [
          gate("implementation-review", .rejected),
          gate("implementation-review", .accepted)
        ]),
        ledger: passingLedger()
      ),
      .satisfied
    )
  }

  func testALowSeverityOpenFindingDoesNotBlockCompletion() {
    XCTAssertEqual(
      CompletionEvaluator.evaluate(
        contract: contract(),
        attemptOutcome: acceptedOutcome(),
        ledger: CompletionLedger(
          verification: [VerificationOutcome(name: "unit-tests", passed: true)],
          findings: [finding(severity: .low, status: .open)],
          acceptance: GateAcceptance(met: true)
        )
      ),
      .satisfied
    )
  }

  func testATaskWithoutAcceptanceCriteriaSkipsTheAcceptanceCheckEntirely() {
    var contract = contract()
    contract.acceptance = []
    XCTAssertEqual(
      CompletionEvaluator.evaluate(
        contract: contract,
        attemptOutcome: acceptedOutcome(),
        ledger: CompletionLedger(
          verification: [VerificationOutcome(name: "unit-tests", passed: true)],
          acceptance: nil
        )
      ),
      .satisfied
    )
  }

  func testAnEmptyContractIsSatisfiedByAnyOutcome() {
    XCTAssertEqual(
      CompletionEvaluator.evaluate(
        contract: CompletionContract(),
        attemptOutcome: AttemptOutcome(sessionStatus: .failed),
        ledger: CompletionLedger()
      ),
      .satisfied
    )
  }

  func testTheVerdictRoundTrips() throws {
    let verdict = CompletionVerdict.unmet([
      .gateNotAccepted(gateId: "g"),
      .verificationMissing(name: "v"),
      .verificationFailed(name: "v"),
      .openBlockingFinding(fingerprint: "id:f"),
      .acceptanceNotMet,
      .acceptanceAbsent,
      .humanAcceptRequired
    ])
    let data = try JSONEncoder().encode(verdict)
    XCTAssertEqual(try JSONDecoder().decode(CompletionVerdict.self, from: data), verdict)
    XCTAssertEqual(try JSONDecoder().decode(CompletionVerdict.self, from: Data(#"{"verdict":"satisfied"}"#.utf8)), .satisfied)
    XCTAssertThrowsError(try JSONDecoder().decode(CompletionVerdict.self, from: Data(#"{"verdict":"maybe"}"#.utf8)))
    XCTAssertThrowsError(try JSONDecoder().decode(UnmetRequirement.self, from: Data(#"{"kind":"budget"}"#.utf8)))
  }

  // MARK: - Gate payload acceptance (delta D3)

  func testAcceptanceIsReadFromTheGatePayload() {
    XCTAssertEqual(
      GateAcceptanceParser.acceptance(inGatePayload: [
        "acceptance": .object(["met": .bool(true), "note": .string("all criteria met")])
      ]),
      GateAcceptance(met: true, note: "all criteria met")
    )
    XCTAssertEqual(
      GateAcceptanceParser.acceptance(inGatePayload: ["acceptance": .object(["met": .bool(false)])]),
      GateAcceptance(met: false)
    )
  }

  func testAMalformedOrAbsentAcceptanceReadsAsAbsentNeverAsMet() {
    let payloads: [JSONObject] = [
      [:],
      ["acceptance": .null],
      ["acceptance": .string("true")],
      ["acceptance": .object([:])],
      ["acceptance": .object(["met": .string("true")])],
      ["acceptance": .object(["note": .string("looks fine")])]
    ]
    for payload in payloads {
      XCTAssertNil(GateAcceptanceParser.acceptance(inGatePayload: payload), "\(payload) must read as absent")
    }
  }

  func testAttemptAcceptanceIsTheMergeOfEveryRequiredGatePayload() {
    let gates = [
      GateDeclaration(id: "a", stepId: "step-a", required: true),
      GateDeclaration(id: "b", stepId: "step-b", required: true),
      GateDeclaration(id: "c", stepId: "step-c", required: false)
    ]

    XCTAssertEqual(
      GateAcceptanceParser.acceptance(
        requiredGates: gates,
        session: session(acceptance: ["step-a": true, "step-b": true])
      ),
      GateAcceptance(met: true)
    )
    XCTAssertEqual(
      GateAcceptanceParser.acceptance(
        requiredGates: gates,
        session: session(acceptance: ["step-a": true, "step-b": false])
      )?.met,
      false,
      "one dissenting gate cannot be outvoted"
    )
    XCTAssertNil(
      GateAcceptanceParser.acceptance(requiredGates: gates, session: session(acceptance: [:])),
      "no gate carrying an acceptance object reads as absent"
    )
    XCTAssertNil(
      GateAcceptanceParser.acceptance(
        requiredGates: gates,
        session: session(acceptance: ["step-c": true])
      ),
      "an advisory gate's judgement is not the task's"
    )
    XCTAssertNil(
      GateAcceptanceParser.acceptance(requiredGates: [], session: session(acceptance: ["step-a": true]))
    )
  }

  func testTheLatestExecutionOfAGateStepWins() {
    var session = session(acceptance: ["step-a": false])
    session.executions.append(execution(stepId: "step-a", executionId: "exec-2", met: true))
    XCTAssertEqual(
      GateAcceptanceParser.acceptance(
        requiredGates: [GateDeclaration(id: "a", stepId: "step-a", required: true)],
        session: session
      ),
      GateAcceptance(met: true)
    )
  }

  // MARK: - Helpers

  private func contract(requiresHumanAccept: Bool = false) -> CompletionContract {
    CompletionContract(
      gates: [GateDeclaration(id: "implementation-review", stepId: "implementation-review", required: true)],
      verification: [VerificationRequirement(name: "unit-tests", command: "swift test")],
      acceptance: [AcceptanceCriterion(id: "criterion-1", statement: "rows are no longer dropped")],
      requiresHumanAccept: requiresHumanAccept
    )
  }

  private func passingLedger() -> CompletionLedger {
    CompletionLedger(
      verification: [VerificationOutcome(name: "unit-tests", passed: true)],
      acceptance: GateAcceptance(met: true)
    )
  }

  private func outcome(gates: [LoopGateResult]) -> AttemptOutcome {
    AttemptOutcome(sessionStatus: .completed, gateResults: gates)
  }

  private func acceptedOutcome() -> AttemptOutcome {
    outcome(gates: [gate("implementation-review", .accepted)])
  }

  private func gate(
    _ id: String,
    _ decision: LoopGateDecision,
    findings: [LoopBlockingFinding] = []
  ) -> LoopGateResult {
    LoopGateResult(
      gateId: id,
      stepId: id,
      stepExecutionId: "exec-\(id)",
      decision: decision,
      blockingFindings: findings
    )
  }

  private func finding(severity: FindingSeverity, status: FindingStatus) -> Finding {
    let blocking = LoopBlockingFinding(id: "finding-1", severity: severity.rawValue, message: "m")
    return Finding(
      id: "finding-1",
      fingerprint: LoopFindingFingerprint.make(from: blocking),
      severity: severity,
      status: status,
      sourceStepExecutionId: "exec-1",
      message: "m"
    )
  }

  private func session(acceptance: [String: Bool]) -> WorkflowSession {
    let date = Date(timeIntervalSince1970: 1_000)
    return WorkflowSession(
      workflowId: "w",
      sessionId: "session-1",
      status: .completed,
      entryStepId: "step-a",
      createdAt: date,
      updatedAt: date,
      executions: acceptance.keys.sorted().map { stepId in
        execution(stepId: stepId, executionId: "exec-\(stepId)", met: acceptance[stepId] ?? false)
      }
    )
  }

  private func execution(stepId: String, executionId: String, met: Bool) -> WorkflowStepExecution {
    let date = Date(timeIntervalSince1970: 1_000)
    return WorkflowStepExecution(
      executionId: executionId,
      stepId: stepId,
      nodeId: stepId,
      attempt: 1,
      status: .completed,
      acceptedOutput: WorkflowAcceptedOutputMetadata(
        payload: [
          "loopGate": .object([
            "gateId": .string(stepId),
            "decision": .string("accepted"),
            "acceptance": .object(["met": .bool(met)])
          ])
        ],
        when: [:],
        acceptedAt: date
      ),
      createdAt: date,
      updatedAt: date
    )
  }
}
