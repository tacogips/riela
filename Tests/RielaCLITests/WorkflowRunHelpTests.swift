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
    XCTAssertTrue(result.stdout.contains("riela serve --note-api [--note-root <dir>] [--host <host>] [--port <port>]"))
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

  func testPackageHelpDocumentsArchiveAndAppImportFlow() async {
    let result = await RielaCLIApplication().run(["package", "--help"])

    XCTAssertEqual(result.exitCode, .success)
    XCTAssertTrue(result.stderr.isEmpty)
    XCTAssertTrue(result.stdout.contains("Riela package"))
    XCTAssertTrue(result.stdout.contains("init <workflow-or-package-dir>"))
    XCTAssertTrue(result.stdout.contains("pack <package-dir>"))
    XCTAssertTrue(result.stdout.contains("validate <package-dir|archive.rielapkg|archive.zip>"))
    XCTAssertTrue(result.stdout.contains("install [package-name|package-dir|archive.rielapkg|archive.zip]"))
    XCTAssertTrue(result.stdout.contains("ci [package-name]"))
    XCTAssertTrue(result.stdout.contains("run|temp-run <package-name|package-dir|archive.rielapkg|archive.zip>"))
    XCTAssertTrue(result.stdout.contains("Package init:"))
    XCTAssertTrue(result.stdout.contains("content-derived checksum"))
    XCTAssertTrue(result.stdout.contains("contains exactly one workflows/<name>/workflow.json"))
    XCTAssertTrue(result.stdout.contains("pass --workflow-definition-dir"))
    XCTAssertTrue(result.stdout.contains("multiple workflows are present"))
    XCTAssertTrue(result.stdout.contains("Manual manifests:"))
    XCTAssertTrue(result.stdout.contains("checksumAlgorithm"))
    XCTAssertTrue(result.stdout.contains("md5"))
    XCTAssertTrue(result.stdout.contains("A .rielapkg or .zip is a portable package archive"))
    XCTAssertTrue(result.stdout.contains("Lockfile installs:"))
    XCTAssertTrue(result.stdout.contains("riela-lock.json"))
    XCTAssertTrue(result.stdout.contains("archive sha256 pins"))
    XCTAssertTrue(result.stdout.contains("RielaApp can import the same package folder, .rielapkg, or .zip"))
    XCTAssertTrue(result.stdout.contains("--import-workflow-or-package <path>"))
    XCTAssertTrue(result.stdout.contains("--import-workflow-or-package <path> --open-workflows"))
    XCTAssertTrue(result.stdout.contains("launch RielaApp with --import-workflow-or-package <path> --open-workflows"))
    XCTAssertTrue(result.stdout.contains("profiles keeps enabled workflows and imported packages separate"))
  }

  func testWorkflowPackageHelpUsesWorkflowPackagePrefix() async {
    let result = await RielaCLIApplication().run(["workflow", "package", "--help"])

    XCTAssertEqual(result.exitCode, .success)
    XCTAssertTrue(result.stderr.isEmpty)
    XCTAssertTrue(result.stdout.contains("riela workflow package pack <package-dir>"))
    XCTAssertTrue(result.stdout.contains("riela workflow package init <workflow-or-package-dir>"))
    XCTAssertTrue(result.stdout.contains("riela workflow package install"))
    XCTAssertTrue(result.stdout.contains("riela workflow package ci"))
  }
}
