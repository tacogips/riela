import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class LoopFindingsExportTests: XCTestCase {
  func testSeverityLevelMapping() {
    XCTAssertEqual(LoopFindingsSARIFExporter.level(forSeverity: "high"), "error")
    XCTAssertEqual(LoopFindingsSARIFExporter.level(forSeverity: "HIGH"), "error")
    XCTAssertEqual(LoopFindingsSARIFExporter.level(forSeverity: "medium"), "warning")
    XCTAssertEqual(LoopFindingsSARIFExporter.level(forSeverity: "low"), "note")
    XCTAssertEqual(LoopFindingsSARIFExporter.level(forSeverity: "informational"), "note")
    // Unknown severity → warning (original preserved in properties).
    XCTAssertEqual(LoopFindingsSARIFExporter.level(forSeverity: "spicy"), "warning")
  }

  func testSarifShapeForFindingsWithAndWithoutFilePath() throws {
    let manifest = Self.manifest(gates: [
      Self.gate("review", findings: [
        LoopBlockingFinding(id: "f1", severity: "high", filePath: "src/a.swift", line: 12, message: "leak"),
        LoopBlockingFinding(id: "f2", severity: "spicy", message: "no path here")
      ])
    ])

    let sarif = LoopFindingsSARIFExporter.sarif(manifest: manifest, gateId: nil)
    let json = try Self.encoded(sarif)

    XCTAssertEqual(json["version"] as? String, "2.1.0")
    let run = try XCTUnwrap((json["runs"] as? [[String: Any]])?.first)
    let driver = try XCTUnwrap(((run["tool"] as? [String: Any])?["driver"]) as? [String: Any])
    XCTAssertEqual(driver["name"] as? String, "riela-loop")
    XCTAssertEqual((driver["rules"] as? [[String: Any]])?.first?["id"] as? String, "review")

    let results = try XCTUnwrap(run["results"] as? [[String: Any]])
    XCTAssertEqual(results.count, 2)

    // First finding (f1) has a physicalLocation and error level.
    let first = results[0]
    XCTAssertEqual(first["ruleId"] as? String, "review")
    XCTAssertEqual(first["level"] as? String, "error")
    let location = try XCTUnwrap((first["locations"] as? [[String: Any]])?.first)
    let physical = try XCTUnwrap((location["physicalLocation"]) as? [String: Any])
    XCTAssertEqual(((physical["artifactLocation"]) as? [String: Any])?["uri"] as? String, "src/a.swift")
    XCTAssertEqual(((physical["region"]) as? [String: Any])?["startLine"] as? Int, 12)

    // Second finding (f2, unknown severity, no path) → warning, no locations,
    // original severity preserved in properties.
    let second = results[1]
    XCTAssertEqual(second["level"] as? String, "warning")
    XCTAssertNil(second["locations"])
    let properties = try XCTUnwrap(second["properties"] as? [String: Any])
    XCTAssertEqual(properties["severity"] as? String, "spicy")
    XCTAssertEqual(properties["sessionId"] as? String, "session-1")
  }

  func testEmptyFindingsEmitValidEmptyRun() throws {
    let manifest = Self.manifest(gates: [Self.gate("review", findings: [])])
    let sarif = LoopFindingsSARIFExporter.sarif(manifest: manifest, gateId: nil)
    let json = try Self.encoded(sarif)

    let run = try XCTUnwrap((json["runs"] as? [[String: Any]])?.first)
    XCTAssertEqual((run["results"] as? [Any])?.count, 0)
    XCTAssertEqual(((run["tool"] as? [String: Any])?["driver"] as? [String: Any])?["name"] as? String, "riela-loop")
  }

  func testGateFilterRestrictsFindings() {
    let manifest = Self.manifest(gates: [
      Self.gate("review", findings: [LoopBlockingFinding(id: "f1", severity: "high", message: "a")]),
      Self.gate("security", findings: [LoopBlockingFinding(id: "f2", severity: "medium", message: "b")])
    ])
    let findings = LoopFindingsSARIFExporter.findings(manifest: manifest, gateId: "security")
    XCTAssertEqual(findings.map(\.findingId), ["f2"])
  }

  // MARK: - Fixtures

  private static func encoded(_ object: JSONObject) throws -> [String: Any] {
    let data = try JSONEncoder().encode(JSONValue.object(object))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private static func gate(_ gateId: String, findings: [LoopBlockingFinding]) -> LoopGateResult {
    LoopGateResult(
      gateId: gateId,
      stepId: "\(gateId)-step",
      stepExecutionId: "\(gateId)-exec",
      decision: findings.isEmpty ? .accepted : .rejected,
      blockingFindings: findings
    )
  }

  private static func manifest(gates: [LoopGateResult]) -> LoopEvidenceManifest {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "loop-evidence-session-1",
      workflowId: "wf",
      sessionId: "session-1",
      workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow-directory", mutable: true),
      policy: LoopPolicyEvidence(),
      gates: gates,
      redaction: LoopRedactionSummary(policyName: "summary-only", status: "clean"),
      createdAt: date,
      updatedAt: date
    )
  }
}
