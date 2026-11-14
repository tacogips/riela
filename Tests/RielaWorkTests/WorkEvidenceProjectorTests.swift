import Foundation
import RielaCore
import XCTest
@testable import RielaWork

/// P0-4: the design section 8 mapping, its counts, and its `causedBy` edges.
final class WorkEvidenceProjectorTests: XCTestCase {
  private let taskId = TaskID("task-1")
  private let attempt = Attempt(
    id: AttemptID("attempt-1"),
    taskId: TaskID("task-1"),
    sessionId: "session-1",
    entry: .start,
    state: .terminal
  )

  // MARK: - Counts

  func testEverySourceInTheMappingTableBecomesItsLedgerKind() {
    let projection = project(snapshot: fullSnapshot())
    XCTAssertEqual(projection.evidence(ofKind: .gate).count, 2)
    XCTAssertEqual(projection.evidence(ofKind: .command).count, 2)
    XCTAssertEqual(projection.evidence(ofKind: .verification).count, 2)
    XCTAssertEqual(projection.evidence(ofKind: .changedFile).count, 2)
    XCTAssertEqual(projection.evidence(ofKind: .cost).count, 1)
    XCTAssertEqual(projection.evidence(ofKind: .guardViolation).count, 1)
    XCTAssertEqual(projection.evidence(ofKind: .decision).count, 1)
    // 3 distinct fingerprints: two gate findings plus one review finding that
    // does not collide with them.
    XCTAssertEqual(projection.evidence(ofKind: .finding).count, 3)
    XCTAssertEqual(projection.findings.count, 3)
    XCTAssertEqual(projection.decisions.count, 1)
    XCTAssertEqual(projection.evidence.count, 14)
    for record in projection.evidence {
      XCTAssertEqual(record.taskId, taskId)
      XCTAssertEqual(record.attemptId, attempt.id)
    }
  }

  func testASnapshotWithoutLoopEvidenceProjectsOnlyItsReviewFindings() {
    var snapshot = fullSnapshot()
    snapshot.loopEvidence = nil
    let projection = project(snapshot: snapshot)
    XCTAssertEqual(projection.findings.map(\.id), ["review-99"])
    XCTAssertEqual(projection.evidence.map(\.kind), [.finding])
    XCTAssertEqual(projection.decisions, [])
  }

  func testAnEmptySnapshotProjectsNothing() {
    var snapshot = fullSnapshot()
    snapshot.loopEvidence = nil
    snapshot.session.reviewFindings = []
    let projection = project(snapshot: snapshot)
    XCTAssertEqual(projection, WorkProjection())
  }

  /// Ledger identifiers are derived, not random: re-projecting the same
  /// terminal snapshot must upsert the same rows.
  func testProjectionIsDeterministic() {
    let first = project(snapshot: fullSnapshot())
    let second = project(snapshot: fullSnapshot())
    XCTAssertEqual(first, second)
    XCTAssertEqual(Set(first.evidence.map(\.id)).count, first.evidence.count)
    for record in first.evidence {
      XCTAssertTrue(record.id.rawValue.hasPrefix("evidence-\(attempt.id.rawValue)-"))
    }
  }

  // MARK: - causedBy edges

  func testFindingsPointAtTheGateThatReportedThem() {
    let projection = project(snapshot: fullSnapshot())
    let gates = projection.evidence(ofKind: .gate)
    let reviewGate = try? XCTUnwrap(gates.first { gateId(of: $0) == "implementation-review" })
    let findings = projection.evidence(ofKind: .finding)

    let gateFindings = findings.filter { $0.producedBy == .stepExecution("exec-review-1") }
    XCTAssertEqual(gateFindings.count, 2)
    for finding in gateFindings {
      XCTAssertEqual(finding.causedBy, [reviewGate?.id].compactMap { $0 })
    }

    // The review finding came from a step that is not a gate step, so there
    // is no gate evidence to point at.
    let orphan = findings.first { $0.producedBy == .stepExecution("exec-implementation-1") }
    XCTAssertEqual(orphan?.causedBy, [])
  }

