#if os(macOS)
import Foundation
import RielaAddons
import RielaCore
import XCTest
@testable import RielaAppSupport
@testable import RielaCLI

extension WorkflowCommandTests {
  func testPackageAppEnvironmentEnablementRunAndMonitoringScenario() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-package-app-scenario-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    let archive = tempDir.appendingPathComponent("scenario-chatgpt-package.rielapkg")
    let appRoot = tempDir.appendingPathComponent("app-root", isDirectory: true)
    let homeRoot = tempDir.appendingPathComponent("home", isDirectory: true)
    let profileName = RielaAppProfileName("scenario-profile")
    let appPackageRoot = RielaAppProfileStore.packageRootURL(appRootURL: appRoot, profileName: profileName)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try writeScenarioPackageWorkflow(at: packageSource)

    let app = RielaCLIApplication()
    let initialize = await app.run([
      "package", "init", packageSource.path,
      "--package-name", "scenario-chatgpt-package",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(initialize.exitCode, .success, initialize.stderr)
    let initialized = try decodeJSON(WorkflowPackageCommandResult.self, from: initialize.stdout)
    XCTAssertEqual(initialized.packages.first?.name, "scenario-chatgpt-package")
    XCTAssertEqual(initialized.packages.first?.workflowDirectory, ".")

    try writeScenarioPackageManifest(at: packageSource)
    let sourceValidation = await app.run([
      "package", "validate", packageSource.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(sourceValidation.exitCode, .success, sourceValidation.stderr + sourceValidation.stdout)
    let validatedSource = try decodeJSON(WorkflowPackageCommandResult.self, from: sourceValidation.stdout)
    XCTAssertEqual(validatedSource.message, "package validation passed")
    XCTAssertEqual(validatedSource.packages.first?.valid, true)

    let pack = await app.run([
      "package", "pack", packageSource.path,
      "--destination", archive.path,
      "--overwrite",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(pack.exitCode, .success, pack.stderr)
    let packed = try decodeJSON(WorkflowPackageCommandResult.self, from: pack.stdout)
    XCTAssertEqual(packed.destinationDirectory, archive.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

    let archiveValidation = await app.run([
      "package", "validate", archive.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(archiveValidation.exitCode, .success, archiveValidation.stderr + archiveValidation.stdout)
    let validatedArchive = try decodeJSON(WorkflowPackageCommandResult.self, from: archiveValidation.stdout)
    XCTAssertEqual(validatedArchive.packages.first?.name, "scenario-chatgpt-package")
    XCTAssertEqual(validatedArchive.packages.first?.valid, true)

    let install = await app.run([
      "package", "install", "scenario-chatgpt-package",
      "--source", archive.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .success, install.stderr)
    let installed = try decodeJSON(WorkflowPackageCommandResult.self, from: install.stdout)
    XCTAssertEqual(
      installed.destinationDirectory,
      tempDir.appendingPathComponent(".riela/packages/scenario-chatgpt-package", isDirectory: true).path
    )

    let workflowValidation = await app.run([
      "workflow", "validate", "scenario-chatgpt-package",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(workflowValidation.exitCode, .success, workflowValidation.stderr + workflowValidation.stdout)
    let validatedWorkflow = try decodeJSON(WorkflowValidationCommandResult.self, from: workflowValidation.stdout)
    XCTAssertEqual(validatedWorkflow.workflowId, "scenario-chatgpt-workflow")
    XCTAssertEqual(validatedWorkflow.sourceKind, .package)
    XCTAssertEqual(validatedWorkflow.packageName, "scenario-chatgpt-package")

    let appInstall = try RielaAppManagedPackageInstaller(packageRoot: appPackageRoot).installPackageSourceResult(archive)
    XCTAssertFalse(appInstall.replacedExisting)
    let importSummary = RielaAppImportSummary(
      importedNames: ["scenario-chatgpt-package"],
      failures: [],
      profileName: profileName,
      startsImmediately: false,
      autostartOffNames: ["scenario-chatgpt-package"]
    )
    XCTAssertEqual(
      importSummary.statusMessage,
      "Imported scenario-chatgpt-package into profile scenario-profile with auto-start off"
    )
    let discovery = RielaAppDaemonWorkflowDiscovery(homeDirectory: homeRoot)
    let candidate = try XCTUnwrap(discovery.discoverUserDaemonWorkflows(appPackageRoot: appPackageRoot).first)
    XCTAssertEqual(candidate.workflowId, "scenario-chatgpt-workflow")
    XCTAssertEqual(candidate.sourceScope, .profile)
    XCTAssertEqual(
      candidate.packageDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
      appInstall.installedURL.resolvingSymlinksInPath().path
    )
    XCTAssertEqual(candidate.requiredEnvironment, [
      RielaAppEnvRequirement(
        name: "RIELA_SCENARIO_OPENAI_API_KEY",
        description: "OpenAI API key for live scenario fallback",
        secret: true
      )
    ])

    let envNames = candidate.requiredEnvironment.map(\.name)
    XCTAssertEqual(
      RielaAppEnvironmentFileStore(processEnvironment: [:]).statuses(for: envNames),
      [RielaAppEnvironmentVariableStatus(name: "RIELA_SCENARIO_OPENAI_API_KEY", configured: false)]
    )
    let envFile = tempDir.appendingPathComponent("scenario.env")
    try "RIELA_SCENARIO_OPENAI_API_KEY=present-for-test\n"
      .write(to: envFile, atomically: true, encoding: .utf8)
    XCTAssertEqual(
      RielaAppEnvironmentFileStore(environmentFileURL: envFile, processEnvironment: [:]).statuses(for: envNames),
      [RielaAppEnvironmentVariableStatus(name: "RIELA_SCENARIO_OPENAI_API_KEY", configured: true)]
    )

    let disabledPreference = RielaAppImportPreferencePolicy.preference(
      identity: candidate.id,
      existingPreference: RielaAppDaemonWorkflowPreference(identity: candidate.id, available: true, active: false),
      replacedExisting: true,
      startsImmediately: true
    )
    XCTAssertEqual(disabledPreference.available, true)
    XCTAssertEqual(disabledPreference.active, false)
    XCTAssertFalse(RielaAppImportPreferencePolicy.shouldStartAfterImport(
      preference: disabledPreference,
      startsImportedCandidates: true
    ))
    let enabledPreference = RielaAppDaemonWorkflowPreference(identity: candidate.id, available: true, active: true)
    XCTAssertTrue(RielaAppImportPreferencePolicy.shouldStartAfterImport(
      preference: enabledPreference,
      startsImportedCandidates: true
    ))

    let previousScenarioAPIKey = environmentValue("RIELA_SCENARIO_OPENAI_API_KEY")
    setEnvironmentValue("RIELA_SCENARIO_OPENAI_API_KEY", nil)
    let missingEnvRun = await app.run([
      "workflow", "run", "scenario-chatgpt-package",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--mock-scenario", packageSource.appendingPathComponent("mock-scenario.json").path,
      "--output", "json"
    ])
    XCTAssertEqual(missingEnvRun.exitCode, .failure, missingEnvRun.stdout)
    let missingEnvFailure = try decodeJSON(WorkflowRunFailureResult.self, from: missingEnvRun.stdout)
    XCTAssertEqual(missingEnvFailure.target, "scenario-chatgpt-package")
    XCTAssertTrue(missingEnvFailure.error.contains("RIELA_SCENARIO_OPENAI_API_KEY"))
    XCTAssertFalse(missingEnvFailure.error.contains("present-for-deterministic-run"))

    setEnvironmentValue("RIELA_SCENARIO_OPENAI_API_KEY", "present-for-deterministic-run")
    defer { setEnvironmentValue("RIELA_SCENARIO_OPENAI_API_KEY", previousScenarioAPIKey) }
    let run = await app.run([
      "workflow", "run", "scenario-chatgpt-package",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--mock-scenario", packageSource.appendingPathComponent("mock-scenario.json").path,
      "--variables", #"{"workflowInput":{"request":"deterministic scenario acceptance"}}"#,
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .success, run.stderr + run.stdout)
    let runResult = try decodeJSON(WorkflowRunResult.self, from: run.stdout)
    XCTAssertEqual(runResult.workflowId, "scenario-chatgpt-workflow")
    XCTAssertEqual(runResult.status, .completed)
    XCTAssertEqual(runResult.nodeExecutions, 1)
    XCTAssertEqual(runResult.transitions, 0)
    XCTAssertEqual(runResult.session.executions.map(\.stepId), ["main"])
    XCTAssertEqual(runResult.rootOutput?["verdict"], .string("accepted"))
    XCTAssertEqual(runResult.rootOutput?["modelBudget"], .string("cheap-chatgpt-mock"))

    let progress = await app.run([
      "session", "progress", runResult.session.sessionId,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(progress.exitCode, .success, progress.stderr + progress.stdout)
    let progressResult = try decodeJSON(SessionInspectionCommandResult.self, from: progress.stdout)
    XCTAssertEqual(progressResult.sessionId, runResult.session.sessionId)
    XCTAssertEqual(progressResult.workflowName, "scenario-chatgpt-workflow")
    XCTAssertEqual(progressResult.status, .completed)
    XCTAssertEqual(progressResult.executionCount, 1)
    XCTAssertEqual(progressResult.executions, [])
  }

  private func writeScenarioPackageWorkflow(at packageSource: URL) throws {
    try FileManager.default.createDirectory(
      at: packageSource.appendingPathComponent("nodes", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    {
      "workflowId": "scenario-chatgpt-workflow",
      "description": "Deterministic package/App scenario workflow with cheap ChatGPT live fallback metadata.",
      "defaults": { "maxLoopIterations": 1, "nodeTimeoutMs": 120000 },
      "entryStepId": "main",
      "nodes": [
        { "id": "main", "nodeFile": "nodes/node-main.json" }
      ],
      "steps": [
        { "id": "main", "nodeId": "main", "role": "worker" }
      ]
    }
    """.write(to: packageSource.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "main",
      "description": "Uses the cheap ChatGPT model for live runs; deterministic tests use mock-scenario.json.",
      "executionBackend": "official/openai-sdk",
      "model": "gpt-5-mini",
      "agentEnvironment": {
        "OPENAI_API_KEY": {
          "fromEnv": "RIELA_SCENARIO_OPENAI_API_KEY",
          "required": true
        }
      },
      "promptTemplate": "Return compact JSON confirming the Riela package/App scenario acceptance.",
      "variables": {}
    }
    """.write(to: packageSource.appendingPathComponent("nodes/node-main.json"), atomically: true, encoding: .utf8)
    try """
    {
      "main": {
        "provider": "scenario-mock",
        "model": "gpt-5-mini",
        "when": { "always": true },
        "payload": {
          "verdict": "accepted",
          "modelBudget": "cheap-chatgpt-mock",
          "checks": [
            "package-init",
            "package-validate",
            "package-pack",
            "app-env-readiness",
            "workflow-run-monitoring"
          ]
        }
      }
    }
    """.write(to: packageSource.appendingPathComponent("mock-scenario.json"), atomically: true, encoding: .utf8)
  }

  private func writeScenarioPackageManifest(at packageSource: URL) throws {
    let checksum = try WorkflowPackageChecksum.md5(packageRoot: packageSource)
    try """
    {
      "kind": "workflow",
      "name": "scenario-chatgpt-package",
      "version": "1.0.0",
      "description": "Scenario package covering riela command and RielaApp package workflow use.",
      "tags": ["scenario", "app", "package"],
      "registry": "local",
      "checksum": "\(checksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": ".",
      "environmentVariables": [
        {
          "name": "RIELA_SCENARIO_OPENAI_API_KEY",
          "description": "OpenAI API key for live scenario fallback",
          "required": true,
          "secret": true
        }
      ]
    }
    """.write(to: packageSource.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
  }
}
#endif
