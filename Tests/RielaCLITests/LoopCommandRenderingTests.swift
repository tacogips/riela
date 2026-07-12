import RielaCore
import XCTest
@testable import RielaCLI

final class LoopCommandRenderingTests: XCTestCase {
  func testCostCellRendersNotRecordedWhenAbsent() {
    XCTAssertEqual(LoopCommandRunner.costCell(nil), "not-recorded")
  }

  func testCostCellRendersTokensAndDuration() {
    let cost = LoopCostSummary(totalTokens: 1_200, totalDurationMs: 9_000, stepsWithUsage: 2)
    XCTAssertEqual(LoopCommandRunner.costCell(cost), "1200tok 9000ms")
  }

  func testCostCellFlagsPartialTotals() {
    let cost = LoopCostSummary(totalTokens: 500, stepsWithUsage: 1, stepsWithoutUsage: 1)
    XCTAssertEqual(LoopCommandRunner.costCell(cost), "500tok (partial)")
  }

  func testCostCellRendersNoUsageWhenRecordedButEmpty() {
    let cost = LoopCostSummary(stepsWithoutUsage: 2)
    // No token/duration dimensions, and all steps lacked usage.
    XCTAssertEqual(LoopCommandRunner.costCell(cost), "no-usage (partial)")
  }

  func testStatsTextLinesRenderKeyMetrics() {
    let stats = LoopWorkflowStats(
      workflowId: "wf",
      windowRuns: 3,
      completedRuns: 2,
      failedRuns: 1,
      acceptedRuns: 2,
      gateFailureCounts: ["review": 1, "style": 2],
      rerunCount: 1,
      meanDurationMs: 4_000,
      meanTotalTokens: 200,
      lastAcceptedSessionId: "s3",
      diagnostics: ["1 of 3 runs have no recorded cost; token mean is partial"]
    )

    let lines = LoopCommandRunner.statsTextLines(stats)
    XCTAssertTrue(lines.contains("workflow: wf"))
    XCTAssertTrue(lines.contains("acceptedRuns: 2"))
    XCTAssertTrue(lines.contains("meanTotalTokens: 200"))
    XCTAssertTrue(lines.contains("lastAcceptedSessionId: s3"))
    XCTAssertTrue(lines.contains("gateFailures: review=1 style=2"))
    XCTAssertTrue(lines.contains("diagnostic: 1 of 3 runs have no recorded cost; token mean is partial"))
  }

  func testStatsTextLinesRenderAbsentMeansAsNotRecorded() {
    let stats = LoopWorkflowStats(workflowId: "wf")
    let lines = LoopCommandRunner.statsTextLines(stats)
    XCTAssertTrue(lines.contains("meanDurationMs: not-recorded"))
    XCTAssertTrue(lines.contains("meanTotalTokens: not-recorded"))
    XCTAssertTrue(lines.contains("lastAcceptedSessionId: none"))
    XCTAssertTrue(lines.contains("gateFailures: none"))
  }

  func testGateCheckExitCodesArePinned() {
    // Guard against later exit-code unification.
    XCTAssertEqual(CLIExitCode.success.rawValue, 0)
    XCTAssertEqual(CLIExitCode.failure.rawValue, 1)
    XCTAssertEqual(CLIExitCode.usage.rawValue, 2)
    XCTAssertEqual(CLIExitCode.gateCheckFailed.rawValue, 3)
    XCTAssertEqual(CLIExitCode.noLoopEvidence.rawValue, 4)
  }

  func testEvaluateRequiredGatesPassesWhenAllAcceptedWithoutBlocking() {
    let gates = [
      Self.gate("review", .accepted),
      Self.gate("security", .accepted)
    ]
    let result = LoopCommandRunner.evaluateRequiredGates(requiredGateIds: ["review", "security"], gates: gates)
    XCTAssertTrue(result.allAccepted)
    XCTAssertEqual(result.failing, [])
  }

  func testEvaluateRequiredGatesFailsOnMissingRejectedOrBlocking() {
    let gates = [
      Self.gate("review", .rejected),
      Self.gate("security", .accepted, blocking: [LoopBlockingFinding(id: "f", severity: "high", message: "leak")])
      // "release" required gate is missing entirely
    ]
    let result = LoopCommandRunner.evaluateRequiredGates(
      requiredGateIds: ["review", "security", "release"],
      gates: gates
    )
    XCTAssertFalse(result.allAccepted)
    XCTAssertEqual(result.failing, ["release", "review", "security"])
  }

  func testEvaluateRequiredGatesUsesLatestVisitPerGate() {
    let gates = [
      Self.gate("review", .rejected), // first visit
      Self.gate("review", .accepted)  // later visit accepts
    ]
    let result = LoopCommandRunner.evaluateRequiredGates(requiredGateIds: ["review"], gates: gates)
    XCTAssertTrue(result.allAccepted)
  }

  func testEvaluateRequiredGatesVacuouslyPassesWithNoRequiredGates() {
    let result = LoopCommandRunner.evaluateRequiredGates(requiredGateIds: [], gates: [])
    XCTAssertTrue(result.allAccepted)
    XCTAssertEqual(result.failing, [])
  }

  private static func gate(
    _ gateId: String,
    _ decision: LoopGateDecision,
    blocking: [LoopBlockingFinding] = []
  ) -> LoopGateResult {
    LoopGateResult(
      gateId: gateId,
      stepId: "\(gateId)-step",
      stepExecutionId: "\(gateId)-exec",
      decision: decision,
      blockingFindings: blocking
    )
  }

  func testDiffTextLinesRenderCountsAndDiagnostics() {
    let diff = LoopEvidenceDiff(
      baseSessionId: "a",
      targetSessionId: "b",
      sameWorkflow: false,
      workflowDefinitionDigestChanged: nil,
      gateChanges: [LoopGateChange(gateId: "g", baseDecision: .rejected, targetDecision: .accepted,
                                   severityCountsDelta: LoopFindingSeverityCounts())],
      blockingFindingsResolved: [LoopBlockingFinding(id: "f", severity: "high", message: "leak")],
      costDelta: LoopCostSummaryDelta(totalTokensDelta: -50),
      diagnostics: ["cross-workflow diff: base workflow x != target workflow y"]
    )

    let lines = LoopCommandRunner.diffTextLines(diff)
    XCTAssertTrue(lines.contains("base: a"))
    XCTAssertTrue(lines.contains("target: b"))
    XCTAssertTrue(lines.contains("sameWorkflow: false"))
    XCTAssertTrue(lines.contains("workflowDefinitionDigestChanged: unknown"))
    XCTAssertTrue(lines.contains("gateChanges: 1"))
    XCTAssertTrue(lines.contains("blockingFindingsResolved: 1"))
    XCTAssertTrue(lines.contains("costTotalTokensDelta: -50"))
    XCTAssertTrue(lines.contains("diagnostic: cross-workflow diff: base workflow x != target workflow y"))
  }
}