  func testVerificationPointsAtTheCommandItRan() {
    let projection = project(snapshot: fullSnapshot())
    let commands = projection.evidence(ofKind: .command)
    let verification = projection.evidence(ofKind: .verification)
    let buildCommand = commands.first { payload($0)["id"] == .string("command-build") }
    let linked = verification.first { payload($0)["id"] == .string("verification-build") }
    let unlinked = verification.first { payload($0)["id"] == .string("verification-manual") }

    XCTAssertEqual(linked?.causedBy, [buildCommand?.id].compactMap { $0 })
    XCTAssertEqual(unlinked?.causedBy, [], "a verification with no command reference has no edge")
  }

  func testChangedFilesAndCostsPointAtTheirProducingStepEvidence() {
    let projection = project(snapshot: fullSnapshot())
    let reviewGate = projection.evidence(ofKind: .gate).first { gateId(of: $0) == "implementation-review" }

    let anchored = projection.evidence(ofKind: .changedFile)
      .first { payload($0)["path"] == .string("Sources/A.swift") }
    XCTAssertEqual(anchored?.causedBy, [reviewGate?.id].compactMap { $0 })
    XCTAssertEqual(anchored?.producedBy, .stepExecution("exec-review-1"))

    let unanchored = projection.evidence(ofKind: .changedFile)
      .first { payload($0)["path"] == .string("Sources/B.swift") }
    XCTAssertEqual(unanchored?.causedBy, [])
    XCTAssertEqual(unanchored?.producedBy, .runtime)

    XCTAssertEqual(projection.evidence(ofKind: .cost).first?.causedBy, [reviewGate?.id].compactMap { $0 })
  }

  func testGuardViolationPointsAtTheStalledGateVisit() {
    let projection = project(snapshot: fullSnapshot())
    let stalledGate = projection.evidence(ofKind: .gate).first { gateId(of: $0) == "implementation-review" }
    let violation = projection.evidence(ofKind: .guardViolation).first
    XCTAssertEqual(violation?.causedBy, [stalledGate?.id].compactMap { $0 })
    XCTAssertEqual(payload(violation!)["repeatedRounds"], .integer(3))
  }

  func testGuardViolationIsAbsentWhenNoStallWasDetected() {
    var snapshot = fullSnapshot()
    snapshot.loopEvidence?.convergence = LoopConvergenceEvidence(gateVisitCounts: ["g": 1], stallDetected: false)
    XCTAssertEqual(project(snapshot: snapshot).evidence(ofKind: .guardViolation), [])
  }

  // MARK: - Recovery lineage

  func testARetryLineageAtAGateStepBecomesARecoverDecision() {
    let projection = project(snapshot: fullSnapshot())
    let decision = projection.decisions.first
    XCTAssertEqual(decision?.kind, .recover(fromGateId: "implementation-review"))
    XCTAssertEqual(decision?.producer, .policy(rule: "legacy-import"))
    XCTAssertEqual(decision?.taskId, taskId)
    XCTAssertEqual(decision?.attemptId, attempt.id)
    XCTAssertEqual(decision?.reason, "gate rejected twice")
    // The guard violation is the strongest cause available on this attempt.
    let violation = projection.evidence(ofKind: .guardViolation).first
    XCTAssertEqual(decision?.causedBy, [violation?.id].compactMap { $0 })
  }

  func testALineageAtANonGateStepBecomesARerunDecision() {
    var snapshot = fullSnapshot()
    snapshot.loopEvidence?.recovery = LoopRecoveryLineage(
      entryMode: .rerun,
      sourceStepId: "implementation",
      inputReusePolicy: "reuse"
    )
    let decision = project(snapshot: snapshot).decisions.first
    XCTAssertEqual(decision?.kind, .rerun(fromStepId: "implementation"))
  }

  func testAPlainRunOrResumeLineageProjectsNoDecision() {
    for mode in [LoopEntryMode.run, .resume] {
      var snapshot = fullSnapshot()
      snapshot.loopEvidence?.recovery = LoopRecoveryLineage(entryMode: mode, inputReusePolicy: "reuse")
      let projection = project(snapshot: snapshot)
      XCTAssertEqual(projection.decisions, [], "\(mode.rawValue) records no redirection")
      XCTAssertEqual(projection.evidence(ofKind: .decision), [])
    }
  }

  // MARK: - Finding merge

  func testAReviewFindingAndAGateFindingWithTheSameIdCollapseToOneRow() {
    var snapshot = fullSnapshot()
    snapshot.session.reviewFindings = [reviewFinding(id: "finding-high", severity: .low)]
    let projection = project(snapshot: snapshot)
    XCTAssertEqual(projection.findings.count, 2)
    let merged = projection.findings.first { $0.id == "finding-high" }
    XCTAssertEqual(merged?.severity, .high, "the merge never downgrades a severity")
    XCTAssertEqual(merged?.gateId, "implementation-review", "the gate id survives the merge")
    XCTAssertEqual(merged?.feedback, "please fix", "the review's feedback fills the gap")
  }

