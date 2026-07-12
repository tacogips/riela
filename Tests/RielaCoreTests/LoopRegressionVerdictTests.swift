import Foundation
import XCTest
@testable import RielaCore

final class LoopRegressionVerdictTests: XCTestCase {
  func testIdenticalManifestsProduceNoRegression() {
    let base = Self.manifest(sessionId: "s1", gates: [Self.gate("review", decision: .accepted)])
    let target = Self.manifest(sessionId: "s2", gates: [Self.gate("review", decision: .accepted)])
    let verdict = LoopRegressionClassifier.verdict(base: base, target: target, requiredGateIds: ["review"])
    XCTAssertFalse(verdict.hasRegression)
    XCTAssertEqual(verdict.baselineSessionId, "s1")
    XCTAssertEqual(verdict.targetSessionId, "s2")
  }

  func testRequiredGateDowngradeIsRegression() {
    let base = Self.manifest(sessionId: "s1", gates: [Self.gate("review", decision: .accepted)])
    let target = Self.manifest(sessionId: "s2", gates: [Self.gate("review", decision: .needsWork)])
    let verdict = LoopRegressionClassifier.verdict(base: base, target: target, requiredGateIds: ["review"])
    XCTAssertEqual(verdict.regressions.map(\.kind), ["required-gate-downgrade"])
    XCTAssertEqual(verdict.regressions.first?.gateId, "review")
  }

  func testRequiredGateMissingInTargetIsRegression() {
    let base = Self.manifest(sessionId: "s1", gates: [Self.gate("review", decision: .accepted)])
    let target = Self.manifest(sessionId: "s2", gates: [])
    let verdict = LoopRegressionClassifier.verdict(base: base, target: target, requiredGateIds: ["review"])
    XCTAssertEqual(verdict.regressions.map(\.kind), ["required-gate-downgrade"])
    XCTAssertTrue(verdict.regressions.first?.detail.contains("missing") == true)
  }

  func testOptionalGateDowngradeIsNotRegression() {
    let base = Self.manifest(sessionId: "s1", gates: [Self.gate("optional", decision: .accepted)])
    let target = Self.manifest(sessionId: "s2", gates: [Self.gate("optional", decision: .rejected)])
    let verdict = LoopRegressionClassifier.verdict(base: base, target: target, requiredGateIds: [])
    XCTAssertFalse(verdict.hasRegression)
  }

  func testGateNotAcceptedInBaselineCannotDowngrade() {
    let base = Self.manifest(sessionId: "s1", gates: [Self.gate("review", decision: .rejected)])
    let target = Self.manifest(sessionId: "s2", gates: [Self.gate("review", decision: .rejected)])
    let verdict = LoopRegressionClassifier.verdict(base: base, target: target, requiredGateIds: ["review"])
    XCTAssertFalse(verdict.hasRegression)
  }

  func testBlockingFindingsAddedOnRequiredGateIsRegression() {
    let base = Self.manifest(sessionId: "s1", gates: [Self.gate("review", decision: .accepted)])
    let target = Self.manifest(sessionId: "s2", gates: [
      Self.gate(
        "review",
        decision: .accepted,
        findings: [LoopBlockingFinding(id: "f1", severity: "high", filePath: "a.swift", message: "leak")]
      )
    ])
    let verdict = LoopRegressionClassifier.verdict(base: base, target: target, requiredGateIds: ["review"])
    XCTAssertEqual(verdict.regressions.map(\.kind), ["blocking-findings-added"])
  }

  func testFindingLineDriftIsNotARegression() {
    let base = Self.manifest(sessionId: "s1", gates: [
      Self.gate(
        "review",
        decision: .accepted,
        findings: [LoopBlockingFinding(id: "f1", severity: "high", filePath: "a.swift", line: 10, message: "leak")]
      )
    ])
    let target = Self.manifest(sessionId: "s2", gates: [
      Self.gate(
        "review",
        decision: .accepted,
        findings: [LoopBlockingFinding(id: "f9", severity: "high", filePath: "a.swift", line: 42, message: "leak")]
      )
    ])
    let verdict = LoopRegressionClassifier.verdict(base: base, target: target, requiredGateIds: ["review"])
    XCTAssertFalse(verdict.hasRegression)
  }

  func testVerificationPassToFailFlipIsRegression() {
    let base = Self.manifest(
      sessionId: "s1",
      commands: [Self.command("c1", summary: "swift test")],
      verification: [Self.verification("v1", commandRef: "c1", outcome: "passed")]
    )
    let target = Self.manifest(
      sessionId: "s2",
      commands: [Self.command("c2", summary: "swift test")],
      verification: [Self.verification("v2", commandRef: "c2", outcome: "failed")]
    )
    let verdict = LoopRegressionClassifier.verdict(base: base, target: target, requiredGateIds: [])
    XCTAssertEqual(verdict.regressions.map(\.kind), ["verification-flip"])
    XCTAssertTrue(verdict.regressions.first?.detail.contains("swift test") == true)
  }

