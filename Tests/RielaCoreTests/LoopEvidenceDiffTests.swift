import Foundation
import RielaCore
import XCTest

final class LoopEvidenceDiffTests: XCTestCase {
  func testIdenticalManifestsProduceEmptyDiff() {
    let manifest = Self.manifest(sessionId: "s1")
    let diff = LoopEvidenceDiffer.diff(base: manifest, target: manifest)

    XCTAssertTrue(diff.sameWorkflow)
    XCTAssertEqual(diff.baseSessionId, "s1")
    XCTAssertEqual(diff.targetSessionId, "s1")
    XCTAssertEqual(diff.gateChanges, [])
    XCTAssertEqual(diff.blockingFindingsAdded, [])
    XCTAssertEqual(diff.blockingFindingsResolved, [])
    XCTAssertEqual(diff.changedFilesAdded, [])
    XCTAssertEqual(diff.changedFilesRemoved, [])
    XCTAssertEqual(diff.verificationChanges, [])
    XCTAssertEqual(diff.residualRiskDelta, LoopResidualRiskDelta())
    XCTAssertNil(diff.costDelta)
    XCTAssertEqual(diff.diagnostics, [])
  }

  func testCrossWorkflowIsFlaggedWithDiagnostic() {
    let base = Self.manifest(sessionId: "a", workflowId: "wf-a")
    let target = Self.manifest(sessionId: "b", workflowId: "wf-b")

    let diff = LoopEvidenceDiffer.diff(base: base, target: target)

    XCTAssertFalse(diff.sameWorkflow)
    XCTAssertTrue(diff.diagnostics.contains { $0.contains("cross-workflow") })
  }

  func testWorkflowDefinitionDigestChangeIsNilWhenEitherAbsent() {
    let base = Self.manifest(sessionId: "a", definitionDigest: "digest-1")
    let targetNoDigest = Self.manifest(sessionId: "b", definitionDigest: nil)
    XCTAssertNil(LoopEvidenceDiffer.diff(base: base, target: targetNoDigest).workflowDefinitionDigestChanged)

    let targetChanged = Self.manifest(sessionId: "b", definitionDigest: "digest-2")
    XCTAssertEqual(LoopEvidenceDiffer.diff(base: base, target: targetChanged).workflowDefinitionDigestChanged, true)

    let targetSame = Self.manifest(sessionId: "b", definitionDigest: "digest-1")
    XCTAssertEqual(LoopEvidenceDiffer.diff(base: base, target: targetSame).workflowDefinitionDigestChanged, false)
  }

  func testDisjointGateSetsProduceGateChanges() {
    var base = Self.manifest(sessionId: "a")
    base.gates = [Self.gate(id: "gate-x", decision: .accepted)]
    var target = Self.manifest(sessionId: "b")
    target.gates = [Self.gate(id: "gate-y", decision: .rejected)]

    let diff = LoopEvidenceDiffer.diff(base: base, target: target)

    XCTAssertEqual(diff.gateChanges.map(\.gateId), ["gate-x", "gate-y"])
    let x = try? XCTUnwrap(diff.gateChanges.first { $0.gateId == "gate-x" })
    XCTAssertEqual(x?.baseDecision, .accepted)
    XCTAssertNil(x?.targetDecision)
    let y = diff.gateChanges.first { $0.gateId == "gate-y" }
    XCTAssertNil(y?.baseDecision)
    XCTAssertEqual(y?.targetDecision, .rejected)
  }

  func testGateDecisionAndSeverityDeltaReported() {
    var base = Self.manifest(sessionId: "a")
    base.gates = [Self.gate(id: "review", decision: .rejected, high: 2, medium: 1)]
    var target = Self.manifest(sessionId: "b")
    target.gates = [Self.gate(id: "review", decision: .accepted, high: 0, medium: 0)]

    let change = try? XCTUnwrap(LoopEvidenceDiffer.diff(base: base, target: target).gateChanges.first)
    XCTAssertEqual(change?.baseDecision, .rejected)
    XCTAssertEqual(change?.targetDecision, .accepted)
    XCTAssertEqual(change?.severityCountsDelta.high, -2)
    XCTAssertEqual(change?.severityCountsDelta.medium, -1)
  }

  func testBlockingFindingsMatchByFilePathAndMessageWithLineDriftTolerated() {
    var base = Self.manifest(sessionId: "a")
    base.gates = [Self.gate(id: "review", decision: .rejected, findings: [
      LoopBlockingFinding(id: "f1", severity: "high", filePath: "a.swift", line: 10, message: "leak"),
      LoopBlockingFinding(id: "f2", severity: "high", filePath: nil, line: nil, message: "pathless")
    ])]
    var target = Self.manifest(sessionId: "b")
    target.gates = [Self.gate(id: "review", decision: .rejected, findings: [
      // Same file+message, different line: matched, so not added/resolved.
      LoopBlockingFinding(id: "f1b", severity: "high", filePath: "a.swift", line: 42, message: "leak"),
      LoopBlockingFinding(id: "f3", severity: "medium", filePath: "b.swift", message: "new bug")
    ])]

    let diff = LoopEvidenceDiffer.diff(base: base, target: target)

    XCTAssertEqual(diff.blockingFindingsAdded.map(\.message), ["new bug"])
    XCTAssertEqual(diff.blockingFindingsResolved.map(\.message), ["pathless"])
  }