  func testFindingsWithoutAnIdCollapseOnFilePathAndNormalizedMessage() {
    var snapshot = fullSnapshot()
    snapshot.loopEvidence?.gates = [
      gateResult(
        gateId: "g",
        stepExecutionId: "exec-g-1",
        decision: .rejected,
        findings: [
          LoopBlockingFinding(id: "", severity: "high", filePath: "A.swift", message: "same   message\nhere"),
          LoopBlockingFinding(id: "", severity: "mid", filePath: "A.swift", message: "same message here")
        ]
      )
    ]
    snapshot.session.reviewFindings = []
    let projection = project(snapshot: snapshot)
    XCTAssertEqual(projection.findings.count, 1)
    XCTAssertEqual(projection.findings.first?.severity, .high)
    XCTAssertEqual(projection.findings.first?.fingerprint.key, "message:A.swift\u{0}same message here")
  }

  func testUnknownLoopSeveritiesAreTreatedAsBlockingAndInformationalIsNot() {
    XCTAssertEqual(WorkFindingMerge.severity(fromLoopSeverity: "critical"), .high)
    XCTAssertEqual(WorkFindingMerge.severity(fromLoopSeverity: "medium"), .mid)
    XCTAssertEqual(WorkFindingMerge.severity(fromLoopSeverity: "minor"), .low)
    XCTAssertEqual(WorkFindingMerge.severity(fromLoopSeverity: "informational"), .low)
    XCTAssertEqual(WorkFindingMerge.severity(fromLoopSeverity: "hgih"), .high)
    XCTAssertFalse(WorkFindingMerge.severity(fromLoopSeverity: "informational").blocksReviewRetry)
    XCTAssertTrue(WorkFindingMerge.severity(fromLoopSeverity: "hgih").blocksReviewRetry)
  }

  func testAnAddressedFindingStaysOpenWhenAnotherProducerStillReportsIt() {
    let open = finding(id: "f", severity: .mid, status: .open)
    var addressed = open
    addressed.status = .addressed
    XCTAssertEqual(WorkFindingMerge.merge([addressed, open]).first?.status, .open)
    XCTAssertEqual(WorkFindingMerge.merge([addressed, addressed]).first?.status, .addressed)
  }

  // MARK: - Outcome

  func testOutcomeLiftsTheTerminalSessionFacts() {
    let snapshot = fullSnapshot()
    let outcome = WorkEvidenceProjector.outcome(from: snapshot)
    XCTAssertEqual(outcome.sessionStatus, .failed)
    XCTAssertEqual(outcome.failureKind, .loopNotConverging)
    XCTAssertEqual(outcome.gateResults.count, 2)
    XCTAssertEqual(outcome.costs.count, 1)
    XCTAssertEqual(outcome.latestGateResults.map(\.gateId), ["design-review", "implementation-review"])
  }

  func testLatestGateResultsKeepsTheLastVisitOfARepeatedGate() {
    let outcome = AttemptOutcome(
      sessionStatus: .completed,
      gateResults: [
        gateResult(gateId: "g", stepExecutionId: "exec-1", decision: .rejected),
        gateResult(gateId: "g", stepExecutionId: "exec-2", decision: .accepted)
      ]
    )
    XCTAssertEqual(outcome.latestGateResults.count, 1)
    XCTAssertEqual(outcome.latestGateResults.first?.decision, .accepted)
    XCTAssertEqual(outcome.latestGateResults.first?.stepExecutionId, "exec-2")
  }

  // MARK: - Helpers

  private func project(snapshot: WorkflowRuntimePersistenceSnapshot) -> WorkProjection {
    WorkEvidenceProjector().project(snapshot: snapshot, task: sampleTask(), attempt: attempt)
  }

  private func sampleTask() -> WorkTask {
    WorkTask(id: taskId, intentId: IntentID("intent-1"), title: "t", instruction: "i")
  }

  private func gateId(of evidence: Evidence) -> String? {
    guard case let .string(value)? = payload(evidence)["gateId"] else { return nil }
    return value
  }

