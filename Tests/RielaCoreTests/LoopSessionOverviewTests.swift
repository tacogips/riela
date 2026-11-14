import Foundation
import RielaCore
import XCTest

final class LoopSessionOverviewTests: XCTestCase {
  func testSummaryProjectionFreezesGateOutcomesAndLineage() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let manifest = LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "loop-evidence-session-1",
      workflowId: "wf",
      sessionId: "session-1",
      workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow-directory", mutable: true),
      policy: LoopPolicyEvidence(),
      recovery: LoopRecoveryLineage(
        entryMode: .rerun,
        sourceSessionId: "session-0",
        sourceStepId: "impl",
        inputReusePolicy: "reuse-runtime-variables"
      ),
      gates: [
        LoopGateResult(
          gateId: "review",
          stepId: "review-step",
          stepExecutionId: "review-exec",
          decision: .needsWork,
          blockingFindings: [
            LoopBlockingFinding(id: "finding-1", severity: "high", message: "bug")
          ]
        )
      ],
      redaction: LoopRedactionSummary(policyName: "summary-only", status: "clean"),
      createdAt: date,
      updatedAt: date
    )
    let metadata = WorkflowLoopMetadata(
      kind: "issue-resolution",
      required: true,
      gates: [LoopGateDeclaration(id: "review", stepId: "review-step", required: true)]
    )

    let summary = LoopSessionSummary.make(manifest: manifest, loopMetadata: metadata)

    XCTAssertEqual(summary.loopKind, "issue-resolution")
    XCTAssertEqual(summary.loopRequired, true)
    XCTAssertEqual(summary.gateOutcomes, [
      LoopGateOutcome(
        gateId: "review",
        stepId: "review-step",
        decision: .needsWork,
        required: true,
        blockingFindingCount: 1
      )
    ])
    XCTAssertEqual(summary.lastGateDecision, "needs_work")
    XCTAssertEqual(summary.blockingFindingCount, 1)
    XCTAssertEqual(summary.entryMode, "rerun")
    XCTAssertEqual(summary.sourceSessionId, "session-0")
  }

  func testOverviewMarksLegacyAndStaleRunningSessions() throws {
    let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
    let session = WorkflowSession(
      workflowId: "wf",
      sessionId: "session-running",
      status: .running,
      entryStepId: "start",
      createdAt: oldDate,
      updatedAt: oldDate
    )

    let overview = LoopSessionOverview.make(
      session: session,
      summary: nil,
      now: oldDate.addingTimeInterval(601)
    )

    XCTAssertFalse(overview.loopEvidenceRecorded)
    XCTAssertNil(overview.gateSummary)
    XCTAssertTrue(overview.possiblyStale)
  }

  func testSummaryDecodesLegacyPayloadWithDefaults() throws {
    let data = Data(#"{"evidenceUpdatedAt":"2023-11-14T22:13:20Z"}"#.utf8)

    let summary = try JSONDecoder.rielaISO8601.decode(LoopSessionSummary.self, from: data)

    XCTAssertEqual(summary.schemaVersion, 1)
    XCTAssertEqual(summary.gateOutcomes, [])
    XCTAssertEqual(summary.blockingFindingCount, 0)
    XCTAssertNil(summary.lastGateDecision)
  }
}

private extension JSONDecoder {
  static var rielaISO8601: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
