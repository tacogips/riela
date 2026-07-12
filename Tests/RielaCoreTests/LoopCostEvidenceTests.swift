import Foundation
import RielaCore
import XCTest

final class LoopCostEvidenceTests: XCTestCase {
  func testCostEvidenceRoundTrips() throws {
    let evidence = LoopCostEvidence(
      stepExecutionId: "impl-exec",
      backend: "codex",
      model: "gpt-5.5",
      inputTokens: 120,
      outputTokens: 45,
      totalTokens: 165,
      durationMs: 9_000,
      diagnostics: ["normalized from total_token_usage"]
    )

    let data = try JSONEncoder().encode(evidence)
    let decoded = try JSONDecoder().decode(LoopCostEvidence.self, from: data)

    XCTAssertEqual(decoded, evidence)
  }

  func testCostEvidenceDecodesLegacyPayloadWithDefaults() throws {
    let data = Data(#"{"stepExecutionId":"impl-exec"}"#.utf8)

    let evidence = try JSONDecoder().decode(LoopCostEvidence.self, from: data)

    XCTAssertEqual(evidence.stepExecutionId, "impl-exec")
    XCTAssertNil(evidence.inputTokens)
    XCTAssertNil(evidence.totalTokens)
    XCTAssertEqual(evidence.diagnostics, [])
  }

  func testCostSummaryFromCostsComputesHonestPartialSums() {
    let costs = [
      LoopCostEvidence(stepExecutionId: "a", inputTokens: 100, outputTokens: 40, totalTokens: 140, durationMs: 5_000),
      LoopCostEvidence(stepExecutionId: "b", inputTokens: 10, outputTokens: 5, totalTokens: 15, durationMs: 1_000),
      LoopCostEvidence(stepExecutionId: "c", diagnostics: ["no usage events"])
    ]

    let summary = LoopCostSummary.make(from: costs)

    XCTAssertEqual(summary.totalInputTokens, 110)
    XCTAssertEqual(summary.totalOutputTokens, 45)
    XCTAssertEqual(summary.totalTokens, 155)
    XCTAssertEqual(summary.totalDurationMs, 6_000)
    XCTAssertEqual(summary.stepsWithUsage, 2)
    XCTAssertEqual(summary.stepsWithoutUsage, 1)
    XCTAssertTrue(summary.isPartial)
  }

  func testCostSummaryFromAllUsageIsNotPartialAndDropsAbsentDimensions() {
    let costs = [
      LoopCostEvidence(stepExecutionId: "a", inputTokens: 100, outputTokens: 40, totalTokens: 140)
    ]

    let summary = LoopCostSummary.make(from: costs)

    XCTAssertEqual(summary.stepsWithUsage, 1)
    XCTAssertEqual(summary.stepsWithoutUsage, 0)
    XCTAssertFalse(summary.isPartial)
    // No step reported a duration, so the total stays nil rather than 0.
    XCTAssertNil(summary.totalDurationMs)
  }

  func testManifestRoundTripsWithCostEvidence() throws {
    var manifest = Self.baseManifest()
    manifest.costs = [
      LoopCostEvidence(stepExecutionId: "impl-exec", backend: "codex", inputTokens: 100, outputTokens: 40, totalTokens: 140)
    ]
    manifest.costSummary = LoopCostSummary.make(from: manifest.costs)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let data = try encoder.encode(manifest)
    let decoded = try decoder.decode(LoopEvidenceManifest.self, from: data)

    XCTAssertEqual(decoded, manifest)
    XCTAssertEqual(decoded.costs.count, 1)
    XCTAssertEqual(decoded.costSummary?.totalTokens, 140)
  }

  func testManifestOmitsEmptyCostFieldsAndDecodesLegacyPayload() throws {
    let manifest = Self.baseManifest()
    XCTAssertTrue(manifest.costs.isEmpty)
    XCTAssertNil(manifest.costSummary)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(manifest)
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))

    // A manifest without cost evidence must serialize exactly as before the
    // fields existed: no `costs` and no `costSummary` keys.
    XCTAssertFalse(json.contains("\"costs\""))
    XCTAssertFalse(json.contains("\"costSummary\""))

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(LoopEvidenceManifest.self, from: data)

    XCTAssertEqual(decoded.costs, [])
    XCTAssertNil(decoded.costSummary)
    XCTAssertEqual(decoded, manifest)
  }

  private static func baseManifest() -> LoopEvidenceManifest {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "loop-evidence-session-1",
      workflowId: "wf",
      sessionId: "session-1",
      workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow-directory", mutable: true),
      policy: LoopPolicyEvidence(),
      redaction: LoopRedactionSummary(policyName: "summary-only", status: "clean"),
      createdAt: date,
      updatedAt: date
    )
  }
}
