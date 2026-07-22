import Foundation
import XCTest
@testable import RielaCLI

extension WorkflowCommandScopedResolutionTests {
  func testTemporaryResolutionIsExactlyFifthAfterWorkflowAndPackageCandidates() async throws {
    let layout = try makeResolutionMatrixLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let workflowId = "five-way"
    let environment = ["HOME": layout.home.path]

    try writeResolutionMatrixWorkflow(
      at: layout.project.appendingPathComponent(".riela/workflows/\(workflowId)"),
      workflowId: workflowId,
      description: "project-workflow"
    )
    try writeResolutionMatrixWorkflow(
      at: layout.home.appendingPathComponent(".riela/workflows/\(workflowId)"),
      workflowId: workflowId,
      description: "user-workflow"
    )
    try writeResolutionMatrixPackage(
      at: layout.project.appendingPathComponent(".riela/packages/\(workflowId)"),
      workflowId: workflowId,
      description: "project-package"
    )
    try writeResolutionMatrixPackage(
      at: layout.home.appendingPathComponent(".riela/packages/\(workflowId)"),
      workflowId: workflowId,
      description: "user-package"
    )
    let temporaryInput = layout.inputs.appendingPathComponent(workflowId, isDirectory: true)
    try writeResolutionMatrixWorkflow(
      at: temporaryInput,
      workflowId: workflowId,
      description: "temporary-workflow"
    )
    let registration = await RielaCLIApplication().run([
      "workflow", "register", temporaryInput.path, "--temporary", "--output", "json"
    ], environment: environment)
    XCTAssertEqual(registration.exitCode, .success, registration.stderr + registration.stdout)

    let options = WorkflowResolutionOptions(
      workflowName: workflowId,
      scope: .auto,
      workingDirectory: layout.project.path
    )
    try CLIRuntimeEnvironment.$overrides.withValue(environment) {
      let projectWorkflow = try FileSystemWorkflowBundleResolver().resolve(options)
      XCTAssertEqual(projectWorkflow.workflow.description, "project-workflow")
      XCTAssertEqual(projectWorkflow.sourceScope, .project)
      XCTAssertNil(projectWorkflow.packageManifest)
      XCTAssertFalse(projectWorkflow.temporary)

      try FileManager.default.removeItem(
        at: layout.project.appendingPathComponent(".riela/workflows/\(workflowId)")
      )
      let userWorkflow = try FileSystemWorkflowBundleResolver().resolve(options)
      XCTAssertEqual(userWorkflow.workflow.description, "user-workflow")
      XCTAssertEqual(userWorkflow.sourceScope, .user)
      XCTAssertNil(userWorkflow.packageManifest)
      XCTAssertFalse(userWorkflow.temporary)

      try FileManager.default.removeItem(
        at: layout.home.appendingPathComponent(".riela/workflows/\(workflowId)")
      )
      let projectPackage = try FileSystemWorkflowBundleResolver().resolve(options)
      XCTAssertEqual(projectPackage.workflow.description, "project-package")
      XCTAssertEqual(projectPackage.sourceScope, .project)
      XCTAssertEqual(projectPackage.packageManifest?.name, workflowId)
      XCTAssertFalse(projectPackage.temporary)

      try FileManager.default.removeItem(
        at: layout.project.appendingPathComponent(".riela/packages/\(workflowId)")
      )
      let userPackage = try FileSystemWorkflowBundleResolver().resolve(options)
      XCTAssertEqual(userPackage.workflow.description, "user-package")
      XCTAssertEqual(userPackage.sourceScope, .user)
      XCTAssertEqual(userPackage.packageManifest?.name, workflowId)
      XCTAssertFalse(userPackage.temporary)

      try FileManager.default.removeItem(
        at: layout.home.appendingPathComponent(".riela/packages/\(workflowId)")
      )
      let temporary = try FileSystemWorkflowBundleResolver().resolve(options)
      XCTAssertEqual(temporary.workflow.description, "temporary-workflow")
      XCTAssertEqual(temporary.sourceScope, .user)
      XCTAssertNil(temporary.packageManifest)
      XCTAssertTrue(temporary.temporary)
    }
  }

