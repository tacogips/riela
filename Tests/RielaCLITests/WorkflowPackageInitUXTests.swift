import Foundation
import XCTest
@testable import RielaCLI

extension WorkflowCommandTests {
  func testPackageInitInfersSingleWorkflowUnderWorkflowsDirectory() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-init-infer-workflow-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    let workflowDirectory = packageSource.appendingPathComponent("workflows/worker-only-single-step", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try copyExampleWorkflow(root: root, to: workflowDirectory)

    let result = await RielaCLIApplication().run([
      "package", "init", packageSource.path,
      "--package-name", "inferred-demo",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let initialized = try decodeJSON(WorkflowPackageCommandResult.self, from: result.stdout)
    XCTAssertEqual(initialized.packages.first?.workflowDirectory, "workflows/worker-only-single-step")
    let manifestURL = packageSource.appendingPathComponent("riela-package.json")
    let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
    XCTAssertTrue(
      manifestText.contains("\n  \"workflowDirectory\" : \"workflows\\/worker-only-single-step\""),
      manifestText
    )
  }

  func testPackageInitRequiresWorkflowDefinitionDirWhenMultipleWorkflowsArePresent() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-init-ambiguous-workflow-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try copyExampleWorkflow(root: root, to: packageSource.appendingPathComponent("workflows/alpha", isDirectory: true))
    try copyExampleWorkflow(root: root, to: packageSource.appendingPathComponent("workflows/beta", isDirectory: true))

    let result = await RielaCLIApplication().run([
      "package", "init", packageSource.path,
      "--package-name", "ambiguous-demo",
      "--working-dir", tempDir.path
    ])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.contains("found multiple workflow directories"), result.stderr)
    XCTAssertTrue(result.stderr.contains("--workflow-definition-dir <relative-path>"), result.stderr)
    XCTAssertTrue(result.stderr.contains("workflows/alpha, workflows/beta"), result.stderr)
  }

  private func copyExampleWorkflow(root: String, to destination: URL) throws {
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let source = URL(fileURLWithPath: root)
      .appendingPathComponent("examples/worker-only-single-step", isDirectory: true)
    try FileManager.default.copyItem(
      at: source.appendingPathComponent("workflow.json"),
      to: destination.appendingPathComponent("workflow.json")
    )
    try FileManager.default.copyItem(
      at: source.appendingPathComponent("nodes", isDirectory: true),
      to: destination.appendingPathComponent("nodes", isDirectory: true)
    )
    try FileManager.default.copyItem(
      at: source.appendingPathComponent("prompts", isDirectory: true),
      to: destination.appendingPathComponent("prompts", isDirectory: true)
    )
  }
}