  private func payload(_ evidence: Evidence) -> JSONObject {
    evidence.payloadRef.inlinePayload ?? [:]
  }

  private func finding(id: String, severity: FindingSeverity, status: FindingStatus) -> Finding {
    let blocking = LoopBlockingFinding(id: id, severity: severity.rawValue, message: "m")
    return Finding(
      id: id,
      fingerprint: LoopFindingFingerprint.make(from: blocking),
      severity: severity,
      status: status,
      sourceStepExecutionId: "exec-1",
      message: "m"
    )
  }

  private func reviewFinding(id: String, severity: FindingSeverity) -> WorkflowReviewFinding {
    WorkflowReviewFinding(
      id: id,
      sourceReviewStepId: "implementation",
      sourceStepExecutionId: "exec-implementation-1",
      sourceExecutionAttempt: 1,
      targetStepId: "implementation",
      severity: severity,
      message: "review message",
      feedback: "please fix",
      originatingSessionId: "session-1",
      createdAt: Date(timeIntervalSince1970: 1_500)
    )
  }

  private func gateResult(
    gateId: String,
    stepExecutionId: String,
    decision: LoopGateDecision,
    findings: [LoopBlockingFinding] = []
  ) -> LoopGateResult {
    LoopGateResult(
      gateId: gateId,
      stepId: gateId,
      stepExecutionId: stepExecutionId,
      decision: decision,
      blockingFindings: findings,
      acceptedAt: decision == .accepted ? Date(timeIntervalSince1970: 2_000) : nil
    )
  }

  private func fullSnapshot() -> WorkflowRuntimePersistenceSnapshot {
    let date = Date(timeIntervalSince1970: 1_000)
    var session = WorkflowSession(
      workflowId: "loop-workflow",
      sessionId: "session-1",
      status: .failed,
      entryStepId: "design",
      createdAt: date,
      updatedAt: date,
      reviewFindings: [reviewFinding(id: "review-99", severity: .mid)],
      failureKind: .loopNotConverging
    )
    session.failureReason = "loop did not converge"

    let manifest = LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "manifest-1",
      workflowId: "loop-workflow",
      sessionId: "session-1",
      workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow-directory", mutable: false),
      policy: LoopPolicyEvidence(),
      recovery: LoopRecoveryLineage(
        entryMode: .retry,
        sourceStepId: "implementation-review",
        sourceStepExecutionId: "exec-review-1",
        reason: "gate rejected twice",
        inputReusePolicy: "reuse"
      ),
      convergence: LoopConvergenceEvidence(
        gateVisitCounts: ["implementation-review": 3],
        stallDetected: true,
        stalledGateId: "implementation-review",
        repeatedRounds: 3,
        action: "stop"
      ),
      costs: [
        LoopCostEvidence(
          stepExecutionId: "exec-review-1",
          backend: "codex-agent",
          model: "gpt-5.6-luna",
          totalTokens: 1_234,
          durationMs: 5_000
        )
      ],
      gates: [
        gateResult(gateId: "design-review", stepExecutionId: "exec-design-1", decision: .accepted),
        gateResult(
          gateId: "implementation-review",
          stepExecutionId: "exec-review-1",
          decision: .rejected,
          findings: [
            LoopBlockingFinding(id: "finding-high", severity: "high", filePath: "Sources/A.swift", message: "boom"),
            LoopBlockingFinding(id: "finding-low", severity: "informational", message: "nit")
          ]
        )
      ],
      changedFiles: [
        LoopChangedFile(path: "Sources/A.swift", changeKind: "modified", producerStepExecutionId: "exec-review-1"),
        LoopChangedFile(path: "Sources/B.swift", changeKind: "added")
      ],
      commands: [
        LoopCommandEvidence(id: "command-build", argvSummary: "swift build", argvRedactionStatus: "clean", exitCode: 0),
        LoopCommandEvidence(id: "command-test", argvSummary: "swift test", argvRedactionStatus: "clean", exitCode: 1)
      ],
      verification: [
        LoopVerificationEvidence(id: "verification-build", commandRef: "command-build", outcome: "passed"),
        LoopVerificationEvidence(id: "verification-manual", outcome: "failed")
      ],
      redaction: LoopRedactionSummary(policyName: "default", status: "clean"),
      createdAt: date,
      updatedAt: date
    )

    return WorkflowRuntimePersistenceSnapshot(session: session, loopEvidence: manifest)
  }
}
