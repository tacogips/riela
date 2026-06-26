import XCTest
@testable import RielaCLI

final class WorkflowRunHelpTests: XCTestCase {
  func testWorkflowRunHelpDocumentsVariablesAndSessionStartOutput() async {
    let result = await RielaCLIApplication().run(["workflow", "run", "worker-only-single-step", "--help"])

    XCTAssertEqual(result.exitCode, .success)
    XCTAssertTrue(result.stderr.isEmpty)
    XCTAssertTrue(result.stdout.contains("Riela workflow run"))
    XCTAssertTrue(result.stdout.contains("--variables <json|@file>"))
    XCTAssertTrue(result.stdout.contains("--stall-timeout-ms <n>"))
    XCTAssertTrue(result.stdout.contains("CLI agent and official SDK backends are not"))
    XCTAssertTrue(result.stdout.contains("JSONL streams session_started before worker backends run"))
    XCTAssertTrue(result.stdout.contains("riela workflow run worker-only-single-step --variables"))
  }
}
