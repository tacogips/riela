import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

/// End-to-end live cross-workflow dispatch through the CLI without any agent
/// backend: the caller and callee are command-node workflows resolved from the
/// same --workflow-definition-dir root (examples/workflow-call-live-echo).
final class WorkflowCommandCrossWorkflowDispatchTests: XCTestCase {
  func testLiveRunDispatchesCalleeWorkflowAndResumesWithCalleeResult() async throws {
    let root = repositoryRoot()
    let sessionStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cross-workflow-live-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sessionStore) }

    let run = await RielaCLIApplication().run([
      "workflow", "run", "workflow-call-live-echo",
      "--workflow-definition-dir", "\(root)/examples",
      "--session-store", sessionStore.path,
      "--output", "json"
    ])

    XCTAssertEqual(run.exitCode, .success, run.stderr + run.stdout)
    let result = try decodeJSON(WorkflowRunResult.self, from: run.stdout)
    XCTAssertEqual(result.workflowId, "workflow-call-live-echo")
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.session.executions.map(\.stepId), ["produce-request", "apply-result"])
    XCTAssertEqual(result.rootOutput?["status"], .string("applied"))
    XCTAssertEqual(
      result.rootOutput?["receivedCalleeResult"],
      .string("echoed:outbound-request"),
      "resume step must receive the callee root output, not the outbound handoff echo"
    )
  }

  func testValidateReportsNoCapabilityGapForSupportedCrossWorkflowDispatchShape() async throws {
    let root = repositoryRoot()
    let validate = await RielaCLIApplication().run([
      "workflow", "validate", "workflow-call-live-echo",
      "--workflow-definition-dir", "\(root)/examples",
      "--output", "json"
    ])

    XCTAssertEqual(validate.exitCode, .success, validate.stderr + validate.stdout)
    let result = try decodeJSON(WorkflowValidationCommandResult.self, from: validate.stdout)
    XCTAssertTrue(result.valid)
    XCTAssertTrue(
      result.diagnostics.isEmpty,
      "cross-workflow dispatch with resumeStepId is supported live and must not report gaps: \(result.diagnostics)"
    )
  }

  private func repositoryRoot() -> String {
    FileManager.default.currentDirectoryPath
  }

  private func decodeJSON<T: Decodable>(_ type: T.Type, from stdout: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(stdout.utf8))
  }
}