  func testAutomaticFallbackReachesTemporaryButExplicitScopesFailFast() async throws {
    let layout = try makeResolutionMatrixLayout()
    defer { try? FileManager.default.removeItem(at: layout.base) }
    let environment = ["HOME": layout.home.path]
    let application = RielaCLIApplication()

    for (workflowId, invalidScope) in [("project-fallback", WorkflowScope.project), ("user-fallback", .user)] {
      let invalidRoot = invalidScope == .project ? layout.project : layout.home
      let invalidDirectory = invalidRoot.appendingPathComponent(
        ".riela/workflows/\(workflowId)",
        isDirectory: true
      )
      try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
      try #"{"workflowId":"broken""#.write(
        to: invalidDirectory.appendingPathComponent("workflow.json"),
        atomically: true,
        encoding: .utf8
      )
      let temporaryInput = layout.inputs.appendingPathComponent(workflowId, isDirectory: true)
      try writeResolutionMatrixWorkflow(
        at: temporaryInput,
        workflowId: workflowId,
        description: "temporary-fallback"
      )
      let registration = await application.run([
        "workflow", "register", temporaryInput.path, "--temporary", "--output", "json"
      ], environment: environment)
      XCTAssertEqual(registration.exitCode, .success, registration.stderr + registration.stdout)

      try CLIRuntimeEnvironment.$overrides.withValue(environment) {
        let automatic = try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
          workflowName: workflowId,
          scope: .auto,
          workingDirectory: layout.project.path
        ))
        XCTAssertTrue(automatic.temporary)
        XCTAssertEqual(automatic.workflow.description, "temporary-fallback")
        XCTAssertThrowsError(try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
          workflowName: workflowId,
          scope: invalidScope,
          workingDirectory: layout.project.path
        )))
      }
    }
  }
}

private struct ResolutionMatrixLayout {
  var base: URL
  var home: URL
  var project: URL
  var inputs: URL
}

private func makeResolutionMatrixLayout() throws -> ResolutionMatrixLayout {
  let base = FileManager.default.temporaryDirectory
    .appendingPathComponent("riela-resolution-matrix-\(UUID().uuidString)", isDirectory: true)
  let layout = ResolutionMatrixLayout(
    base: base,
    home: base.appendingPathComponent("home", isDirectory: true),
    project: base.appendingPathComponent("project", isDirectory: true),
    inputs: base.appendingPathComponent("inputs", isDirectory: true)
  )
  for directory in [layout.home, layout.project, layout.inputs] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  return layout
}

private func writeResolutionMatrixPackage(
  at packageDirectory: URL,
  workflowId: String,
  description: String
) throws {
  try writeResolutionMatrixWorkflow(
    at: packageDirectory,
    workflowId: workflowId,
    description: description
  )
  try """
  {
    "name": "\(workflowId)",
    "version": "1.0.0",
    "kind": "workflow",
    "description": "\(description)",
    "tags": [],
    "registry": "local",
    "checksum": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "checksumAlgorithm": "md5",
    "workflowDirectory": "."
  }
  """.write(
    to: packageDirectory.appendingPathComponent("riela-package.json"),
    atomically: true,
    encoding: .utf8
  )
}

private func writeResolutionMatrixWorkflow(
  at directory: URL,
  workflowId: String,
  description: String
) throws {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try """
  {
    "workflowId": "\(workflowId)",
    "description": "\(description)",
    "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
    "entryStepId": "work",
    "nodes": [{ "id": "worker", "addon": { "name": "example-addon" } }],
    "steps": [{ "id": "work", "nodeId": "worker", "role": "worker" }]
  }
  """.write(to: directory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
}
