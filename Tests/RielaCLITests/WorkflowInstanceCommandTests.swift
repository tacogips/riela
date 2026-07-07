import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class WorkflowInstanceCommandTests: XCTestCase {
  func testTopLevelHelpDocumentsInstanceCommands() async {
    let result = await RielaCLIApplication().run(["--help"])

    XCTAssertEqual(result.exitCode, CLIExitCode.success)
    XCTAssertTrue(result.stdout.contains("riela instance list|show|create|update|remove"))
    XCTAssertTrue(result.stdout.contains("--instance <name>"))
  }

  func testRemoteWorkflowRunPassesInstanceIdentity() async throws {
    let transport = RecordingWorkflowGraphQLRunTransport()
    let app = RielaCLIApplication(runCommand: WorkflowRunCommand(graphQLTransport: transport))

    let result = await app.run([
      "workflow", "run", "worker-only-single-step",
      "--endpoint", "http://localhost:4000/graphql",
      "--instance", "prod",
      "--variables", #"{"request":"remote"}"#,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, CLIExitCode.success, result.stderr + result.stdout)
    let recordedRequest = await transport.recordedRequest()
    let request = try XCTUnwrap(recordedRequest)
    XCTAssertEqual(request.workflowName, "worker-only-single-step")
    XCTAssertEqual(request.instanceIdentity, "prod")
    XCTAssertEqual(request.runtimeVariables["request"], JSONValue.string("remote"))
  }

  func testWorkflowRunWithoutInstanceRecordsDefaultInstance() async throws {
    let root = repositoryRootURL()
    let tempRoot = root.appendingPathComponent("tmp/workflow-instance-default-\(UUID().uuidString)", isDirectory: true)
    let sessionStore = tempRoot.appendingPathComponent("sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let run = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", root.appendingPathComponent("examples", isDirectory: true).path,
      "--mock-scenario", root.appendingPathComponent("examples/worker-only-single-step/mock-scenario.json").path,
      "--working-dir", tempRoot.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])

    XCTAssertEqual(run.exitCode, CLIExitCode.success, run.stderr + run.stdout)
    let result = try decode(WorkflowRunResult.self, from: run.stdout)
    XCTAssertEqual(result.session.instanceIdentity, "default")
    XCTAssertEqual(result.session.instanceKind, "default")
    XCTAssertNil(result.session.instanceBaseIdentity)
  }

  func testInstanceCreateAndWorkflowRunInstanceRecordNamedProvenance() async throws {
    let root = repositoryRootURL()
    let tempRoot = root.appendingPathComponent("tmp/workflow-instance-run-\(UUID().uuidString)", isDirectory: true)
    let sessionStore = tempRoot.appendingPathComponent("sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let app = RielaCLIApplication()
    let examples = root.appendingPathComponent("examples", isDirectory: true).path
    let scenario = root.appendingPathComponent("examples/worker-only-single-step/mock-scenario.json").path

    let created = await app.run([
      "instance", "create", "prod",
      "--workflow", "worker-only-single-step",
      "--workflow-definition-dir", examples,
      "--cwd", tempRoot.path,
      "--variables", #"{"workflowInput":{"request":"from instance"}}"#,
      "--node-patch", #"{"main-worker":{"model":"gpt-5.3-instance"}}"#,
      "--output", "json"
    ])
    XCTAssertEqual(created.exitCode, CLIExitCode.success, created.stderr + created.stdout)

    let stored = try FileWorkflowInstanceStore(rootDirectory: tempRoot.appendingPathComponent(".riela", isDirectory: true).path)
      .find(identity: "prod", workflowId: "worker-only-single-step")
    XCTAssertEqual(
      stored?.configuration.defaultVariables["workflowInput"],
      JSONValue.object(["request": JSONValue.string("from instance")])
    )
    XCTAssertEqual(stored?.configuration.nodePatches["main-worker"]?.model, "gpt-5.3-instance")

    let run = await app.run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", examples,
      "--mock-scenario", scenario,
      "--working-dir", tempRoot.path,
      "--session-store", sessionStore.path,
      "--instance", "prod",
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, CLIExitCode.success, run.stderr + run.stdout)
    let result = try decode(WorkflowRunResult.self, from: run.stdout)
    XCTAssertEqual(result.session.instanceIdentity, "prod")
    XCTAssertEqual(result.session.instanceKind, "named")
    XCTAssertEqual(result.session.instanceConfiguration?["defaultVariables"], JSONValue.object([
      "workflowInput": JSONValue.object(["request": JSONValue.string("from instance")])
    ]))

    let status = await app.run([
      "session", "status", result.session.sessionId,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(status.exitCode, CLIExitCode.success, status.stderr + status.stdout)
    let inspection = try decode(SessionInspectionCommandResult.self, from: status.stdout)
    XCTAssertEqual(inspection.instanceIdentity, "prod")
    XCTAssertEqual(inspection.instanceKind, "named")
  }

  func testScopedStoreProjectPrecedesUserAndCorruptFileIsQuarantined() throws {
    let root = repositoryRootURL()
    let tempRoot = root.appendingPathComponent("tmp/workflow-instance-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let projectStore = FileWorkflowInstanceStore(
      rootDirectory: tempRoot.appendingPathComponent("project/.riela", isDirectory: true).path
    )
    let userStore = FileWorkflowInstanceStore(
      rootDirectory: tempRoot.appendingPathComponent("home/.riela", isDirectory: true).path
    )
    let scoped = ScopedWorkflowInstanceStore(project: projectStore, user: userStore)

    try userStore.save(WorkflowInstanceDefinition(
      identity: "prod",
      workflowId: "worker-only-single-step",
      configuration: WorkflowInstanceConfiguration(defaultVariables: ["scope": .string("user")])
    ))
    try projectStore.save(WorkflowInstanceDefinition(
      identity: "prod",
      workflowId: "worker-only-single-step",
      configuration: WorkflowInstanceConfiguration(defaultVariables: ["scope": .string("project")])
    ))

    let resolved = try XCTUnwrap(scoped.find(identity: "prod", workflowId: "worker-only-single-step"))
    XCTAssertEqual(resolved.0, .project)
    XCTAssertEqual(resolved.1.configuration.defaultVariables["scope"], .string("project"))
    let savedData = try Data(contentsOf: projectStore.fileURL)
    XCTAssertNoThrow(try JSONDecoder().decode(WorkflowInstanceStoreFile.self, from: savedData))

    let corruptStore = FileWorkflowInstanceStore(
      rootDirectory: tempRoot.appendingPathComponent("corrupt/.riela", isDirectory: true).path
    )
    try FileManager.default.createDirectory(
      at: corruptStore.fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "{not-json".write(to: corruptStore.fileURL, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try corruptStore.list()) { error in
      XCTAssertTrue("\(error)".contains("corrupt file moved"), "\(error)")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: corruptStore.fileURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: corruptStore.fileURL.path + ".corrupt"))
  }

  func testInstanceListAllIncludesReadOnlyRielaAppProfileInstances() async throws {
    let root = repositoryRootURL()
    let tempRoot = root.appendingPathComponent("tmp/workflow-instance-app-profile-\(UUID().uuidString)", isDirectory: true)
    let home = tempRoot.appendingPathComponent("home", isDirectory: true)
    let project = tempRoot.appendingPathComponent("project", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let stateURL = home
      .appendingPathComponent(".riela/rielaapp/profiles/work", isDirectory: true)
      .appendingPathComponent("daemon-workflows.json")
    try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    {
      "version": 1,
      "preferences": {
        "persona-a": {
          "identity": "persona-a",
          "sourceIdentity": "user-workflow:telegram-bot",
          "displayName": "Telegram Persona A",
          "available": true,
          "active": true,
          "configuration": {
            "workingDirectory": "/projects/persona-a",
            "defaultVariables": {"persona": "assistant-a"},
            "nodePatches": {"worker": {"model": "gpt-5-mini"}}
          }
        }
      }
    }
    """.write(to: stateURL, atomically: true, encoding: .utf8)

    let result = await RielaCLIApplication().run([
      "instance", "list",
      "--scope", "all",
      "--workflow", "telegram-bot",
      "--cwd", project.path,
      "--output", "json"
    ], environment: ["HOME": home.path])

    XCTAssertEqual(result.exitCode, CLIExitCode.success, result.stderr + result.stdout)
    let listing = try decode(TestInstanceListResult.self, from: result.stdout)
    let record = try XCTUnwrap(listing.instances.first)
    XCTAssertEqual(record.scope, "app:work")
    XCTAssertEqual(record.instance.identity, "persona-a")
    XCTAssertEqual(record.instance.workflowId, "telegram-bot")
    XCTAssertEqual(record.instance.sourceIdentity, "user-workflow:telegram-bot")
    XCTAssertEqual(record.instance.displayName, "Telegram Persona A")
    XCTAssertEqual(record.instance.configuration.defaultVariables["persona"], .string("assistant-a"))
    XCTAssertEqual(record.instance.configuration.nodePatches["worker"]?.model, "gpt-5-mini")
  }

  func testWorkflowRunUsesInstanceWorkingDirectoryForRelativeRunInputs() async throws {
    let root = repositoryRootURL()
    let tempRoot = root.appendingPathComponent("tmp/workflow-instance-cwd-\(UUID().uuidString)", isDirectory: true)
    let sessionStore = tempRoot.appendingPathComponent("sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let app = RielaCLIApplication()
    let examples = root.appendingPathComponent("examples", isDirectory: true).path

    let created = await app.run([
      "instance", "create", "prod",
      "--workflow", "worker-only-single-step",
      "--workflow-definition-dir", examples,
      "--cwd", tempRoot.path,
      "--working-dir", root.path,
      "--output", "json"
    ])
    XCTAssertEqual(created.exitCode, CLIExitCode.success, created.stderr + created.stdout)

    let command = WorkflowRunCommand()
    let resolution = WorkflowResolutionOptions(
      workflowName: "worker-only-single-step",
      scope: .auto,
      workflowDefinitionDir: examples,
      workingDirectory: tempRoot.path
    )
    let run = await command.run(WorkflowRunOptions(
      target: "worker-only-single-step",
      resolution: resolution,
      instance: "prod",
      mockScenarioPath: "examples/worker-only-single-step/mock-scenario.json",
      output: .json,
      sessionStore: sessionStore.path,
      workingDirectory: tempRoot.path,
      explicitWorkingDirectory: true
    ))

    XCTAssertEqual(run.exitCode, CLIExitCode.failure, "explicit --working-dir should override the instance cwd")

    let inheritedRun = await command.run(WorkflowRunOptions(
      target: "worker-only-single-step",
      resolution: resolution,
      instance: "prod",
      mockScenarioPath: "examples/worker-only-single-step/mock-scenario.json",
      output: .json,
      sessionStore: sessionStore.path,
      workingDirectory: tempRoot.path,
      explicitWorkingDirectory: false
    ))
    XCTAssertEqual(inheritedRun.exitCode, CLIExitCode.success, inheritedRun.stderr + inheritedRun.stdout)
    let result = try decode(WorkflowRunResult.self, from: inheritedRun.stdout)
    XCTAssertEqual(result.session.instanceIdentity, "prod")
  }

  func testSessionRerunFallsBackToRecordedInstanceSnapshotWhenNamedInstanceIsMissing() async throws {
    let root = repositoryRootURL()
    let tempRoot = root.appendingPathComponent("tmp/workflow-instance-rerun-\(UUID().uuidString)", isDirectory: true)
    let sessionStore = tempRoot.appendingPathComponent("sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let app = RielaCLIApplication()
    let examples = root.appendingPathComponent("examples", isDirectory: true).path
    let scenario = root.appendingPathComponent("examples/worker-only-single-step/mock-scenario.json").path

    let created = await app.run([
      "instance", "create", "prod",
      "--workflow", "worker-only-single-step",
      "--workflow-definition-dir", examples,
      "--cwd", tempRoot.path,
      "--variables", #"{"workflowInput":{"request":"snapshot"}}"#,
      "--output", "json"
    ])
    XCTAssertEqual(created.exitCode, CLIExitCode.success, created.stderr + created.stdout)
    let firstRun = await app.run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", examples,
      "--mock-scenario", scenario,
      "--working-dir", tempRoot.path,
      "--session-store", sessionStore.path,
      "--instance", "prod",
      "--output", "json"
    ])
    XCTAssertEqual(firstRun.exitCode, CLIExitCode.success, firstRun.stderr + firstRun.stdout)
    let first = try decode(WorkflowRunResult.self, from: firstRun.stdout)

    let removed = await app.run([
      "instance", "remove", "prod",
      "--workflow", "worker-only-single-step",
      "--cwd", tempRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(removed.exitCode, CLIExitCode.success, removed.stderr + removed.stdout)

    let rerun = await app.run([
      "session", "rerun", first.session.sessionId, "main-worker",
      "--workflow-definition-dir", examples,
      "--mock-scenario", scenario,
      "--working-dir", tempRoot.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(rerun.exitCode, CLIExitCode.success, rerun.stderr + rerun.stdout)
    XCTAssertTrue(rerun.stderr.contains("used the source session snapshot"), rerun.stderr)
    let payload = try decode(SessionRerunCommandResult.self, from: rerun.stdout)
    let status = await app.run([
      "session", "status", payload.sessionId,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(status.exitCode, CLIExitCode.success, status.stderr + status.stdout)
    let inspection = try decode(SessionInspectionCommandResult.self, from: status.stdout)
    XCTAssertEqual(inspection.instanceIdentity, "prod")
    XCTAssertEqual(
      inspection.instanceConfiguration?["defaultVariables"],
      .object(["workflowInput": .object(["request": .string("snapshot")])])
    )
  }

  func testSessionRerunPreservesRunNodePatchBackend() async throws {
    let root = repositoryRootURL()
    let tempRoot = root.appendingPathComponent("tmp/workflow-node-patch-rerun-\(UUID().uuidString)", isDirectory: true)
    let sessionStore = tempRoot.appendingPathComponent("sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let app = RielaCLIApplication()
    let examples = root.appendingPathComponent("examples", isDirectory: true).path
    let scenario = root.appendingPathComponent("examples/worker-only-single-step/mock-scenario.json").path

    let firstRun = await app.run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", examples,
      "--mock-scenario", scenario,
      "--working-dir", tempRoot.path,
      "--session-store", sessionStore.path,
      "--node-patch", #"{"main-worker":{"executionBackend":"claude-code-agent"}}"#,
      "--output", "json"
    ])
    XCTAssertEqual(firstRun.exitCode, CLIExitCode.success, firstRun.stderr + firstRun.stdout)
    let first = try decode(WorkflowRunResult.self, from: firstRun.stdout)
    XCTAssertEqual(first.session.instanceKind, "temporary")
    XCTAssertEqual(first.session.executions.map(\.backend), [.claudeCodeAgent])

    let rerun = await app.run([
      "session", "rerun", first.session.sessionId, "main-worker",
      "--workflow-definition-dir", examples,
      "--mock-scenario", scenario,
      "--working-dir", tempRoot.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(rerun.exitCode, CLIExitCode.success, rerun.stderr + rerun.stdout)
    let payload = try decode(SessionRerunCommandResult.self, from: rerun.stdout)

    let status = await app.run([
      "session", "status", payload.sessionId,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(status.exitCode, CLIExitCode.success, status.stderr + status.stdout)
    let inspection = try decode(SessionInspectionCommandResult.self, from: status.stdout)
    XCTAssertEqual(inspection.instanceKind, "temporary")
    XCTAssertEqual(
      inspection.instanceConfiguration?["nodePatches"],
      .object(["main-worker": .object(["executionBackend": .string("claude-code-agent")])])
    )
    XCTAssertEqual(
      inspection.executions.map(\.backend),
      [.claudeCodeAgent],
      "session rerun must reuse the source session's --node-patch backend (tacogips/riela#33)"
    )
  }

  func testSessionResumePreservesRunNodePatchBackend() async throws {
    let root = repositoryRootURL()
    let tempRoot = root.appendingPathComponent("tmp/workflow-node-patch-resume-\(UUID().uuidString)", isDirectory: true)
    let sessionStore = tempRoot.appendingPathComponent("sessions", isDirectory: true)
    let workflowRoot = tempRoot.appendingPathComponent("workflows", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    try writeTwoStepWorkerWorkflow(workflowRoot: workflowRoot)
    let scenario = workflowRoot.appendingPathComponent("two-step-worker/mock-scenario.json").path
    let app = RielaCLIApplication()

    let firstRun = await app.run([
      "workflow", "run", "two-step-worker",
      "--workflow-definition-dir", workflowRoot.path,
      "--mock-scenario", scenario,
      "--working-dir", tempRoot.path,
      "--session-store", sessionStore.path,
      "--node-patch", #"{"second-worker":{"executionBackend":"claude-code-agent"}}"#,
      "--max-steps", "1",
      "--output", "json"
    ])
    XCTAssertEqual(firstRun.exitCode, CLIExitCode.failure, firstRun.stderr + firstRun.stdout)
    let failure = try decode(WorkflowRunFailureResult.self, from: firstRun.stdout)
    XCTAssertEqual(failure.failureKind, .maxStepsExceeded)
    let sessionId = try XCTUnwrap(failure.sessionId)

    let resume = await app.run([
      "session", "resume", sessionId,
      "--workflow-definition-dir", workflowRoot.path,
      "--mock-scenario", scenario,
      "--working-dir", tempRoot.path,
      "--session-store", sessionStore.path,
      "--max-steps", "4",
      "--output", "json"
    ])
    XCTAssertEqual(resume.exitCode, CLIExitCode.success, resume.stderr + resume.stdout)
    let resumePayload = try decode(SessionResumeCommandResult.self, from: resume.stdout)
    XCTAssertEqual(resumePayload.status, .completed)

    let status = await app.run([
      "session", "status", sessionId,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(status.exitCode, CLIExitCode.success, status.stderr + status.stdout)
    let inspection = try decode(SessionInspectionCommandResult.self, from: status.stdout)
    let secondWorkerBackends = inspection.executions.filter { $0.stepId == "second-worker" }.map(\.backend)
    XCTAssertEqual(
      secondWorkerBackends,
      [.claudeCodeAgent],
      "session resume must reuse the source session's --node-patch backend (tacogips/riela#33)"
    )
  }

  private func writeTwoStepWorkerWorkflow(workflowRoot: URL) throws {
    let workflowDirectory = workflowRoot.appendingPathComponent("two-step-worker", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    let promptsDirectory = workflowDirectory.appendingPathComponent("prompts", isDirectory: true)
    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: promptsDirectory, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "two-step-worker",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 10000 },
      "entryStepId": "first-worker",
      "nodes": [
        { "id": "first-worker", "nodeFile": "nodes/node-first-worker.json" },
        { "id": "second-worker", "nodeFile": "nodes/node-second-worker.json" }
      ],
      "steps": [
        {
          "id": "first-worker",
          "nodeId": "first-worker",
          "role": "worker",
          "transitions": [{ "toStepId": "second-worker" }]
        },
        { "id": "second-worker", "nodeId": "second-worker", "role": "worker" }
      ]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    for nodeId in ["first-worker", "second-worker"] {
      try """
      {
        "id": "\(nodeId)",
        "executionBackend": "codex-agent",
        "model": "gpt-5.3-codex-spark",
        "promptTemplateFile": "prompts/worker.md",
        "variables": {},
        "output": { "description": "Return a concise completion summary as business JSON." }
      }
      """.write(to: nodesDirectory.appendingPathComponent("node-\(nodeId).json"), atomically: true, encoding: .utf8)
    }
    try """
    Complete the assigned workflow step for {{workflowId}}.

    Summarize the completion result as business JSON only.
    """.write(to: promptsDirectory.appendingPathComponent("worker.md"), atomically: true, encoding: .utf8)
    try """
    {
      "first-worker": {
        "provider": "scenario-mock",
        "model": "gpt-5.3-codex-spark",
        "when": { "always": true },
        "payload": { "status": "first done" }
      },
      "second-worker": {
        "provider": "scenario-mock",
        "model": "gpt-5.3-codex-spark",
        "when": { "always": true },
        "payload": { "status": "second done" }
      }
    }
    """.write(to: workflowDirectory.appendingPathComponent("mock-scenario.json"), atomically: true, encoding: .utf8)
  }

  private func decode<T: Decodable>(_ type: T.Type, from stdout: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: Data(stdout.utf8))
  }

  private func repositoryRootURL() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
        return url
      }
      url.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  }
}

private struct TestInstanceListResult: Decodable {
  var instances: [TestInstanceRecord]
}

private struct TestInstanceRecord: Decodable {
  var scope: String
  var instance: WorkflowInstanceDefinition
}