  func testChangedFilesDiffByPath() {
    var base = Self.manifest(sessionId: "a")
    base.changedFiles = [LoopChangedFile(path: "keep.swift", changeKind: "modified"),
                         LoopChangedFile(path: "gone.swift", changeKind: "modified")]
    var target = Self.manifest(sessionId: "b")
    target.changedFiles = [LoopChangedFile(path: "keep.swift", changeKind: "modified"),
                          LoopChangedFile(path: "new.swift", changeKind: "added")]

    let diff = LoopEvidenceDiffer.diff(base: base, target: target)
    XCTAssertEqual(diff.changedFilesAdded, ["new.swift"])
    XCTAssertEqual(diff.changedFilesRemoved, ["gone.swift"])
  }

  func testVerificationOutcomeFlipMatchedByCommandSummary() {
    var base = Self.manifest(sessionId: "a")
    base.commands = [LoopCommandEvidence(id: "cmd-1", argvSummary: "swift test", argvRedactionStatus: "clean")]
    base.verification = [LoopVerificationEvidence(id: "v1", commandRef: "cmd-1", outcome: "failed")]
    var target = Self.manifest(sessionId: "b")
    // Different command id, same summary: joins on the summary string.
    target.commands = [LoopCommandEvidence(id: "cmd-9", argvSummary: "swift test", argvRedactionStatus: "clean")]
    target.verification = [LoopVerificationEvidence(id: "v2", commandRef: "cmd-9", outcome: "passed")]

    let diff = LoopEvidenceDiffer.diff(base: base, target: target)
    XCTAssertEqual(diff.verificationChanges.count, 1)
    XCTAssertEqual(diff.verificationChanges.first?.commandSummary, "swift test")
    XCTAssertEqual(diff.verificationChanges.first?.baseOutcome, "failed")
    XCTAssertEqual(diff.verificationChanges.first?.targetOutcome, "passed")
  }

  func testCostDeltaOnlyWhenBothSummariesPresent() {
    var base = Self.manifest(sessionId: "a")
    base.costSummary = LoopCostSummary(totalInputTokens: 100, totalTokens: 140, stepsWithUsage: 1)
    var targetNoCost = Self.manifest(sessionId: "b")
    targetNoCost.costSummary = nil

    let noDelta = LoopEvidenceDiffer.diff(base: base, target: targetNoCost)
    XCTAssertNil(noDelta.costDelta)
    XCTAssertTrue(noDelta.diagnostics.contains { $0.contains("only one run") })

    var target = Self.manifest(sessionId: "b")
    target.costSummary = LoopCostSummary(totalInputTokens: 130, totalTokens: 200, stepsWithUsage: 1)
    let diff = LoopEvidenceDiffer.diff(base: base, target: target)
    XCTAssertEqual(diff.costDelta?.totalInputTokensDelta, 30)
    XCTAssertEqual(diff.costDelta?.totalTokensDelta, 60)
    // Neither side reported duration, so the delta stays nil.
    XCTAssertNil(diff.costDelta?.totalDurationMsDelta)
  }

  func testResidualRiskDeltaMatchesBySeverityAndMessage() {
    var base = Self.manifest(sessionId: "a")
    base.residualRisks = [LoopResidualRisk(severity: "medium", message: "flaky")]
    var target = Self.manifest(sessionId: "b")
    target.residualRisks = [LoopResidualRisk(severity: "low", message: "docs")]

    let delta = LoopEvidenceDiffer.diff(base: base, target: target).residualRiskDelta
    XCTAssertEqual(delta.added.map(\.message), ["docs"])
    XCTAssertEqual(delta.resolved.map(\.message), ["flaky"])
  }

  func testDiffIsCodable() throws {
    var base = Self.manifest(sessionId: "a")
    base.gates = [Self.gate(id: "review", decision: .rejected, high: 1)]
    let target = Self.manifest(sessionId: "b")
    let diff = LoopEvidenceDiffer.diff(base: base, target: target)

    let data = try JSONEncoder().encode(diff)
    let decoded = try JSONDecoder().decode(LoopEvidenceDiff.self, from: data)
    XCTAssertEqual(decoded, diff)
  }

  // MARK: - Fixtures

  private static func manifest(
    sessionId: String,
    workflowId: String = "wf",
    definitionDigest: String? = nil
  ) -> LoopEvidenceManifest {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "loop-evidence-\(sessionId)",
      workflowId: workflowId,
      sessionId: sessionId,
      workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow-directory", mutable: true),
      workflowDefinitionDigest: definitionDigest,
      policy: LoopPolicyEvidence(),
      redaction: LoopRedactionSummary(policyName: "summary-only", status: "clean"),
      createdAt: date,
      updatedAt: date
    )
  }

  private static func gate(
    id: String,
    decision: LoopGateDecision,
    high: Int = 0,
    medium: Int = 0,
    findings: [LoopBlockingFinding] = []
  ) -> LoopGateResult {
    LoopGateResult(
      gateId: id,
      stepId: "\(id)-step",
      stepExecutionId: "\(id)-exec",
      decision: decision,
      severityCounts: LoopFindingSeverityCounts(high: high, medium: medium),
      blockingFindings: findings
    )
  }
}
