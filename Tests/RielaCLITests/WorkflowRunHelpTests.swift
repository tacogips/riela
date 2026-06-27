import XCTest
@testable import RielaCLI

final class WorkflowRunHelpTests: XCTestCase {
  func testTopLevelHelpRecommendsJSONLForAgentsAndLLMs() async {
    let result = await RielaCLIApplication().run(["--help"])

    XCTAssertEqual(result.exitCode, .success)
    XCTAssertTrue(result.stderr.isEmpty)
    XCTAssertTrue(result.stdout.contains("Prefer --output jsonl"))
    XCTAssertTrue(result.stdout.contains("for automation, agents, and LLM-driven tool use"))
    XCTAssertTrue(result.stdout.contains("Use --output json only when a"))
    XCTAssertTrue(result.stdout.contains("legacy caller explicitly requires"))
  }

  func testWorkflowRunHelpDocumentsVariablesAndSessionStartOutput() async {
    let result = await RielaCLIApplication().run(["workflow", "run", "worker-only-single-step", "--help"])

    XCTAssertEqual(result.exitCode, .success)
    XCTAssertTrue(result.stderr.isEmpty)
    XCTAssertTrue(result.stdout.contains("Riela workflow run"))
    XCTAssertTrue(result.stdout.contains("--variables <json|@file>"))
    XCTAssertTrue(result.stdout.contains("--stall-timeout-ms <n>"))
    XCTAssertTrue(result.stdout.contains("CLI agent and official SDK backends are not"))
    XCTAssertTrue(result.stdout.contains("Prefer jsonl for agents/LLMs"))
    XCTAssertTrue(result.stdout.contains("json is legacy and emits only after completion"))
    XCTAssertTrue(result.stdout.contains("riela workflow run worker-only-single-step --variables"))
    XCTAssertTrue(result.stdout.contains("--output jsonl"))
  }
}
