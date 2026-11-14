import Foundation
import RielaCore
import XCTest

final class LoopWorkflowStatsTests: XCTestCase {
  func testAggregatesRunSeriesWithRequiredGateAcceptance() {
    let overviews = [
      // newest first
      Self.overview(sessionId: "s3", status: "completed", entryMode: "rerun", durationMs: 4_000,
                    totalTokens: 300, gates: [Self.outcome("review", .accepted, required: true)]),
      Self.overview(sessionId: "s2", status: "failed", durationMs: 2_000,
                    totalTokens: 100, gates: [Self.outcome("review", .rejected, required: true)]),
      Self.overview(sessionId: "s1", status: "completed", durationMs: 6_000,
                    totalTokens: nil, gates: [Self.outcome("review", .accepted, required: true),
                                              Self.outcome("style", .needsWork, required: false)])
    ]

    let stats = LoopWorkflowStats.aggregate(workflowId: "wf", overviews: overviews)

    XCTAssertEqual(stats.windowRuns, 3)
    XCTAssertEqual(stats.completedRuns, 2)
    XCTAssertEqual(stats.failedRuns, 1)
    XCTAssertEqual(stats.acceptedRuns, 2) // s3 and s1 (all required gates accepted)
    XCTAssertEqual(stats.lastAcceptedSessionId, "s3") // newest accepted
    XCTAssertEqual(stats.rerunCount, 1)
    XCTAssertEqual(stats.gateFailureCounts, ["review": 1, "style": 1])
    XCTAssertEqual(stats.meanDurationMs, 4_000) // (4000+2000+6000)/3
    XCTAssertEqual(stats.meanTotalTokens, 200) // (300+100)/2, s1 has no cost
    XCTAssertTrue(stats.diagnostics.contains { $0.contains("no recorded cost") })
  }

  func testAcceptedRequiresAtLeastOneRequiredGate() {
    let overviews = [
      Self.overview(sessionId: "s1", status: "completed", durationMs: 1_000, totalTokens: 10,
                    gates: [Self.outcome("optional-gate", .accepted, required: false)])
    ]

    let stats = LoopWorkflowStats.aggregate(workflowId: "wf", overviews: overviews)
    XCTAssertEqual(stats.acceptedRuns, 0)
    XCTAssertNil(stats.lastAcceptedSessionId)
  }

  func testWindowLimitBoundsAndDiagnoses() {
    let overviews = (0..<5).map { index in
      Self.overview(sessionId: "s\(index)", status: "completed", durationMs: 1_000, totalTokens: 10,
                    gates: [Self.outcome("review", .accepted, required: true)])
    }

    let stats = LoopWorkflowStats.aggregate(workflowId: "wf", overviews: overviews, limit: 2)
    XCTAssertEqual(stats.windowRuns, 2)
    XCTAssertEqual(stats.acceptedRuns, 2)
    XCTAssertTrue(stats.diagnostics.contains { $0.contains("window limited to 2 of 5") })
  }

  func testEmptySeriesProducesEmptyStats() {
    let stats = LoopWorkflowStats.aggregate(workflowId: "wf", overviews: [])
    XCTAssertEqual(stats.windowRuns, 0)
    XCTAssertNil(stats.meanDurationMs)
    XCTAssertNil(stats.meanTotalTokens)
    XCTAssertEqual(stats.gateFailureCounts, [:])
  }

  func testStatsIsCodable() throws {
    let stats = LoopWorkflowStats.aggregate(
      workflowId: "wf",
      overviews: [Self.overview(sessionId: "s1", status: "completed", durationMs: 1_000, totalTokens: 5,
                                gates: [Self.outcome("review", .accepted, required: true)])]
    )
    let data = try JSONEncoder().encode(stats)
    XCTAssertEqual(try JSONDecoder().decode(LoopWorkflowStats.self, from: data), stats)
  }

  // MARK: - Fixtures

  private static func outcome(
    _ gateId: String,
    _ decision: LoopGateDecision,
    required: Bool
  ) -> LoopGateOutcome {
    LoopGateOutcome(gateId: gateId, stepId: "\(gateId)-step", decision: decision, required: required)
  }

  private static func overview(
    sessionId: String,
    status: String,
    entryMode: String? = nil,
    durationMs: Int,
    totalTokens: Int?,
    gates: [LoopGateOutcome]
  ) -> LoopSessionOverview {
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    return LoopSessionOverview(
      workflowId: "wf",
      sessionId: sessionId,
      sessionStatus: status,
      loopEvidenceRecorded: true,
      entryMode: entryMode,
      cost: totalTokens.map { LoopCostSummary(totalTokens: $0, stepsWithUsage: 1) },
      gateOutcomes: gates,
      createdAt: created,
      updatedAt: created.addingTimeInterval(Double(durationMs) / 1_000)
    )
  }
}
