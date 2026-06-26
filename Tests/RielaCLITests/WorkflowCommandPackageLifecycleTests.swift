import Foundation
import RielaAdapters
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

extension WorkflowCommandTests {
  // This parity test intentionally exercises a long command sequence with shared state.
  // swiftlint:disable:next function_body_length
  func testWorkflowCreateCheckoutPackageSessionContinueAndScopedParityCommands() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-parity-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: packageSource, withIntermediateDirectories: true)

    let app = RielaCLIApplication()
    let create = await app.run([
      "workflow", "create", "created-flow",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(create.exitCode, .success, create.stderr)
    let created = try decodeJSON(WorkflowCreateCommandResult.self, from: create.stdout)
    XCTAssertEqual(created.workflowName, "created-flow")
    XCTAssertTrue(FileManager.default.fileExists(atPath: "\(created.workflowDirectory)/workflow.json"))
    let checkoutCache = tempDir
      .appendingPathComponent(".riela/workflow-checkout-sources/github-example-workflows-main-copied-flow", isDirectory: true)
      .appendingPathComponent("copied-flow", isDirectory: true)
    try FileManager.default.createDirectory(at: checkoutCache.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: created.workflowDirectory), to: checkoutCache)

    let checkout = await app.run([
      "workflow", "checkout", "https://github.com/example/workflows/tree/main/copied-flow",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(checkout.exitCode, .success, checkout.stderr)
    let checkedOut = try decodeJSON(WorkflowCheckoutCommandResult.self, from: checkout.stdout)
    XCTAssertEqual(checkedOut.workflowName, "copied-flow")
    XCTAssertTrue(FileManager.default.fileExists(atPath: "\(checkedOut.destinationDirectory)/workflow.json"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/workflow-checkouts/copied-flow.json").path))

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
    try """
    {
      "name": "demo-package",
      "version": "1.0.0",
      "description": "Demo package",
      "tags": ["demo"],
      "registry": "local",
      "checksum": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: packageSource.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let install = await app.run([
      "package", "install", "demo-package",
      "--source", packageSource.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .success, install.stderr)
    let installed = try decodeJSON(WorkflowPackageCommandResult.self, from: install.stdout)
    XCTAssertEqual(installed.destinationDirectory, tempDir.appendingPathComponent(".riela/packages/demo-package").path)

    let list = await app.run([
      "workflow", "package", "list",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(list.exitCode, .success, list.stderr)
    let listed = try decodeJSON(WorkflowPackageCommandResult.self, from: list.stdout)
    XCTAssertEqual(listed.packages.map(\.name), ["demo-package"])
    XCTAssertEqual(listed.packages.first?.valid, true)

    let workflowList = await app.run([
      "workflow", "list",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(workflowList.exitCode, .success, workflowList.stderr)
    let listedWorkflows = try decodeJSON(WorkflowCatalogResult.self, from: workflowList.stdout)
    let packageCatalogEntry = try XCTUnwrap(listedWorkflows.workflows.first { $0.workflowName == "demo-package" })
    XCTAssertEqual(packageCatalogEntry.sourceKind, .package)
    XCTAssertEqual(packageCatalogEntry.packageName, "demo-package")
    XCTAssertEqual(packageCatalogEntry.mutable, false)
    XCTAssertEqual(packageCatalogEntry.valid, true)

    let packageValidate = await app.run([
      "workflow", "validate", "demo-package",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(packageValidate.exitCode, .success, packageValidate.stderr)
    let packageValidation = try decodeJSON(WorkflowValidationCommandResult.self, from: packageValidate.stdout)
    XCTAssertEqual(packageValidation.workflowId, "worker-only-single-step")
    XCTAssertEqual(packageValidation.sourceKind, .package)
    XCTAssertEqual(packageValidation.packageName, "demo-package")
    XCTAssertEqual(packageValidation.mutable, false)

    let packageInspect = await app.run([
      "workflow", "inspect", "demo-package",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(packageInspect.exitCode, .success, packageInspect.stderr)
    let workflowPackageInspection = try decodeJSON(WorkflowInspectionSummary.self, from: packageInspect.stdout)
    XCTAssertEqual(workflowPackageInspection.workflowId, "worker-only-single-step")
    XCTAssertEqual(workflowPackageInspection.sourceKind, .package)
    XCTAssertEqual(workflowPackageInspection.packageName, "demo-package")
    XCTAssertEqual(workflowPackageInspection.mutable, false)

    let packageWorkflowRun = await app.run([
      "workflow", "run", "demo-package",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(packageWorkflowRun.exitCode, .success, packageWorkflowRun.stderr)
    let packageWorkflowRunResult = try decodeJSON(WorkflowRunResult.self, from: packageWorkflowRun.stdout)
    XCTAssertEqual(packageWorkflowRunResult.workflowId, "worker-only-single-step")
    XCTAssertEqual(packageWorkflowRunResult.status, .completed)

    let registryAdd = await app.run([
      "package", "registry", "add", "local",
      "--registry-url", "https://github.com/example/registry",
      "--registry-local-path", tempDir.appendingPathComponent("local-registry").path,
      "--branch", "main",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(registryAdd.exitCode, .success, registryAdd.stderr)
    let addedRegistry = try decodeJSON(WorkflowPackageRegistryConfig.self, from: registryAdd.stdout)
    XCTAssertEqual(addedRegistry.defaultRegistryId, "default")
    XCTAssertEqual(addedRegistry.registries.map(\.id), ["local", "default"])

    let registryList = await app.run([
      "workflow", "package", "registry", "list",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(registryList.exitCode, .success, registryList.stderr)
    let listedRegistry = try decodeJSON(WorkflowPackageRegistryConfig.self, from: registryList.stdout)
    XCTAssertEqual(listedRegistry.registries.map(\.url), [
      "https://github.com/example/registry",
      "https://github.com/tacogips/riela-packages"
    ])

    let publish = await app.run([
      "workflow", "package", "publish", packageSource.path,
      "--package-name", "demo-package",
      "--dry-run",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(publish.exitCode, .success, publish.stderr)
    let published = try decodeJSON(WorkflowPackageCommandResult.self, from: publish.stdout)
    XCTAssertEqual(published.dryRun, true)

    let publishWrite = await app.run([
      "workflow", "package", "publish", packageSource.path,
      "--package-id", "demo-package",
      "--registry", "local",
      "--registry-local-path", tempDir.appendingPathComponent("local-registry").path,
      "--working-dir", tempDir.path,
      "--yes",
      "--output", "json"
    ])
    XCTAssertEqual(publishWrite.exitCode, .success, publishWrite.stderr)
    let publishWriteResult = try decodeJSON(WorkflowPackageCommandResult.self, from: publishWrite.stdout)
    XCTAssertEqual(publishWriteResult.dryRun, false)
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(publishWriteResult.destinationDirectory)))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/package-cache/demo-package.json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/package-locks/demo-package.json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/skills/demo-package/SKILL.md").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/package-native-addons/demo-package.json").path))

    let explicitRegistryRoot = tempDir.appendingPathComponent("explicit-url-registry", isDirectory: true)
    let explicitRegistryPublish = await app.run([
      "package", "publish", packageSource.path,
      "--package-name", "demo-package-url",
      "--registry", "https://github.com/acme/packages",
      "--registry-local-path", explicitRegistryRoot.path,
      "--branch", "release",
      "--working-dir", tempDir.path,
      "--yes",
      "--output", "json"
    ])
    XCTAssertEqual(explicitRegistryPublish.exitCode, .success, explicitRegistryPublish.stderr)
    let explicitRegistryResult = try decodeJSON(WorkflowPackageCommandResult.self, from: explicitRegistryPublish.stdout)
    let explicitRegistryRecordPath = try XCTUnwrap(explicitRegistryResult.destinationDirectory)
    let explicitRegistryRecord = try decodeJSON(JSONObject.self, from: String(contentsOfFile: explicitRegistryRecordPath))
    XCTAssertEqual(explicitRegistryRecord["registry"]?.stringValue, "github-acme-packages")
    XCTAssertEqual(explicitRegistryRecord["registryUrl"]?.stringValue, "https://github.com/acme/packages")
    XCTAssertEqual(explicitRegistryRecord["registryRef"]?.stringValue, "release")
    XCTAssertTrue(FileManager.default.fileExists(atPath: explicitRegistryRoot.appendingPathComponent("registry/demo-package-url.json").path))

    let registryURLPrecedencePublish = await app.run([
      "package", "publish", packageSource.path,
      "--package-name", "demo-package-url-precedence",
      "--registry", "local",
      "--registry-url", "https://github.com/override/packages",
      "--working-dir", tempDir.path,
      "--yes",
      "--output", "json"
    ])
    XCTAssertEqual(registryURLPrecedencePublish.exitCode, .success, registryURLPrecedencePublish.stderr)
    let registryURLPrecedenceResult = try decodeJSON(WorkflowPackageCommandResult.self, from: registryURLPrecedencePublish.stdout)
    let registryURLPrecedenceRecord = try decodeJSON(JSONObject.self, from: String(contentsOfFile: try XCTUnwrap(registryURLPrecedenceResult.destinationDirectory)))
    XCTAssertEqual(registryURLPrecedenceRecord["registry"]?.stringValue, "local")
    XCTAssertEqual(registryURLPrecedenceRecord["registryUrl"]?.stringValue, "https://github.com/override/packages")

    let runtimeRecordsRoot = tempDir.appendingPathComponent(".riela/sessions/runtime-records", isDirectory: true)
    let runtimeRecordCountBeforeDryRun = (try? FileManager.default.contentsOfDirectory(
      at: runtimeRecordsRoot,
      includingPropertiesForKeys: [.isDirectoryKey]
    ).count) ?? 0
    for command in ["run", "temp-run"] {
      let dryRun = await app.run([
        "package", command, "demo-package",
        "--dry-run",
        "--working-dir", tempDir.path,
        "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
        "--output", "json"
      ])
      XCTAssertEqual(dryRun.exitCode, .success, "\(command): \(dryRun.stderr) \(dryRun.stdout)")
      let dryRunResult = try decodeJSON(WorkflowPackageCommandResult.self, from: dryRun.stdout)
      XCTAssertEqual(dryRunResult.dryRun, true)
      XCTAssertNil(dryRunResult.runSessionId)
      let runtimeRecordCountAfterDryRun = (try? FileManager.default.contentsOfDirectory(
        at: runtimeRecordsRoot,
        includingPropertiesForKeys: [.isDirectoryKey]
      ).count) ?? 0
      XCTAssertEqual(runtimeRecordCountAfterDryRun, runtimeRecordCountBeforeDryRun)
    }

    let scopedPackageSource = tempDir.appendingPathComponent("scoped-package-source", isDirectory: true)
    try FileManager.default.copyItem(at: packageSource, to: scopedPackageSource)
    try """
    {
      "name": "@scope/scoped-flow",
      "version": "1.0.0",
      "description": "Scoped demo package",
      "tags": ["demo"],
      "registry": "local",
      "checksum": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: scopedPackageSource.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
    let scopedInstall = await app.run([
      "package", "install", "@scope/scoped-flow",
      "--source", scopedPackageSource.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(scopedInstall.exitCode, .success, scopedInstall.stderr)

    let scopedPackageValidate = await app.run([
      "workflow", "validate", "@scope/scoped-flow",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(scopedPackageValidate.exitCode, .success, scopedPackageValidate.stderr)
    let scopedPackageValidation = try decodeJSON(WorkflowValidationCommandResult.self, from: scopedPackageValidate.stdout)
    XCTAssertEqual(scopedPackageValidation.sourceKind, .package)
    XCTAssertEqual(scopedPackageValidation.packageName, "@scope/scoped-flow")

    let scopedRegistryRun = await app.run([
      "workflow", "run", "@scope/scoped-flow",
      "--from-registry",
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(scopedRegistryRun.exitCode, .success, scopedRegistryRun.stderr)
    let scopedRegistryRunResult = try decodeJSON(WorkflowRunResult.self, from: scopedRegistryRun.stdout)
    XCTAssertEqual(scopedRegistryRunResult.workflowId, "worker-only-single-step")
    XCTAssertEqual(scopedRegistryRunResult.status, .completed)

    let registryRun = await app.run([
      "workflow", "run", "demo-package",
      "--from-registry",
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(registryRun.exitCode, .success, registryRun.stderr)
    let registryRunResult = try decodeJSON(WorkflowRunResult.self, from: registryRun.stdout)
    XCTAssertEqual(registryRunResult.workflowId, "worker-only-single-step")
    XCTAssertEqual(registryRunResult.status, .completed)
    let registryRunSessionId = registryRunResult.session.sessionId

    let registryResume = await app.run([
      "session", "resume", registryRunSessionId,
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(registryResume.exitCode, .success, registryResume.stderr)
    let registryResumeResult = try decodeJSON(SessionResumeCommandResult.self, from: registryResume.stdout)
    XCTAssertEqual(registryResumeResult.sessionId, registryRunSessionId)

    let registryContinue = await app.run([
      "session", "continue", registryRunSessionId,
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(registryContinue.exitCode, .success, registryContinue.stderr)
    let registryContinueResult = try decodeJSON(SessionResumeCommandResult.self, from: registryContinue.stdout)
    XCTAssertEqual(registryContinueResult.sessionId, registryRunSessionId)

    let registryRerun = await app.run([
      "session", "rerun", registryRunSessionId, "main-worker",
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(registryRerun.exitCode, .success, registryRerun.stderr)
    let registryRerunResult = try decodeJSON(SessionRerunCommandResult.self, from: registryRerun.stdout)
    XCTAssertEqual(registryRerunResult.sourceSessionId, registryRunSessionId)
    XCTAssertEqual(registryRerunResult.rerunFromStepId, "main-worker")

    let packageRun = await app.run([
      "package", "temp-run", "demo-package",
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(packageRun.exitCode, .success, packageRun.stderr)
    let packageRunResult = try decodeJSON(WorkflowPackageCommandResult.self, from: packageRun.stdout)
    let packageRunSessionId = try XCTUnwrap(packageRunResult.runSessionId)
    let packageRuntimeStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: tempDir
      .appendingPathComponent(".riela/sessions/runtime-records", isDirectory: true)
      .path)
    XCTAssertEqual(try packageRuntimeStore.load(sessionId: packageRunSessionId).session.sessionId, packageRunSessionId)
    let secondPackageRun = await app.run([
      "package", "temp-run", "demo-package",
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(secondPackageRun.exitCode, .success, secondPackageRun.stderr)
    let secondPackageRunResult = try decodeJSON(WorkflowPackageCommandResult.self, from: secondPackageRun.stdout)
    let secondPackageRunSessionId = try XCTUnwrap(secondPackageRunResult.runSessionId)
    XCTAssertNotEqual(secondPackageRunSessionId, packageRunSessionId)
    for sessionId in [packageRunSessionId, secondPackageRunSessionId] {
      XCTAssertEqual(try packageRuntimeStore.load(sessionId: sessionId).session.sessionId, sessionId)
    }
    let packageRunStatus = await app.run([
      "session", "status", packageRunSessionId,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(packageRunStatus.exitCode, .success, packageRunStatus.stderr)
    let packageInspection = try decodeJSON(SessionInspectionCommandResult.self, from: packageRunStatus.stdout)
    XCTAssertEqual(packageInspection.status, .completed)

    let selfImprove = await app.run([
      "workflow", "self-improve", "created-flow",
      "--working-dir", tempDir.path,
      "--yes",
      "--output", "json"
    ])
    XCTAssertEqual(selfImprove.exitCode, .success, selfImprove.stderr)
    let selfImproveResult = try decodeJSON(WorkflowSelfImproveCommandResult.self, from: selfImprove.stdout)
    XCTAssertEqual(selfImproveResult.workflowName, "created-flow")
    XCTAssertEqual(selfImproveResult.dryRun, false)
    XCTAssertEqual(selfImproveResult.mutated, true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: "\(created.workflowDirectory)/.riela-self-improve-patch.json"))
    XCTAssertTrue(try String(contentsOfFile: "\(created.workflowDirectory)/workflow.json").contains("self-improve-reviewed"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(selfImproveResult.backupDirectory)))
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(selfImproveResult.reportPath)))

    let autoImprove = await app.run([
      "workflow", "run", "supervised-mock-retry",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/supervised-mock-retry/mock-scenario.json",
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--auto-improve",
      "--max-supervised-attempts", "3",
      "--monitor-interval-ms", "1000",
      "--stall-timeout-ms", "2000",
      "--workflow-mutation-mode", "execution-copy",
      "--output", "json"
    ])
    XCTAssertEqual(autoImprove.exitCode, .success, autoImprove.stderr)
    let autoImproveResult = try decodeJSON(WorkflowRunResult.self, from: autoImprove.stdout)
    XCTAssertEqual(autoImproveResult.status, .completed)
    XCTAssertEqual(autoImproveResult.rootOutput?["status"], .string("ready"))
    let supervision = try XCTUnwrap(autoImproveResult.supervision)
    XCTAssertEqual(supervision["status"], .string("succeeded"))
    XCTAssertEqual(supervision["attempts"], .number(2))
    guard case let .object(policy)? = supervision["policy"] else {
      return XCTFail("expected supervision policy")
    }
    XCTAssertEqual(policy["maxSupervisedAttempts"], .number(3))
    XCTAssertEqual(policy["monitorIntervalMs"], .number(1000))
    XCTAssertEqual(policy["stallTimeoutMs"], .number(2000))
    XCTAssertEqual(policy["stallDetectionEnabled"], .bool(true))
    XCTAssertEqual(policy["workflowMutationMode"], .string("execution-copy"))
    guard case let .array(incidents)? = supervision["incidents"] else {
      return XCTFail("expected supervision incidents")
    }
    XCTAssertEqual(incidents.count, 1)
    guard case let .object(incident)? = incidents.first else {
      return XCTFail("expected failure incident object")
    }
    XCTAssertEqual(incident["category"], .string("failure"))
    XCTAssertEqual(incident["stepId"], .string("main-worker"))
    guard case let .array(remediations)? = supervision["remediations"] else {
      return XCTFail("expected supervision remediations")
    }
    XCTAssertEqual(remediations.count, 1)
    guard case let .object(remediation)? = remediations.first else {
      return XCTFail("expected rerun remediation object")
    }
    XCTAssertEqual(remediation["action"], .string("rerun-workflow"))
    XCTAssertEqual(remediation["managerControl"], .string("session rerun"))
    XCTAssertEqual(remediation["targetSessionId"], .string(autoImproveResult.session.sessionId))
    XCTAssertNotEqual(remediation["sourceSessionId"], remediation["targetSessionId"])
    let supervisionRecord = tempDir
      .appendingPathComponent("sessions/runtime-records", isDirectory: true)
      .appendingPathComponent(autoImproveResult.session.sessionId, isDirectory: true)
      .appendingPathComponent("supervision-record.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: supervisionRecord.path))
    let persistedSupervision = try decodeJSON(
      JSONObject.self,
      from: String(contentsOf: supervisionRecord, encoding: .utf8)
    )
    XCTAssertEqual(persistedSupervision["status"], .string("succeeded"))
    XCTAssertEqual(persistedSupervision["targetSessionId"], .string(autoImproveResult.session.sessionId))
    XCTAssertEqual(persistedSupervision["attempts"], .number(2))

    let run = await app.run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .success, run.stderr)
    let runResult = try decodeJSON(WorkflowRunResult.self, from: run.stdout)
    let runtimeRecordRoot = tempDir
      .appendingPathComponent("sessions/runtime-records", isDirectory: true)
      .appendingPathComponent(runResult.session.sessionId, isDirectory: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeRecordRoot.appendingPathComponent("supervision-record.json").path))
    let secondRun = await app.run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--output", "json"
    ])
    XCTAssertEqual(secondRun.exitCode, .success, secondRun.stderr)
    let secondRunResult = try decodeJSON(WorkflowRunResult.self, from: secondRun.stdout)
    XCTAssertNotEqual(secondRunResult.session.sessionId, runResult.session.sessionId)
    let normalRuntimeStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: tempDir
      .appendingPathComponent("sessions/runtime-records", isDirectory: true)
      .path)
    for sessionId in [runResult.session.sessionId, secondRunResult.session.sessionId] {
      XCTAssertEqual(try normalRuntimeStore.load(sessionId: sessionId).session.sessionId, sessionId)
    }
    let transitionWorkflowRoot = tempDir.appendingPathComponent("transition-workflows", isDirectory: true)
    let transitionWorkflow = try writeTwoStepWorkflow(at: transitionWorkflowRoot, workflowName: "two-step")
    let transitionSessionStore = tempDir.appendingPathComponent("transition-sessions", isDirectory: true)
    let transitionRun = await app.run([
      "workflow", "run", "two-step",
      "--workflow-definition-dir", transitionWorkflowRoot.path,
      "--mock-scenario", transitionWorkflow.scenarioPath,
      "--session-store", transitionSessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(transitionRun.exitCode, .success, transitionRun.stderr)
    let transitionRunResult = try decodeJSON(WorkflowRunResult.self, from: transitionRun.stdout)
    let secondTransitionRun = await app.run([
      "workflow", "run", "two-step",
      "--workflow-definition-dir", transitionWorkflowRoot.path,
      "--mock-scenario", transitionWorkflow.scenarioPath,
      "--session-store", transitionSessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(secondTransitionRun.exitCode, .success, secondTransitionRun.stderr)
    let secondTransitionRunResult = try decodeJSON(WorkflowRunResult.self, from: secondTransitionRun.stdout)
    let transitionPersistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: transitionSessionStore.path))
    let transitionCommunicationIds = try transitionPersistence
      .load(sessionId: transitionRunResult.session.sessionId)
      .workflowMessages
      .map(\.communicationId)
    let secondTransitionCommunicationIds = try transitionPersistence
      .load(sessionId: secondTransitionRunResult.session.sessionId)
      .workflowMessages
      .map(\.communicationId)
    XCTAssertEqual(transitionCommunicationIds, ["comm-000001"])
    XCTAssertEqual(secondTransitionCommunicationIds, ["comm-000002"])
    for communicationId in transitionCommunicationIds + secondTransitionCommunicationIds {
      for command in ["retry-communication", "replay-communication"] {
        let graphResult = await app.run([
          "graphql", command, communicationId,
          "--session-store", transitionSessionStore.path,
          "--output", "json"
        ])
        XCTAssertEqual(graphResult.exitCode, .success, "\(command) \(communicationId): \(graphResult.stderr) \(graphResult.stdout)")
      }
    }
    let preexistingResumeMessage = WorkflowMessageRecord(
      communicationId: "comm-000001",
      workflowExecutionId: runResult.session.sessionId,
      fromStepId: nil,
      toStepId: "main-worker",
      routingScope: .workflow,
      deliveryKind: .direct,
      sourceStepExecutionId: "resume-source-exec",
      payload: ["mode": .string("preserve-on-resume")],
      lifecycleStatus: .delivered,
      createdOrder: 1,
      createdAt: Date(timeIntervalSince1970: 0)
    )
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: tempDir.appendingPathComponent("sessions", isDirectory: true).path)).save(
      WorkflowRuntimePersistenceProjector.snapshot(session: runResult.session, workflowMessages: [preexistingResumeMessage])
    )
    let continued = await app.run([
      "session", "continue", runResult.session.sessionId,
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--output", "json"
    ])
    XCTAssertEqual(continued.exitCode, .success, continued.stderr)
    let continueResult = try decodeJSON(SessionResumeCommandResult.self, from: continued.stdout)
    XCTAssertEqual(continueResult.sessionId, runResult.session.sessionId)
    let continuedSnapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: tempDir.appendingPathComponent("sessions", isDirectory: true).path))
      .load(sessionId: runResult.session.sessionId)
    XCTAssertTrue(continuedSnapshot.workflowMessages.contains { $0.communicationId == "comm-000001" && $0.payload["mode"] == .string("preserve-on-resume") })
    let eventConfig = tempDir.appendingPathComponent("events.json")
    try """
    {
      "sources": [{"id":"web-a","kind":"webhook","path":"/events/web","signingSecretEnv":"WEBHOOK_SECRET"}],
      "bindings": [{"id":"bind-a","sourceId":"web-a","workflowName":"worker-only-single-step","inputMapping":{"mode":"event-input"}}]
    }
    """.write(to: eventConfig, atomically: true, encoding: .utf8)

    let eventEnvelope = tempDir.appendingPathComponent("event-envelope.json")
    try """
    {
      "sourceId": "web-a",
      "eventId": "event-1",
      "provider": "webhook",
      "eventType": "event-input",
      "input": {"mode": "event-input"}
    }
    """.write(to: eventEnvelope, atomically: true, encoding: .utf8)

    for command in [
      ["events", "validate", eventConfig.path],
      ["events", "list", eventConfig.path],
      ["events", "emit", eventConfig.path, "--variables", eventEnvelope.path],
      ["hook", "codex"],
      ["graphql", "schema"],
      ["graphql", "session", runResult.session.sessionId, "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path],
      ["serve", "status"],
      ["serve", "graphql"]
    ] {
      let result = await app.run(command + ["--output", "json"])
      XCTAssertEqual(result.exitCode, .success, command.joined(separator: " "))
      let scoped = try decodeJSON(ScopedParityCommandResult.self, from: result.stdout)
      XCTAssertEqual(scoped.status, "ok")
    }

    let eventRoot = tempDir.appendingPathComponent("event-root", isDirectory: true)
    let eventEmit = await app.run([
      "events", "emit", "web-a",
      "--event-root", eventRoot.path,
      "--event-file", eventEnvelope.path,
      "--output", "json"
    ])
    XCTAssertEqual(eventEmit.exitCode, .success, eventEmit.stderr)
    let eventEmitResult = try decodeJSON(ScopedParityCommandResult.self, from: eventEmit.stdout)
    XCTAssertEqual(eventEmitResult.status, "ok")
    let eventReceiptId = try XCTUnwrap(eventEmitResult.records.first { $0.hasPrefix("receipt=") }?.dropFirst("receipt=".count).description)
    let eventReceiptURL = eventRoot.appendingPathComponent("receipts/\(eventReceiptId).json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: eventReceiptURL.path))

    let readOnlyEventEnvelope = tempDir.appendingPathComponent("event-envelope-read-only.json")
    try """
    {
      "sourceId": "web-a",
      "eventId": "event-read-only",
      "provider": "webhook",
      "eventType": "event-input",
      "input": {"mode": "read-only-input"}
    }
    """.write(to: readOnlyEventEnvelope, atomically: true, encoding: .utf8)
    let readOnlyEventEmit = await app.run([
      "events", "emit", "web-a",
      "--event-root", eventRoot.path,
      "--event-file", readOnlyEventEnvelope.path,
      "--read-only",
      "--output", "json"
    ])
    XCTAssertEqual(readOnlyEventEmit.exitCode, .success, readOnlyEventEmit.stderr)
    let readOnlyEventEmitResult = try decodeJSON(ScopedParityCommandResult.self, from: readOnlyEventEmit.stdout)
    XCTAssertEqual(readOnlyEventEmitResult.status, "ok")

    let duplicateEventEnvelope = tempDir.appendingPathComponent("event-envelope-duplicate.json")
    try """
    {
      "sourceId": "web-a",
      "eventId": "event-1",
      "provider": "webhook",
      "eventType": "event-input",
      "input": {"mode": "duplicate-input"}
    }
    """.write(to: duplicateEventEnvelope, atomically: true, encoding: .utf8)
    let duplicateEventEmit = await app.run([
      "events", "emit", "web-a",
      "--event-root", eventRoot.path,
      "--event-file", duplicateEventEnvelope.path,
      "--output", "json"
    ])
    XCTAssertEqual(duplicateEventEmit.exitCode, .success, duplicateEventEmit.stderr)
    let duplicateEventEmitResult = try decodeJSON(ScopedParityCommandResult.self, from: duplicateEventEmit.stdout)
    XCTAssertEqual(duplicateEventEmitResult.status, "duplicate")
    XCTAssertTrue(duplicateEventEmitResult.records.contains { $0.contains("duplicate=true") })
    let originalReceiptText = try String(contentsOf: eventReceiptURL, encoding: .utf8)
    XCTAssertTrue(originalReceiptText.contains("event-input"))
    XCTAssertFalse(originalReceiptText.contains("duplicate-input"))

    let eventList = await app.run([
      "events", "list", "web-a",
      "--event-root", eventRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(eventList.exitCode, .success, eventList.stderr)
    let eventListResult = try decodeJSON(ScopedParityCommandResult.self, from: eventList.stdout)
    XCTAssertTrue(eventListResult.records.contains { $0.contains(eventReceiptId) })

    let eventReplay = await app.run([
      "events", "replay", eventReceiptId,
      "--event-root", eventRoot.path,
      "--reason", "test",
      "--output", "json"
    ])
    XCTAssertEqual(eventReplay.exitCode, .success, eventReplay.stderr)
    let eventReplayResult = try decodeJSON(ScopedParityCommandResult.self, from: eventReplay.stdout)
    XCTAssertEqual(eventReplayResult.status, "ok")
    let eventReplayReceiptId = try XCTUnwrap(eventReplayResult.records.first { $0.hasPrefix("receipt=") }?.dropFirst("receipt=".count).description)
    XCTAssertTrue(FileManager.default.fileExists(atPath: eventRoot.appendingPathComponent("receipts/\(eventReplayReceiptId).json").path))

    let slashEventEnvelope = tempDir.appendingPathComponent("event-envelope-slash.json")
    try """
    {
      "sourceId": "web-a",
      "eventId": "a/b",
      "provider": "webhook",
      "eventType": "event-input",
      "input": {"mode": "slash"}
    }
    """.write(to: slashEventEnvelope, atomically: true, encoding: .utf8)
    let colonEventEnvelope = tempDir.appendingPathComponent("event-envelope-colon.json")
    try """
    {
      "sourceId": "web-a",
      "eventId": "a:b",
      "provider": "webhook",
      "eventType": "event-input",
      "input": {"mode": "colon"}
    }
    """.write(to: colonEventEnvelope, atomically: true, encoding: .utf8)
    let slashEmit = await app.run([
      "events", "emit", "web-a",
      "--event-root", eventRoot.path,
      "--event-file", slashEventEnvelope.path,
      "--output", "json"
    ])
    let colonEmit = await app.run([
      "events", "emit", "web-a",
      "--event-root", eventRoot.path,
      "--event-file", colonEventEnvelope.path,
      "--output", "json"
    ])
    XCTAssertEqual(slashEmit.exitCode, .success, slashEmit.stderr)
    XCTAssertEqual(colonEmit.exitCode, .success, colonEmit.stderr)
    let slashEmitResult = try decodeJSON(ScopedParityCommandResult.self, from: slashEmit.stdout)
    let colonEmitResult = try decodeJSON(ScopedParityCommandResult.self, from: colonEmit.stdout)
    XCTAssertEqual(slashEmitResult.status, "ok")
    XCTAssertEqual(colonEmitResult.status, "ok")
    let slashReceiptId = try XCTUnwrap(slashEmitResult.records.first { $0.hasPrefix("receipt=") }?.dropFirst("receipt=".count).description)
    let colonReceiptId = try XCTUnwrap(colonEmitResult.records.first { $0.hasPrefix("receipt=") }?.dropFirst("receipt=".count).description)
    XCTAssertNotEqual(slashReceiptId, colonReceiptId)
    XCTAssertTrue(FileManager.default.fileExists(atPath: eventRoot.appendingPathComponent("receipts/\(slashReceiptId).json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: eventRoot.appendingPathComponent("receipts/\(colonReceiptId).json").path))

    let eventServe = await app.run([
      "events", "serve",
      "--event-root", eventRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(eventServe.exitCode, .success, eventServe.stderr)
    let eventServeResult = try decodeJSON(ScopedParityCommandResult.self, from: eventServe.stdout)
    XCTAssertEqual(eventServeResult.status, "ok")
    XCTAssertTrue(FileManager.default.fileExists(atPath: eventRoot.appendingPathComponent("serve-record.json").path))

    let liveEventRoot = tempDir.appendingPathComponent("live-event-root", isDirectory: true)
    try FileManager.default.createDirectory(at: liveEventRoot.appendingPathComponent("sources", isDirectory: true), withIntermediateDirectories: true)
    try """
    {
      "id": "telegram-live",
      "kind": "telegram-gateway",
      "provider": "telegram",
      "tokenEnv": "RIELA_TELEGRAM_BOT_TOKEN"
    }
    """.write(
      to: liveEventRoot.appendingPathComponent("sources/telegram-live.json"),
      atomically: true,
      encoding: .utf8
    )
    let liveEventServe = await app.run([
      "events", "serve",
      "--event-root", liveEventRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(liveEventServe.exitCode, .success, liveEventServe.stderr)
    let liveEventServeResult = try decodeJSON(ScopedParityCommandResult.self, from: liveEventServe.stdout)
    XCTAssertEqual(liveEventServeResult.status, "failed")
    XCTAssertTrue(liveEventServeResult.records.contains("status=unavailable"))
    XCTAssertTrue(liveEventServeResult.records.contains("unsupportedLiveSources=telegram-live:telegram-gateway"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: liveEventRoot.appendingPathComponent("serve-record.json").path))

    let dryRunLiveEventServe = await app.run([
      "events", "serve",
      "--event-root", liveEventRoot.path,
      "--dry-run",
      "--output", "json"
    ])
    XCTAssertEqual(dryRunLiveEventServe.exitCode, .success, dryRunLiveEventServe.stderr)
    let dryRunLiveEventServeResult = try decodeJSON(ScopedParityCommandResult.self, from: dryRunLiveEventServe.stdout)
    XCTAssertEqual(dryRunLiveEventServeResult.status, "ok")
    XCTAssertTrue(dryRunLiveEventServeResult.records.contains("status=dry-run"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: liveEventRoot.appendingPathComponent("serve-record.json").path))

    try FileManager.default.createDirectory(at: eventRoot.appendingPathComponent("replies", isDirectory: true), withIntermediateDirectories: true)
    try #"{"idempotencyKey":"reply-1","sourceId":"web-a","status":"queued","workflowExecutionId":"run-1"}"#
      .write(to: eventRoot.appendingPathComponent("replies/reply-1.json"), atomically: true, encoding: .utf8)
    let eventReplies = await app.run([
      "events", "replies", "run-1",
      "--event-root", eventRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(eventReplies.exitCode, .success, eventReplies.stderr)
    let eventRepliesResult = try decodeJSON(ScopedParityCommandResult.self, from: eventReplies.stdout)
    XCTAssertTrue(eventRepliesResult.records.contains { $0.contains("reply-1") })

    try FileManager.default.createDirectory(at: eventRoot.appendingPathComponent("schedules", isDirectory: true), withIntermediateDirectories: true)
    try #"{"scheduleId":"schedule-1","sourceId":"web-a","status":"active","workflowName":"worker-only-single-step","kind":"cron","timezone":"UTC","nextDueAt":"2026-06-16T00:00:00Z"}"#
      .write(to: eventRoot.appendingPathComponent("schedules/schedule-1.json"), atomically: true, encoding: .utf8)
    for command in [
      ["events", "schedules", "list"],
      ["events", "schedules", "inspect", "schedule-1"],
      ["events", "schedules", "cancel", "schedule-1", "--reason", "test"]
    ] {
      let result = await app.run(command + [
        "--event-root", eventRoot.path,
        "--output", "json"
      ])
      XCTAssertEqual(result.exitCode, .success, command.joined(separator: " "))
      let scoped = try decodeJSON(ScopedParityCommandResult.self, from: result.stdout)
      XCTAssertEqual(scoped.status, "ok")
      XCTAssertTrue(scoped.records.contains { $0.contains("schedule-1") })
    }

    let managerSession = await app.run([
      "graphql", "manager-session", runResult.session.sessionId,
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--output", "json"
    ])
    XCTAssertEqual(managerSession.exitCode, .success, managerSession.stderr)
    let managerSessionResult = try decodeJSON(ScopedParityCommandResult.self, from: managerSession.stdout)
    XCTAssertEqual(managerSessionResult.status, "ok")
    XCTAssertTrue(managerSessionResult.records.first?.contains(runResult.session.sessionId) == true)

    let missingManagerMessage = await app.run([
      "graphql", "send-manager-message", runResult.session.sessionId,
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--output", "json"
    ])
    XCTAssertNotEqual(missingManagerMessage.exitCode, .success)
    XCTAssertTrue(missingManagerMessage.stdout.contains("requires --message-json or --message-file"))

    let managerMessage = await app.run([
      "graphql", "send-manager-message", runResult.session.sessionId,
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--message-json", #"{"kind":"retry","target":"main-worker","reason":"test-manager-control"}"#,
      "--output", "json"
    ])
    XCTAssertEqual(managerMessage.exitCode, .success, managerMessage.stderr)
    let managerMessageResult = try decodeJSON(ScopedParityCommandResult.self, from: managerMessage.stdout)
    XCTAssertEqual(managerMessageResult.status, "ok")
    let managerSnapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: tempDir.appendingPathComponent("sessions", isDirectory: true).path)
    ).load(sessionId: runResult.session.sessionId)
    let managerMessageRecord = try XCTUnwrap(managerSnapshot.workflowMessages.first {
      $0.payload["reason"] == .string("test-manager-control")
    })
    let managerCommunicationId = managerMessageRecord.communicationId
    XCTAssertTrue(managerMessageResult.records.first?.contains(managerCommunicationId) == true)
    XCTAssertEqual(managerMessageRecord.payload["kind"], .string("retry"))
    XCTAssertEqual(managerMessageRecord.payload["target"], .string("main-worker"))
    XCTAssertEqual(managerMessageRecord.payload["reason"], .string("test-manager-control"))
    XCTAssertNil(managerMessageRecord.payload["managerMessage"])

    var secondSession = runResult.session
    secondSession.sessionId = "worker-only-single-step-session-200"
    try CLIWorkflowSessionStore(rootDirectory: tempDir.appendingPathComponent("sessions", isDirectory: true).path).save(PersistedCLIWorkflowSession(
      workflowName: "worker-only-single-step",
      session: secondSession,
      resolution: WorkflowResolutionOptions(workflowName: "worker-only-single-step", scope: .direct, workflowDefinitionDir: "\(root)/examples", workingDirectory: tempDir.path),
      mockScenarioPath: "\(root)/examples/worker-only-single-step/mock-scenario.json"
    ))
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: tempDir.appendingPathComponent("sessions", isDirectory: true).path)).save(
      WorkflowRuntimePersistenceProjector.snapshot(session: secondSession)
    )
    let secondManagerMessage = await app.run([
      "graphql", "send-manager-message", secondSession.sessionId,
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--message-json", #"{"kind":"retry","target":"main-worker","reason":"second-manager-control"}"#,
      "--output", "json"
    ])
    XCTAssertEqual(secondManagerMessage.exitCode, .success, secondManagerMessage.stderr)
    let secondManagerMessageResult = try decodeJSON(ScopedParityCommandResult.self, from: secondManagerMessage.stdout)
    let secondManagerCommunicationId = "graphql-manager-\(secondSession.sessionId)-1"
    XCTAssertTrue(secondManagerMessageResult.records.first?.contains(secondManagerCommunicationId) == true)
    XCTAssertNotEqual(managerCommunicationId, secondManagerCommunicationId)

    for command in [
      ["graphql", "replay-communication", managerCommunicationId],
      ["graphql", "retry-communication", managerCommunicationId],
      ["graphql", "retry-communication-delivery", managerCommunicationId]
    ] {
      let result = await app.run(command + [
        "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
        "--output", "json"
      ])
      XCTAssertEqual(result.exitCode, .success, command.joined(separator: " "))
      let scoped = try decodeJSON(ScopedParityCommandResult.self, from: result.stdout)
      XCTAssertEqual(scoped.status, "ok")
      XCTAssertTrue(scoped.records.first?.contains(managerCommunicationId) == true)
    }
    let secondRetry = await app.run([
      "graphql", "retry-communication", secondManagerCommunicationId,
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--output", "json"
    ])
    XCTAssertEqual(secondRetry.exitCode, .success, secondRetry.stderr)
    let secondRetryResult = try decodeJSON(ScopedParityCommandResult.self, from: secondRetry.stdout)
    XCTAssertTrue(secondRetryResult.records.first?.contains(secondManagerCommunicationId) == true)

    let callRoot = tempDir.appendingPathComponent("call-step-root", isDirectory: true)
    let callWorkflow = callRoot.appendingPathComponent("call-flow", isDirectory: true)
    try FileManager.default.createDirectory(at: callWorkflow.appendingPathComponent("nodes", isDirectory: true), withIntermediateDirectories: true)
    try """
    {
      "workflowId": "call-flow",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "step-a",
      "nodes": [
        { "id": "node-a", "nodeFile": "nodes/node-a.json" },
        { "id": "node-b", "nodeFile": "nodes/node-b.json" }
      ],
      "steps": [
        { "id": "step-a", "nodeId": "node-a", "role": "worker", "transitions": [{ "toStepId": "step-b" }] },
        { "id": "step-b", "nodeId": "node-b", "role": "worker" }
      ]
    }
    """.write(to: callWorkflow.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try #"{"id":"node-a","executionBackend":"codex-agent","model":"gpt-5.5","variables":{}}"#
      .write(to: callWorkflow.appendingPathComponent("nodes/node-a.json"), atomically: true, encoding: .utf8)
    try #"{"id":"node-b","executionBackend":"codex-agent","model":"gpt-5.5","variables":{},"promptVariants":{"direct":{"promptTemplate":"direct variant"}}}"#
      .write(to: callWorkflow.appendingPathComponent("nodes/node-b.json"), atomically: true, encoding: .utf8)
    let callScenario = tempDir.appendingPathComponent("call-step-scenario.json")
    try #"{"step-b":{"provider":"scenario-mock","model":"gpt-5.5","payload":{"status":"called-step-b"}}}"#
      .write(to: callScenario, atomically: true, encoding: .utf8)
    let callSessionStore = tempDir.appendingPathComponent("call-step-sessions", isDirectory: true)
    let callSession = WorkflowSession(
      workflowId: "call-flow",
      sessionId: "call-flow-run-1",
      status: .running,
      entryStepId: "step-a",
      currentStepId: "step-b",
      createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0)
    )
    try CLIWorkflowSessionStore(rootDirectory: callSessionStore.path).save(PersistedCLIWorkflowSession(
      workflowName: "call-flow",
      session: callSession,
      resolution: WorkflowResolutionOptions(workflowName: "call-flow", scope: .direct, workflowDefinitionDir: callRoot.path, workingDirectory: tempDir.path),
      mockScenarioPath: callScenario.path
    ))
    let preexistingCallMessage = WorkflowMessageRecord(
      communicationId: "comm-000001",
      workflowExecutionId: callSession.sessionId,
      fromStepId: nil,
      toStepId: "step-b",
      routingScope: .workflow,
      deliveryKind: .direct,
      sourceStepExecutionId: "preexisting-call-exec",
      payload: ["mode": .string("preexisting-call-message")],
      lifecycleStatus: .delivered,
      createdOrder: 1,
      createdAt: Date(timeIntervalSince1970: 0)
    )
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: callSessionStore.path)).save(
      WorkflowRuntimePersistenceProjector.snapshot(session: callSession, workflowMessages: [preexistingCallMessage])
    )
    let called = await app.run([
      "call-step", "call-flow", "call-flow-run-1", "step-b",
      "--workflow-definition-dir", callRoot.path,
      "--session-store", callSessionStore.path,
      "--message-json", #"{"mode":"direct"}"#,
      "--prompt-variant", "direct",
      "--resume-step-exec", "previous-exec-1",
      "--output", "json"
    ])
    XCTAssertEqual(called.exitCode, .success, called.stderr)
    let calledResult = try decodeJSON(WorkflowRunResult.self, from: called.stdout)
    XCTAssertEqual(calledResult.session.sessionId, "call-flow-run-1")
    XCTAssertEqual(calledResult.session.executions.map(\.stepId), ["step-b"])
    XCTAssertEqual(calledResult.rootOutput?["resumedFromNodeExecId"], .string("previous-exec-1"))
    XCTAssertEqual(calledResult.rootOutput?["promptText"], .string("direct variant"))
    let calledSnapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: callSessionStore.path))
      .load(sessionId: calledResult.session.sessionId)
    let directCallMessage = try XCTUnwrap(calledSnapshot.workflowMessages.first { $0.payload["directCallPromptVariant"] == .string("direct") })
    XCTAssertEqual(directCallMessage.payload["directCallPromptVariant"], .string("direct"))
    XCTAssertEqual(calledSnapshot.rootOutput?["resumedFromNodeExecId"], .string("previous-exec-1"))
    let calledCommunicationIds = calledSnapshot.workflowMessages.map(\.communicationId)
    XCTAssertEqual(Set(calledCommunicationIds).count, calledCommunicationIds.count)
    XCTAssertTrue(calledCommunicationIds.contains("comm-000001"))
    XCTAssertTrue(calledCommunicationIds.contains("comm-000002"))

    let workflowCallSessionStore = tempDir.appendingPathComponent("workflow-call-sessions", isDirectory: true)
    let workflowCallSession = WorkflowSession(
      workflowId: "call-flow",
      sessionId: "call-flow-run-2",
      status: .running,
      entryStepId: "step-a",
      currentStepId: "step-b",
      createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0)
    )
    try CLIWorkflowSessionStore(rootDirectory: workflowCallSessionStore.path).save(PersistedCLIWorkflowSession(
      workflowName: "call-flow",
      session: workflowCallSession,
      resolution: WorkflowResolutionOptions(workflowName: "call-flow", scope: .direct, workflowDefinitionDir: callRoot.path, workingDirectory: tempDir.path),
      mockScenarioPath: callScenario.path
    ))
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: workflowCallSessionStore.path)).save(
      WorkflowRuntimePersistenceProjector.snapshot(session: workflowCallSession)
    )
    let workflowCalled = await app.run([
      "workflow-call", "call-flow", "call-flow-run-2", "step-b",
      "--workflow-definition-dir", callRoot.path,
      "--mock-scenario", callScenario.path,
      "--session-store", workflowCallSessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(workflowCalled.exitCode, .success, workflowCalled.stderr)
    let workflowCalledResult = try decodeJSON(WorkflowRunResult.self, from: workflowCalled.stdout)
    XCTAssertEqual(workflowCalledResult.session.sessionId, "call-flow-run-2")
    XCTAssertEqual(workflowCalledResult.session.executions.map(\.stepId), ["step-b"])
    XCTAssertEqual(
      try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: workflowCallSessionStore.path))
        .load(sessionId: workflowCalledResult.session.sessionId)
        .session
        .sessionId,
      workflowCalledResult.session.sessionId
    )
  }

}