  func testVerificationFailToPassIsNotARegression() {
    let base = Self.manifest(
      sessionId: "s1",
      commands: [Self.command("c1", summary: "swift test")],
      verification: [Self.verification("v1", commandRef: "c1", outcome: "failed")]
    )
    let target = Self.manifest(
      sessionId: "s2",
      commands: [Self.command("c2", summary: "swift test")],
      verification: [Self.verification("v2", commandRef: "c2", outcome: "passed")]
    )
    let verdict = LoopRegressionClassifier.verdict(base: base, target: target, requiredGateIds: [])
    XCTAssertFalse(verdict.hasRegression)
  }

  func testLatestGateVisitWins() {
    // Two visits: first rejected, second accepted — the final state is
    // accepted, so a target acceptance is not a downgrade.
    let base = Self.manifest(sessionId: "s1", gates: [
      Self.gate("review", decision: .rejected),
      Self.gate("review", decision: .accepted)
    ])
    let target = Self.manifest(sessionId: "s2", gates: [
      Self.gate("review", decision: .accepted),
      Self.gate("review", decision: .rejected)
    ])
    let verdict = LoopRegressionClassifier.verdict(base: base, target: target, requiredGateIds: ["review"])
    XCTAssertEqual(verdict.regressions.map(\.kind), ["required-gate-downgrade"])
  }

  func testVerdictCodableRoundTrip() throws {
    let base = Self.manifest(sessionId: "s1", gates: [Self.gate("review", decision: .accepted)])
    let target = Self.manifest(sessionId: "s2", gates: [Self.gate("review", decision: .rejected)])
    let verdict = LoopRegressionClassifier.verdict(base: base, target: target, requiredGateIds: ["review"])
    let decoded = try JSONDecoder().decode(
      LoopRegressionVerdict.self,
      from: try JSONEncoder().encode(verdict)
    )
    XCTAssertEqual(decoded, verdict)
  }

  // MARK: - Baseline store

  func testBaselineSetLoadClearRoundTrip() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root)
    XCTAssertNil(try store.loadLoopBaseline(workflowId: "wf"), "missing database means no baseline")

    let baseline = LoopBaseline(
      workflowId: "wf",
      sessionId: "session-1",
      setAt: Date(timeIntervalSince1970: 1_700_000_000),
      note: "smoke"
    )
    try store.setLoopBaseline(baseline)
    let loaded = try XCTUnwrap(store.loadLoopBaseline(workflowId: "wf"))
    XCTAssertEqual(loaded.sessionId, "session-1")
    XCTAssertEqual(loaded.note, "smoke")

    let replacement = LoopBaseline(
      workflowId: "wf",
      sessionId: "session-2",
      setAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    try store.setLoopBaseline(replacement)
    XCTAssertEqual(try store.loadLoopBaseline(workflowId: "wf")?.sessionId, "session-2")
    XCTAssertNil(try store.loadLoopBaseline(workflowId: "wf")?.note)

    XCTAssertTrue(try store.clearLoopBaseline(workflowId: "wf"))
    XCTAssertNil(try store.loadLoopBaseline(workflowId: "wf"))
    XCTAssertFalse(try store.clearLoopBaseline(workflowId: "wf"))
  }

  func testBaselineReadTreatsMissingTableAsNoBaseline() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    // Create the database without the baseline table by saving a snapshot.
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    try store.save(WorkflowRuntimePersistenceSnapshot(
      session: WorkflowSession(
        workflowId: "wf",
        sessionId: "session-1",
        status: .completed,
        entryStepId: "s",
        createdAt: date,
        updatedAt: date
      ),
      workflowMessages: [],
      diagnostics: []
    ))
    XCTAssertNil(try store.loadLoopBaseline(workflowId: "wf"))
  }

  // MARK: - Fixtures

  private func temporaryRoot() throws -> String {
    let root = NSTemporaryDirectory() + "loop-baseline-tests-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
  }

  private static func gate(
    _ gateId: String,
    decision: LoopGateDecision,
    findings: [LoopBlockingFinding] = []
  ) -> LoopGateResult {
    LoopGateResult(
      gateId: gateId,
      stepId: gateId,
      stepExecutionId: "\(gateId)-exec",
      decision: decision,
      severityCounts: LoopFindingSeverityCounts(),
      blockingFindings: findings
    )
  }

  private static func command(_ id: String, summary: String) -> LoopCommandEvidence {
    LoopCommandEvidence(id: id, argvSummary: summary, argvRedactionStatus: "clean")
  }

  private static func verification(_ id: String, commandRef: String, outcome: String) -> LoopVerificationEvidence {
    LoopVerificationEvidence(id: id, commandRef: commandRef, outcome: outcome)
  }

  private static func manifest(
    sessionId: String,
    workflowId: String = "wf",
    gates: [LoopGateResult] = [],
    commands: [LoopCommandEvidence] = [],
    verification: [LoopVerificationEvidence] = []
  ) -> LoopEvidenceManifest {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "loop-evidence-\(sessionId)",
      workflowId: workflowId,
      sessionId: sessionId,
      workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow-directory", mutable: true),
      policy: LoopPolicyEvidence(),
      gates: gates,
      commands: commands,
      verification: verification,
      redaction: LoopRedactionSummary(policyName: "summary-only", status: "clean"),
      createdAt: date,
      updatedAt: date
    )
  }
}
