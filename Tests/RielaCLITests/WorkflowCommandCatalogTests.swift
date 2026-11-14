import Foundation
import RielaAdapters
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

final class WorkflowCommandCatalogTests: XCTestCase {
  func testListRejectsEmptyPositionalQuery() async {
    let result = await RielaCLIApplication().run([
      "workflow", "list", "", "--output", "json"
    ])
    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue((result.stderr + result.stdout).contains("query must not be empty"))
  }

  func testListParserKeepsTemporaryExclusionAndQuery() throws {
    let command = try RielaArgumentParser().parse([
      "workflow", "list", "Needle", "--scope", "user", "--exclude-temporary", "--output", "table"
    ])
    guard case let .workflow(.list(options)) = command else {
      return XCTFail("expected workflow list command")
    }
    XCTAssertEqual(options.target, "Needle")
    XCTAssertEqual(options.output, .table)
    XCTAssertTrue(options.arguments.contains("--exclude-temporary"))
  }
}

extension WorkflowCommandTests {
  func testAutoScopeSkipsInvalidProjectWorkflowWhenUserWorkflowIsValid() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-auto-invalid-project-\(UUID().uuidString)", isDirectory: true)
    let projectRoot = tempDir.appendingPathComponent("project", isDirectory: true)
    let homeRoot = tempDir.appendingPathComponent("home", isDirectory: true)
    let workflowName = "shadowed-flow"
    let projectWorkflow = projectRoot
      .appendingPathComponent(".riela/workflows", isDirectory: true)
      .appendingPathComponent(workflowName, isDirectory: true)
    let userWorkflow = homeRoot
      .appendingPathComponent(".riela/workflows", isDirectory: true)
      .appendingPathComponent(workflowName, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: projectWorkflow, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: userWorkflow.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"workflowId": "broken","#.write(
      to: projectWorkflow.appendingPathComponent("workflow.json"),
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: root).appendingPathComponent("examples/worker-only-single-step", isDirectory: true),
      to: userWorkflow
    )

    let auto = await RielaCLIApplication().run([
      "workflow", "usage", workflowName,
      "--working-dir", projectRoot.path,
      "--output", "json"
    ], environment: ["HOME": homeRoot.path])
    XCTAssertEqual(auto.exitCode, .success, auto.stderr + auto.stdout)
    let autoSummary = try decodeJSON(WorkflowInspectionSummary.self, from: auto.stdout)
    XCTAssertEqual(autoSummary.sourceScope, .user)

    let project = await RielaCLIApplication().run([
      "workflow", "usage", workflowName,
      "--scope", "project",
      "--working-dir", projectRoot.path,
      "--output", "json"
    ], environment: ["HOME": homeRoot.path])
    XCTAssertEqual(project.exitCode, .failure)
  }

  func testAddonOnlyExecutableValidationMatchesDeterministicRunFailure() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-addon-only-\(UUID().uuidString)", isDirectory: true)
    let workflowDir = tempDir.appendingPathComponent("addon-demo", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try """
    {
      "workflowId": "addon-demo",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "addon-step",
      "nodes": [
        { "id": "addon-node", "addon": { "name": "missing-addon" } }
      ],
      "steps": [
        { "id": "addon-step", "nodeId": "addon-node", "role": "worker" }
      ]
    }
    """.write(to: workflowDir.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)

    let validate = await RielaCLIApplication().run([
      "workflow", "validate", "addon-demo",
      "--workflow-definition-dir", tempDir.path,
      "--executable",
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .failure)
    XCTAssertTrue(validate.stderr.isEmpty)
    let validation = try decodeJSON(WorkflowValidationCommandResult.self, from: validate.stdout)
    XCTAssertFalse(validation.valid)
    XCTAssertEqual(validation.nodeValidationResults.count, 1)
    XCTAssertEqual(validation.nodeValidationResults.first?.nodeId, "addon-node")
    XCTAssertEqual(validation.nodeValidationResults.first?.valid, false)
    XCTAssertTrue(validation.nodeValidationResults.first?.message.contains("require an add-on resolver") == true)

    let run = await RielaCLIApplication().run([
      "workflow", "run", "addon-demo",
      "--workflow-definition-dir", tempDir.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .failure)
    XCTAssertTrue(run.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowRunFailureResult.self, from: run.stdout)
    XCTAssertEqual(failure.target, "addon-demo")
    XCTAssertTrue(failure.error.contains("missing add-on resolver"))
  }

  func testInspectReportsNativeBundleAddonMetadataWithoutPassiveLoading() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-native-bundle-\(UUID().uuidString)", isDirectory: true)
    let workflowDir = tempDir.appendingPathComponent("native-demo", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let contentDigest = "sha256:\(String(repeating: "a", count: 64))"
    let dependencyDigest = "sha256:\(String(repeating: "b", count: 64))"
    let signingDigest = "sha256:\(String(repeating: "c", count: 64))"
    try """
    {
      "workflowId": "native-demo",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "native-step",
      "nodes": [
        { "id": "native-node", "addon": { "name": "native-runner", "version": "1.0.0" } }
      ],
      "steps": [
        { "id": "native-step", "nodeId": "native-node", "role": "worker" }
      ]
    }
    """.write(to: workflowDir.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "name": "native-workflow",
      "version": "1.0.0",
      "kind": "workflow",
      "description": "Native bundle workflow",
      "tags": [],
      "registry": "default",
      "checksum": "abc123",
      "checksumAlgorithm": "md5",
      "dependencies": [{
        "packageId": "native-addon-package",
        "kind": "node-addon",
        "addons": [{
          "name": "native-runner",
          "version": "1.0.0",
          "executionKind": "native-bundle",
          "abiVersion": 1,
          "bundleIdentifier": "com.example.riela.NativeRunner",
          "contentDigest": "\(contentDigest)",
          "dependencyClosureDigest": "\(dependencyDigest)",
          "codeSignatureRequirementDigest": "\(signingDigest)",
          "sourceScope": "project",
          "capabilityGrant": {
            "attachment.read": { "allowed": true, "scope": "attachments/input" }
          }
        }]
      }]
    }
    """.write(to: workflowDir.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let validate = await app.run([
      "workflow", "validate", "native-demo",
      "--workflow-definition-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .success)
    let validation = try decodeJSON(WorkflowValidationCommandResult.self, from: validate.stdout)
    XCTAssertTrue(validation.valid)
    XCTAssertEqual(validation.sourceKind, .package)
    XCTAssertEqual(validation.packageDirectory, workflowDir.path)
    XCTAssertEqual(validation.mutable, false)
    XCTAssertEqual(validation.nodeValidationResults, [])

    let inspect = await app.run([
      "workflow", "inspect", "native-demo",
      "--workflow-definition-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(inspect.exitCode, .success)
    let summary = try decodeJSON(WorkflowInspectionSummary.self, from: inspect.stdout)
    XCTAssertEqual(summary.sourceKind, .package)
    XCTAssertEqual(summary.packageDirectory, workflowDir.path)
    XCTAssertEqual(summary.mutable, false)
    let native = try XCTUnwrap(summary.nativeBundleAddons.first)
    XCTAssertEqual(native.nodeId, "native-node")
    XCTAssertEqual(native.addon, "native-runner")
    XCTAssertEqual(native.sourceKind, "native-bundle")
    XCTAssertEqual(native.sourceScope, "project")
    XCTAssertEqual(native.packageName, "native-addon-package")
    XCTAssertEqual(native.bundleIdentifier, "com.example.riela.NativeRunner")
    XCTAssertEqual(native.abiVersion, 1)
    XCTAssertEqual(native.contentDigest, contentDigest)
    XCTAssertEqual(native.dependencyClosureDigest, dependencyDigest)
    XCTAssertTrue(native.signingRequired)
    XCTAssertNil(native.signingVerified)
    XCTAssertEqual(native.cacheStatus, "not_loaded")
    XCTAssertNil(native.preflightHelperStatus)

    let executable = await app.run([
      "workflow", "validate", "native-demo",
      "--workflow-definition-dir", tempDir.path,
      "--executable",
      "--output", "json"
    ])
    XCTAssertEqual(executable.exitCode, .failure)
    let executableValidation = try decodeJSON(WorkflowValidationCommandResult.self, from: executable.stdout)
    XCTAssertFalse(executableValidation.valid)
    XCTAssertTrue(executableValidation.nodeValidationResults.first?.message.contains("preflight helper unavailable") == true)
  }

  func testValidateJSONFailureReturnsParseableEnvelopeForMissingWorkflow() async throws {
    let result = await RielaCLIApplication().run([
      "workflow", "validate", "definitely-missing-workflow",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowValidationFailureResult.self, from: result.stdout)
    XCTAssertFalse(failure.valid)
    XCTAssertEqual(failure.workflowId, "definitely-missing-workflow")
    XCTAssertEqual(failure.exitCode, CLIExitCode.failure.rawValue)
    XCTAssertTrue(failure.error.contains("notFound"))
  }

  func testValidateJSONFailureReturnsDiagnosticsForInvalidWorkflow() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-invalid-workflow-\(UUID().uuidString)", isDirectory: true)
    let workflowDir = tempDir.appendingPathComponent("broken", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try """
    {
      "workflowId": "broken",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "missing-entry",
      "nodes": [{ "id": "node", "nodeFile": "nodes/node.json" }],
      "steps": [{ "id": "step", "nodeId": "node", "role": "worker" }]
    }
    """.write(to: workflowDir.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)

    let result = await RielaCLIApplication().run([
      "workflow", "validate", "broken",
      "--workflow-definition-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowValidationFailureResult.self, from: result.stdout)
    XCTAssertFalse(failure.valid)
    XCTAssertEqual(failure.workflowId, "broken")
    XCTAssertTrue(failure.error.contains("invalidWorkflow"))
    XCTAssertTrue(failure.diagnostics.contains {
      $0.path == "workflow.entryStepId" && $0.message.contains("missing-entry")
    })
  }

  func testCLIEntryPointsReportInvalidEffectiveNodeSessionPolicy() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-invalid-session-policy-\(UUID().uuidString)", isDirectory: true)
    let workflowDir = tempDir.appendingPathComponent("invalid-session-policy", isDirectory: true)
    let nodesDir = workflowDir.appendingPathComponent("nodes", isDirectory: true)
    try FileManager.default.createDirectory(at: nodesDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try """
    {
      "workflowId": "invalid-session-policy",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "first",
      "nodeRegistry": [{ "id": "worker", "nodeFile": "nodes/worker.json" }],
      "steps": [
        { "id": "first", "nodeId": "worker" },
        { "id": "second", "nodeId": "worker" }
      ],
      "nodes": [{ "id": "worker", "nodeFile": "nodes/worker.json" }]
    }
    """.write(to: workflowDir.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "worker",
      "executionBackend": "codex-agent",
      "model": "model",
      "sessionPolicy": { "mode": "reuse", "inheritFromStepId": "missing" }
    }
    """.write(to: nodesDir.appendingPathComponent("worker.json"), atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let rejectingCommands = [
      ["workflow", "validate", "invalid-session-policy"],
      ["workflow", "run", "invalid-session-policy"]
    ]
    for command in rejectingCommands {
      let result = await app.run(command + [
        "--workflow-definition-dir", tempDir.path,
        "--output", "json"
      ])
      XCTAssertEqual(result.exitCode, .failure, result.stderr + result.stdout)
      XCTAssertTrue(
        (result.stderr + result.stdout).contains("workflow.steps.second.sessionPolicy.inheritFromStepId"),
        result.stderr + result.stdout
      )
    }

    let inspection = await app.run([
      "workflow", "inspect", "invalid-session-policy",
      "--workflow-definition-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(inspection.exitCode, .success, inspection.stderr + inspection.stdout)
    XCTAssertTrue(inspection.stdout.contains("runtimeCapabilityGaps"), inspection.stdout)
    XCTAssertTrue(
      inspection.stdout.contains("workflow.steps.second.sessionPolicy.inheritFromStepId"),
      inspection.stdout
    )
  }

  func testValidateJSONFailureReturnsParseableEnvelopeForMalformedNodePatch() async throws {
    let root = repositoryRoot()
    let result = await RielaCLIApplication().run([
      "workflow", "validate", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--node-patch", #"{"unterminated": true"#,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowValidationFailureResult.self, from: result.stdout)
    XCTAssertFalse(failure.valid)
    XCTAssertEqual(failure.workflowId, "worker-only-single-step")
    XCTAssertFalse(failure.error.isEmpty)
  }

  func testWorkflowCatalogAndManifestCommandsReturnBehaviorOutput() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-catalog-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let workflowsRoot = tempDir.appendingPathComponent(".riela/workflows", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowsRoot, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step"),
      to: workflowsRoot.appendingPathComponent("demo")
    )

    let app = RielaCLIApplication()
    let list = await app.run([
      "workflow", "list",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(list.exitCode, .success)
    XCTAssertTrue(list.stderr.isEmpty)
    let listed = try decodeJSON(WorkflowCatalogResult.self, from: list.stdout)
    XCTAssertEqual(listed.workflows.map(\.workflowName), ["demo"])
    XCTAssertEqual(listed.workflows.first?.scope, .project)
    XCTAssertEqual(listed.workflows.first?.valid, true)

    let status = await app.run([
      "workflow", "status", "demo",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "table"
    ])
    XCTAssertEqual(status.exitCode, .success)
    XCTAssertTrue(status.stderr.isEmpty)
    XCTAssertTrue(status.stdout.contains("WORKFLOW\tSCOPE\tSOURCE\tPROVENANCE\tSTATUS\tDIRECTORY"))
    XCTAssertTrue(status.stdout.contains("demo\tproject\tworkflow\tstandard\tvalid"))

    let manifestURL = tempDir.appendingPathComponent("riela-package.json")
    try """
    {
      "name": "workflow-package",
      "version": "1.0.0",
      "description": "Workflow package",
      "tags": ["sample"],
      "registry": "default",
      "checksum": "abc123",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "missing-workflow"
    }
    """.write(to: manifestURL, atomically: true, encoding: .utf8)
    let manifest = await app.run([
      "workflow", "manifest", "validate", manifestURL.path,
      "--output", "json"
    ])
    XCTAssertEqual(manifest.exitCode, .usage)
    XCTAssertTrue(manifest.stderr.isEmpty)
    let manifestResult = try decodeJSON(WorkflowManifestValidationCommandResult.self, from: manifest.stdout)
    XCTAssertFalse(manifestResult.valid)
    XCTAssertTrue(manifestResult.issues.contains { $0.code == "MISSING_WORKFLOW_BUNDLE" && $0.path == "workflowDirectory" })

    let envManifest = await app.run([
      "workflow", "manifest", "validate",
      "--output", "json"
    ], environment: ["RIELA_WORKFLOW_MANIFEST": manifestURL.path])
    XCTAssertEqual(envManifest.exitCode, .usage)
    XCTAssertTrue(envManifest.stderr.isEmpty)
    let envManifestResult = try decodeJSON(WorkflowManifestValidationCommandResult.self, from: envManifest.stdout)
    XCTAssertEqual(envManifestResult.manifestPath, manifestURL.path)
  }

  func testSessionInspectionCommandsReturnPersistedSessionBehavior() async throws {
    let root = repositoryRoot()
    let sessionStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-sessions-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sessionStore) }

    let run = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .success)
    let runResult = try decodeJSON(WorkflowRunResult.self, from: run.stdout)
    let runtimeRoot = sessionStore.appendingPathComponent("runtime-records", isDirectory: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeRoot
      .appendingPathComponent(runResult.session.sessionId, isDirectory: true)
      .appendingPathComponent("runtime-snapshot.json").path))

    for command in ["status", "progress", "health", "step-runs", "export", "logs"] {
      let result = await RielaCLIApplication().run([
        "session", command, runResult.session.sessionId,
        "--session-store", sessionStore.path,
        "--output", "json"
      ])
      XCTAssertEqual(result.exitCode, .success, command)
      XCTAssertTrue(result.stderr.isEmpty, command)
      let inspection = try decodeJSON(SessionInspectionCommandResult.self, from: result.stdout)
      XCTAssertEqual(inspection.sessionId, runResult.session.sessionId, command)
      XCTAssertEqual(inspection.workflowName, "worker-only-single-step", command)
      XCTAssertEqual(inspection.status, .completed, command)
      XCTAssertEqual(inspection.executionCount, 1, command)
      if command == "health" {
        XCTAssertEqual(inspection.health, "ok")
      }
      if command == "status" || command == "step-runs" || command == "export" {
        XCTAssertEqual(inspection.executions.first?.stepId, "main-worker", command)
      }
    }
    XCTAssertEqual(
      try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot.path)
        .load(sessionId: runResult.session.sessionId)
        .session
        .sessionId,
      runResult.session.sessionId
    )
  }

  func testSessionInspectionFindsUserStoreSessionWhenScopeIsAuto() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-user-session-inspection-\(UUID().uuidString)", isDirectory: true)
    let projectRoot = tempDir.appendingPathComponent("project", isDirectory: true)
    let homeRoot = tempDir.appendingPathComponent("home", isDirectory: true)
    let userSessionStore = homeRoot.appendingPathComponent(".riela/sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let session = WorkflowSession(
      workflowId: "codex-simple-work-package",
      sessionId: "codex-simple-work-package-session-12",
      status: .running,
      entryStepId: "main",
      createdAt: date,
      updatedAt: date
    )
    try CLIWorkflowSessionStore(rootDirectory: userSessionStore.path).save(
      PersistedCLIWorkflowSession(
        workflowName: "codex-simple-work-package",
        session: session,
        resolution: WorkflowResolutionOptions(
          workflowName: "codex-simple-work-package",
          scope: .user,
          workingDirectory: projectRoot.path
        )
      ),
      runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: session)
    )

    let result = await RielaCLIApplication().run([
      "session", "status", session.sessionId,
      "--working-dir", projectRoot.path,
      "--output", "json"
    ], environment: ["HOME": homeRoot.path])

    XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
    let inspection = try decodeJSON(SessionInspectionCommandResult.self, from: result.stdout)
    XCTAssertEqual(inspection.sessionId, session.sessionId)
    XCTAssertEqual(inspection.workflowName, "codex-simple-work-package")
    XCTAssertEqual(inspection.status, .running)
  }

  func testPackageRegistryReadOnlyCommandsDoNotInitializeRegistryConfig() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-registry-readonly-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    let homeRoot = tempDir.appendingPathComponent("home", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: packageSource, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/workflow.json"),
      to: packageSource.appendingPathComponent("workflow.json")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/nodes"),
      to: packageSource.appendingPathComponent("nodes")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/prompts"),
      to: packageSource.appendingPathComponent("prompts")
    )
    let registryConfig = tempDir
      .appendingPathComponent(".riela/workflow-packages", isDirectory: true)
      .appendingPathComponent("registries.json")

    let app = RielaCLIApplication()
    let registryList = await app.run([
      "package", "registry", "list",
      "--working-dir", tempDir.path,
      "--output", "json"
    ], environment: ["HOME": homeRoot.path])
    XCTAssertEqual(registryList.exitCode, .success, registryList.stderr)
    let listedRegistry = try decodeJSON(WorkflowPackageRegistryConfig.self, from: registryList.stdout)
    XCTAssertEqual(listedRegistry.defaultRegistryId, "default")
    XCTAssertEqual(listedRegistry.registries.map(\.id), ["default"])
    XCTAssertEqual(listedRegistry.registries.map(\.url), ["https://github.com/tacogips/riela-packages"])
    XCTAssertEqual(listedRegistry.registries.first?.localPath, homeRoot.appendingPathComponent(".riela/registries/default").path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryConfig.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryConfig.deletingLastPathComponent().path))

    let publishDryRun = await app.run([
      "package", "publish", packageSource.path,
      "--package-name", "dry-run-package",
      "--dry-run",
      "--working-dir", tempDir.path,
      "--output", "json"
    ], environment: ["HOME": homeRoot.path])
    XCTAssertEqual(publishDryRun.exitCode, .success, publishDryRun.stderr)
    let published = try decodeJSON(WorkflowPackageCommandResult.self, from: publishDryRun.stdout)
    XCTAssertEqual(published.dryRun, true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryConfig.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryConfig.deletingLastPathComponent().path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/package-registry").path))
  }

  func testDefaultPackageRegistryUsesRielaPackagesWithoutPersistedConfig() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-default-registry-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    let homeRoot = tempDir.appendingPathComponent("home", isDirectory: true)
    let defaultRegistryRoot = homeRoot.appendingPathComponent(".riela/registries/default", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: packageSource, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/workflow.json"),
      to: packageSource.appendingPathComponent("workflow.json")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/nodes"),
      to: packageSource.appendingPathComponent("nodes")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/prompts"),
      to: packageSource.appendingPathComponent("prompts")
    )

    let app = RielaCLIApplication()
    let publish = await app.run([
      "package", "publish", packageSource.path,
      "--package-name", "default-registry-package",
      "--working-dir", tempDir.path,
      "--yes",
      "--output", "json"
    ], environment: ["HOME": homeRoot.path])

    XCTAssertEqual(publish.exitCode, .success, publish.stderr)
    let publishResult = try decodeJSON(WorkflowPackageCommandResult.self, from: publish.stdout)
    let registryRecord = try decodeJSON(JSONObject.self, from: String(contentsOfFile: try XCTUnwrap(publishResult.destinationDirectory)))
    XCTAssertEqual(registryRecord["registry"]?.stringValue, "default")
    XCTAssertEqual(registryRecord["registryUrl"]?.stringValue, "https://github.com/tacogips/riela-packages")
    XCTAssertEqual(registryRecord["registryRef"]?.stringValue, "main")
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: defaultRegistryRoot.appendingPathComponent("registry/default-registry-package.json").path
    ))
  }

  func testPackagePublishDryRunReportsRequiredLoopReadinessIssues() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-package-loop-readiness-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step"),
      to: packageSource
    )
    try """
    {
      "workflowId": "worker-only-single-step",
      "description": "Required loop workflow missing package readiness declarations.",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "main-worker",
      "loop": { "required": true },
      "nodes": [{ "id": "main-worker", "nodeFile": "nodes/node-main-worker.json" }],
      "steps": [{ "id": "main-worker", "nodeId": "main-worker", "role": "worker" }]
    }
    """.write(to: packageSource.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let missing = await app.run([
      "package", "publish", packageSource.path,
      "--package-name", "loop-readiness-missing",
      "--dry-run",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(missing.exitCode, .success, missing.stderr)
    let missingResult = try decodeJSON(WorkflowPackageCommandResult.self, from: missing.stdout)
    let missingSummary = try XCTUnwrap(missingResult.packages.first)
    XCTAssertFalse(missingSummary.valid)
    XCTAssertTrue(missingSummary.issues.allSatisfy { $0.code == "LOOP_READINESS" })
    XCTAssertTrue(missingSummary.issues.contains { $0.path == "workflow.loop.evidence.required" })
    XCTAssertTrue(missingSummary.issues.contains { $0.path == "workflow.loop.gates" })
    XCTAssertTrue(missingSummary.issues.contains { $0.path == "workflow.loop.policies.mutation" })
    XCTAssertTrue(missingSummary.issues.contains { $0.path == "workflow.loop.policies.process" })

    try """
    {
      "workflowId": "worker-only-single-step",
      "description": "Required loop workflow with package readiness declarations.",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "main-worker",
      "loop": {
        "required": true,
        "evidence": { "required": true, "artifactRootPolicy": "runtime-owned" },
        "policies": {
          "mutation": {
            "allowedWriteRoots": ["Sources", "Tests", "tmp"],
            "scratchRoot": "tmp",
            "commit": "deny",
            "push": "deny"
          },
          "process": {
            "nestedRiela": "deny",
            "nestedCodex": "deny",
            "allowedBackends": ["codex-agent"]
          }
        },
        "implementationPlan": { "required": true, "pathPattern": "impl-plans/active/*.md" },
        "gates": [{ "id": "implementation-review", "stepId": "main-worker", "required": true }]
      },
      "nodes": [{ "id": "main-worker", "nodeFile": "nodes/node-main-worker.json" }],
      "steps": [{ "id": "main-worker", "nodeId": "main-worker", "role": "worker" }]
    }
    """.write(to: packageSource.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)

    let ready = await app.run([
      "package", "publish", packageSource.path,
      "--package-name", "loop-readiness-ready",
      "--dry-run",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(ready.exitCode, .success, ready.stderr)
    let readyResult = try decodeJSON(WorkflowPackageCommandResult.self, from: ready.stdout)
    let readySummary = try XCTUnwrap(readyResult.packages.first)
    XCTAssertTrue(readySummary.valid)
    XCTAssertEqual(readySummary.issues, [])
  }

  func testPackageCommandsUseRielaFixtureRegistryLocalPath() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-fixture-registry-\(UUID().uuidString)", isDirectory: true)
    let fixtureRegistry = tempDir.appendingPathComponent("riela-fixture", isDirectory: true)
    let fixturePackage = fixtureRegistry
      .appendingPathComponent("packages/fixture-clean-workflow", isDirectory: true)
    let fixtureWorkflow = fixturePackage
      .appendingPathComponent("workflows/fixture-clean-workflow", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: fixtureWorkflow.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step"),
      to: fixtureWorkflow
    )
    let fixturePackageChecksum = try packageChecksum(packageRoot: fixturePackage)
    try """
    {
      "name": "fixture-clean-workflow",
      "version": "1.0.0",
      "description": "Safe fixture package used to verify successful package search and checkout.",
      "tags": ["fixture"],
      "workflow": {
        "description": "Safe fixture package used to verify successful package search and checkout.",
        "tags": ["fixture"],
        "backends": ["codex-agent"]
      },
      "registry": "fixture",
      "checksum": "\(fixturePackageChecksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "workflows/fixture-clean-workflow",
      "repository": "https://github.com/tacogips/riela-fixture"
    }
    """.write(to: fixturePackage.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
    let invalidFixturePackage = fixtureRegistry
      .appendingPathComponent("packages/fixture-invalid-metadata-workflow", isDirectory: true)
    try FileManager.default.createDirectory(at: invalidFixturePackage, withIntermediateDirectories: true)
    try """
    {
      "name": "fixture-invalid-metadata-workflow",
      "version": "1.0.0",
      "description": "Invalid fixture package used to verify registry search resilience.",
      "tags": ["fixture"],
      "workflow": {
        "title": 1,
        "description": "Invalid structured workflow metadata.",
        "tags": ["fixture"]
      },
      "registry": "fixture",
      "checksum": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "workflows/fixture-invalid-metadata-workflow",
      "repository": "https://github.com/tacogips/riela-fixture"
    }
    """.write(
      to: invalidFixturePackage.appendingPathComponent("riela-package.json"),
      atomically: true,
      encoding: .utf8
    )

    let app = RielaCLIApplication()
    let directSearch = await app.run([
      "package", "search", "fixture-clean",
      "--registry-url", "https://github.com/tacogips/riela-fixture",
      "--registry-local-path", fixtureRegistry.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(directSearch.exitCode, .success, directSearch.stderr)
    let directSearchResult = try decodeJSON(WorkflowPackageCommandResult.self, from: directSearch.stdout)
    XCTAssertEqual(directSearchResult.packages.map(\.name), ["fixture-clean-workflow"])
    XCTAssertTrue(
      try XCTUnwrap(directSearchResult.packages.first?.packageDirectory)
        .hasSuffix("/riela-fixture/packages/fixture-clean-workflow")
    )
    XCTAssertEqual(directSearchResult.packages.first?.valid, true)

    let invalidSearch = await app.run([
      "package", "search", "fixture-invalid",
      "--registry-url", "https://github.com/tacogips/riela-fixture",
      "--registry-local-path", fixtureRegistry.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(invalidSearch.exitCode, .success, invalidSearch.stderr)
    let invalidSearchResult = try decodeJSON(WorkflowPackageCommandResult.self, from: invalidSearch.stdout)
    XCTAssertEqual(invalidSearchResult.packages.map(\.name), ["fixture-invalid-metadata-workflow"])
    XCTAssertEqual(invalidSearchResult.packages.first?.valid, false)
    XCTAssertEqual(invalidSearchResult.packages.first?.issues.first?.path, "riela-package.json")

    let registryAdd = await app.run([
      "package", "registry", "add", "fixture",
      "--registry-url", "https://github.com/tacogips/riela-fixture",
      "--registry-local-path", fixtureRegistry.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(registryAdd.exitCode, .success, registryAdd.stderr)

    let registeredSearch = await app.run([
      "package", "search", "fixture-clean",
      "--registry", "fixture",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(registeredSearch.exitCode, .success, registeredSearch.stderr)
    let registeredSearchResult = try decodeJSON(WorkflowPackageCommandResult.self, from: registeredSearch.stdout)
    XCTAssertEqual(registeredSearchResult.packages.map(\.name), ["fixture-clean-workflow"])

    let install = await app.run([
      "package", "install", "fixture-clean-workflow",
      "--registry", "fixture",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .success, install.stderr)
    let installed = try decodeJSON(WorkflowPackageCommandResult.self, from: install.stdout)
    let installedPackage = tempDir.appendingPathComponent(".riela/packages/fixture-clean-workflow", isDirectory: true)
    XCTAssertEqual(installed.destinationDirectory, installedPackage.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: installedPackage.appendingPathComponent("riela-package.json").path))

    let packageRun = await app.run([
      "package", "temp-run", "fixture-clean-workflow",
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(packageRun.exitCode, .success, packageRun.stderr)
    let packageRunResult = try decodeJSON(WorkflowPackageCommandResult.self, from: packageRun.stdout)
    XCTAssertEqual(packageRunResult.target, "fixture-clean-workflow")
    XCTAssertNotNil(packageRunResult.runSessionId)
  }

  func testUserPackageInstallProjectsCodexSkillDirectory() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-user-codex-skill-\(UUID().uuidString)", isDirectory: true)
    let homeDir = tempDir.appendingPathComponent("home", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    let workflowDirectory = packageSource.appendingPathComponent("workflows/riela-package-manager-skill", isDirectory: true)
    let codexSkillDirectory = packageSource.appendingPathComponent("skills/codex/riela-package", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: workflowDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codexSkillDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step"),
      to: workflowDirectory
    )
    try """
    # Riela Package

    Install and manage Riela packages.
    """.write(to: codexSkillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let packageSourceChecksum = try packageChecksum(packageRoot: packageSource)
    try """
    {
      "name": "riela-package-manager-skill",
      "version": "1.0.0",
      "description": "Package manager skill fixture.",
      "tags": ["skill", "package"],
      "registry": "fixture",
      "checksum": "\(packageSourceChecksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "workflows/riela-package-manager-skill",
      "skillDirectory": "skills"
    }
    """.write(to: packageSource.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let install = await app.run([
      "package", "install", "riela-package-manager-skill",
      "--source", packageSource.path,
      "--scope", "user",
      "--working-dir", tempDir.path,
      "--output", "json"
    ], environment: ["HOME": homeDir.path])

    XCTAssertEqual(install.exitCode, .success, install.stderr)
    let installed = try decodeJSON(WorkflowPackageCommandResult.self, from: install.stdout)
    let installedPackage = homeDir.appendingPathComponent(".riela/packages/riela-package-manager-skill", isDirectory: true)
    let projectedSkill = homeDir.appendingPathComponent(".codex/skills/riela-package/SKILL.md")
    XCTAssertEqual(installed.destinationDirectory, installedPackage.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: installedPackage.appendingPathComponent("riela-package.json").path))
    XCTAssertEqual(try String(contentsOf: projectedSkill), "# Riela Package\n\nInstall and manage Riela packages.")
  }

  func testWorkflowRunFromRegistryRejectsEscapingWorkflowDirectory() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-registry-run-escape-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let packageDirectory = tempDir
      .appendingPathComponent(".riela/packages/escape-package", isDirectory: true)
    try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
    let app = RielaCLIApplication()

    for workflowDirectory in ["/tmp/outside-workflow", "../outside-workflow"] {
      try """
      {
        "name": "escape-package",
        "version": "1.0.0",
        "description": "Escape package",
        "tags": ["demo"],
        "registry": "local",
        "checksum": "cccccccccccccccccccccccccccccccc",
        "checksumAlgorithm": "md5",
        "workflowDirectory": "\(workflowDirectory)"
      }
      """.write(to: packageDirectory.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

      let result = await app.run([
        "workflow", "run", "escape-package",
        "--from-registry",
        "--working-dir", tempDir.path,
        "--output", "json"
      ])
      XCTAssertEqual(result.exitCode, .usage, workflowDirectory)
      XCTAssertTrue(result.stderr.isEmpty)
      let failure = try decodeJSON(WorkflowRunFailureResult.self, from: result.stdout)
      XCTAssertTrue(failure.error.contains("workflowDirectory: path must be package-relative"), failure.error)
    }
  }
}
