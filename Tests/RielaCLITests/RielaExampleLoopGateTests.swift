import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class RielaExampleLoopGateTests: XCTestCase {
  func testRequiredLoopGateFailureExampleFailsClosedWithLoopEvidence() async throws {
    let root = repositoryRoot()
    let examplesRoot = root.appendingPathComponent("examples", isDirectory: true)
    let workflowName = "required-loop-gate-failure"
    let scenario = examplesRoot
      .appendingPathComponent(workflowName, isDirectory: true)
      .appendingPathComponent("mock-scenario-rejected.json")
    let sessionStore = root
      .appendingPathComponent("tmp/test-required-loop-gate-failure-sessions-\(UUID().uuidString)", isDirectory: true)
    let artifactRoot = root
      .appendingPathComponent("tmp/test-required-loop-gate-failure-artifacts-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: sessionStore)
      try? FileManager.default.removeItem(at: artifactRoot)
    }

    let result = await RielaCLIApplication().run([
      "workflow", "run", workflowName,
      "--workflow-definition-dir", examplesRoot.path,
      "--mock-scenario", scenario.path,
      "--session-store", sessionStore.path,
      "--artifact-root", artifactRoot.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure, result.stderr + result.stdout)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(payload.workflowId, workflowName)
    XCTAssertEqual(payload.status, .failed)
    XCTAssertEqual(payload.exitCode, 1)
    XCTAssertEqual(payload.loopEvidence?.gateCount, 1)
    XCTAssertEqual(payload.loopEvidence?.acceptedGateCount, 0)
    XCTAssertEqual(payload.loopEvidence?.rejectedGateCount, 1)
    XCTAssertEqual(payload.loopEvidence?.blockingFindingCount, 2)

    let loopGates = await RielaCLIApplication().run([
      "loop", "gates", payload.session.sessionId,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(loopGates.exitCode, .success, loopGates.stderr + loopGates.stdout)
    let gates = try decoder.decode(LoopGatesCommandResult.self, from: Data(loopGates.stdout.utf8))
    XCTAssertTrue(gates.loopEvidenceRecorded)
    XCTAssertEqual(gates.gates.first?.gateId, "implementation-review")
    XCTAssertEqual(gates.gates.first?.decision, .rejected)
    XCTAssertEqual(gates.gates.first?.blockingFindings.count, 2)
  }

  private func repositoryRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
        return url
      }
      url.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  }
}
