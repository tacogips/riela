import Foundation
import XCTest
@testable import RielaCLI

final class WorkflowCommandScopedResolutionTests: XCTestCase {
  func testTemporaryProvenanceDoesNotChangeWorkflowSourceKind() throws {
    let encoded = try JSONEncoder().encode(WorkflowCatalogEntry(
      workflowName: "temporary-demo",
      scope: .user,
      sourceKind: .workflow,
      workflowDirectory: "/tmp/temporary-demo",
      mutable: true,
      provenance: .mutable,
      valid: true,
      diagnostics: []
    ))
    let decoded = try JSONDecoder().decode(WorkflowCatalogEntry.self, from: encoded)
    XCTAssertEqual(decoded.sourceKind, .workflow)
    XCTAssertEqual(decoded.provenance, .mutable)
  }
}

extension WorkflowCommandTests {
  func testScopedWorkflowNamesRejectTraversalAndSlashTargets() async throws {
    let validate = await RielaCLIApplication().run([
      "workflow", "validate", "../../examples/worker-only-single-step",
      "--scope", "project",
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .usage)
    XCTAssertTrue(validate.stderr.isEmpty)
    let validateFailure = try decodeJSON(WorkflowValidationFailureResult.self, from: validate.stdout)
    XCTAssertEqual(validateFailure.workflowId, "../../examples/worker-only-single-step")
    XCTAssertEqual(validateFailure.exitCode, CLIExitCode.usage.rawValue)
    XCTAssertTrue(validateFailure.error.contains("invalid scoped workflow or package name"))

    let inspect = await RielaCLIApplication().run([
      "workflow", "inspect", "nested/workflow",
      "--scope", "project",
      "--output", "json"
    ])
    XCTAssertEqual(inspect.exitCode, .usage)
    XCTAssertTrue(inspect.stderr.isEmpty)
    let inspectFailure = try decodeJSON(WorkflowInspectionFailureResult.self, from: inspect.stdout)
    XCTAssertEqual(inspectFailure.workflowId, "nested/workflow")
    XCTAssertEqual(inspectFailure.exitCode, CLIExitCode.usage.rawValue)
    XCTAssertTrue(inspectFailure.error.contains("invalid scoped workflow or package name"))

    let run = await RielaCLIApplication().run([
      "workflow", "run", "../worker-only-single-step",
      "--scope", "project",
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .usage)
    XCTAssertTrue(run.stderr.isEmpty)
    let runFailure = try decodeJSON(WorkflowRunFailureResult.self, from: run.stdout)
    XCTAssertEqual(runFailure.target, "../worker-only-single-step")
    XCTAssertEqual(runFailure.exitCode, CLIExitCode.usage.rawValue)
    XCTAssertTrue(runFailure.error.contains("invalid scoped workflow or package name"))
  }

  func testWorkflowResolutionSkipsNonWorkflowPackages() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-non-workflow-package-\(UUID().uuidString)", isDirectory: true)
    let packageDirectory = tempDir
      .appendingPathComponent(".riela/packages/addon-only", isDirectory: true)
    try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try """
    {
      "name": "addon-only",
      "version": "1.0.0",
      "kind": "node-addon",
      "description": "Addon-only package",
      "tags": [],
      "registry": "local",
      "checksum": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "checksumAlgorithm": "md5",
      "addons": [{
        "name": "demo-addon",
        "version": "1.0.0",
        "sourcePath": "addons/demo-addon",
        "contentDigest": "sha256:\(String(repeating: "a", count: 64))",
        "capabilities": [{"name": "process.spawn", "reason": "runs package command"}],
        "execution": {"kind": "local-command", "entrypoint": "run.sh"}
      }]
    }
    """.write(to: packageDirectory.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let validate = await RielaCLIApplication().run([
      "workflow", "validate", "addon-only",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .failure)
    XCTAssertTrue(validate.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowValidationFailureResult.self, from: validate.stdout)
    XCTAssertEqual(failure.workflowId, "addon-only")
    XCTAssertTrue(failure.error.contains("not found"), failure.error)
    XCTAssertFalse(failure.error.contains("package source validation failed"), failure.error)
  }

  func testScopedWorkflowResolutionRejectsSymlinkEscapes() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-symlink-escape-\(UUID().uuidString)", isDirectory: true)
    let scopedRoot = tempDir
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("workflows", isDirectory: true)
    try FileManager.default.createDirectory(at: scopedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createSymbolicLink(
      at: scopedRoot.appendingPathComponent("escape"),
      withDestinationURL: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step").standardizedFileURL
    )

    let validate = await RielaCLIApplication().run([
      "workflow", "validate", "escape",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .failure)
    XCTAssertTrue(validate.stderr.isEmpty)
    let validateFailure = try decodeJSON(WorkflowValidationFailureResult.self, from: validate.stdout)
    XCTAssertFalse(validateFailure.valid)
    XCTAssertEqual(validateFailure.workflowId, "escape")
    XCTAssertTrue(validateFailure.error.contains("escapes"))

    let inspect = await RielaCLIApplication().run([
      "workflow", "inspect", "escape",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(inspect.exitCode, .failure)
    XCTAssertTrue(inspect.stderr.isEmpty)
    let inspectFailure = try decodeJSON(WorkflowInspectionFailureResult.self, from: inspect.stdout)
    XCTAssertEqual(inspectFailure.workflowId, "escape")
    XCTAssertTrue(inspectFailure.error.contains("escapes"))

    let run = await RielaCLIApplication().run([
      "workflow", "run", "escape",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .failure)
    XCTAssertTrue(run.stderr.isEmpty)
    let runFailure = try decodeJSON(WorkflowRunFailureResult.self, from: run.stdout)
    XCTAssertEqual(runFailure.target, "escape")
    XCTAssertTrue(runFailure.error.contains("escapes"))
  }

  func testScopedWorkflowResolutionRejectsSymlinkedWorkflowJSON() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-workflow-json-symlink-\(UUID().uuidString)", isDirectory: true)
    let workflowDir = tempDir
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("workflows", isDirectory: true)
      .appendingPathComponent("escape", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createSymbolicLink(
      at: workflowDir.appendingPathComponent("workflow.json"),
      withDestinationURL: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/workflow.json").standardizedFileURL
    )

    try await assertScopedProjectWorkflowEscapeRejected(workingDirectory: tempDir)
  }

  func testScopedWorkflowResolutionRejectsSymlinkedNodePayload() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-node-payload-symlink-\(UUID().uuidString)", isDirectory: true)
    let workflowDir = tempDir
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("workflows", isDirectory: true)
      .appendingPathComponent("escape", isDirectory: true)
    let nodesDir = workflowDir.appendingPathComponent("nodes", isDirectory: true)
    try FileManager.default.createDirectory(at: nodesDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let workflowJSON = try String(
      contentsOfFile: "\(root)/examples/worker-only-single-step/workflow.json",
      encoding: .utf8
    )
    try workflowJSON.write(to: workflowDir.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: nodesDir.appendingPathComponent("node-main-worker.json"),
      withDestinationURL: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/nodes/node-main-worker.json").standardizedFileURL
    )

    try await assertScopedProjectWorkflowEscapeRejected(workingDirectory: tempDir)
  }
}
