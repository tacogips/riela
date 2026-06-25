import Foundation
import RielaAdapters
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

extension WorkflowCommandTests {
  func testScopedPackageIdsInstallListRunPublishUpdateAndRemove() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-scoped-package-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
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
    try """
    {
      "name": "@scope/scoped-flow",
      "version": "1.0.0",
      "description": "Scoped package",
      "tags": ["scoped"],
      "registry": "local",
      "checksum": "cccccccccccccccccccccccccccccccc",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: packageSource.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let install = await app.run([
      "package", "install", "@scope/scoped-flow",
      "--source", packageSource.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .success, install.stderr)
    let installed = try decodeJSON(WorkflowPackageCommandResult.self, from: install.stdout)
    let installedDirectory = tempDir.appendingPathComponent(".riela/packages/@scope/scoped-flow", isDirectory: true)
    XCTAssertEqual(installed.destinationDirectory, installedDirectory.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: installedDirectory.appendingPathComponent("riela-package.json").path))

    let list = await app.run([
      "package", "list",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(list.exitCode, .success, list.stderr)
    let listed = try decodeJSON(WorkflowPackageCommandResult.self, from: list.stdout)
    XCTAssertEqual(listed.packages.map(\.name), ["@scope/scoped-flow"])
    XCTAssertEqual(listed.packages.first?.valid, true)

    for command in ["run", "temp-run"] {
      let result = await app.run([
        "package", command, "@scope/scoped-flow",
        "--working-dir", tempDir.path,
        "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
        "--output", "json"
      ])
      XCTAssertEqual(result.exitCode, .success, "\(command): \(result.stderr) \(result.stdout)")
      let run = try decodeJSON(WorkflowPackageCommandResult.self, from: result.stdout)
      XCTAssertEqual(run.target, "@scope/scoped-flow")
      XCTAssertNotNil(run.runSessionId)
    }

    let update = await app.run([
      "package", "update", "@scope/scoped-flow",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(update.exitCode, .success, update.stderr)
    let updated = try decodeJSON(WorkflowPackageCommandResult.self, from: update.stdout)
    XCTAssertEqual(updated.packages.map(\.name), ["@scope/scoped-flow"])

    let publish = await app.run([
      "package", "publish", packageSource.path,
      "--package-name", "@scope/scoped-flow",
      "--working-dir", tempDir.path,
      "--yes",
      "--output", "json"
    ])
    XCTAssertEqual(publish.exitCode, .success, publish.stderr)
    let published = try decodeJSON(WorkflowPackageCommandResult.self, from: publish.stdout)
    XCTAssertEqual(published.packages.first?.name, "@scope/scoped-flow")
    let encodedKey = "%40scope%2Fscoped-flow"
    XCTAssertEqual(published.destinationDirectory, tempDir.appendingPathComponent(".riela/package-registry/\(encodedKey).json").path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/package-cache/\(encodedKey).json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/package-locks/\(encodedKey).json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/package-native-addons/\(encodedKey).json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/skills/\(encodedKey)/SKILL.md").path))

    let remove = await app.run([
      "package", "remove", "@scope/scoped-flow",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(remove.exitCode, .success, remove.stderr)
    XCTAssertFalse(FileManager.default.fileExists(atPath: installedDirectory.path))
  }

  func testPackageRemoveAndEventRecordCommandsRejectTraversalIdentifiers() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-traversal-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let app = RielaCLIApplication()
    let escapedPackageTarget = tempDir.appendingPathComponent(".riela/some-directory", isDirectory: true)
    try FileManager.default.createDirectory(at: escapedPackageTarget, withIntermediateDirectories: true)
    let packageRemove = await app.run([
      "package", "remove", "../some-directory",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(packageRemove.exitCode, .failure)
    XCTAssertTrue(packageRemove.stdout.contains("invalid package name"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: escapedPackageTarget.path))

    let escapedPackage = tempDir.appendingPathComponent(".riela/escape", isDirectory: true)
    try FileManager.default.createDirectory(at: escapedPackage, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/workflow.json"),
      to: escapedPackage.appendingPathComponent("workflow.json")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/nodes"),
      to: escapedPackage.appendingPathComponent("nodes")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/prompts"),
      to: escapedPackage.appendingPathComponent("prompts")
    )
    try """
    {
      "name": "escape",
      "version": "1.0.0",
      "description": "Escaped package",
      "tags": ["test"],
      "registry": "local",
      "checksum": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: escapedPackage.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let packageTempRun = await app.run([
      "package", "temp-run", "../escape",
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(packageTempRun.exitCode, .failure)
    XCTAssertTrue(packageTempRun.stdout.contains("invalid package name"))

    let packagePublish = await app.run([
      "package", "publish", escapedPackage.path,
      "--package-name", "../escape",
      "--working-dir", tempDir.path,
      "--yes",
      "--output", "json"
    ])
    XCTAssertEqual(packagePublish.exitCode, .failure)
    XCTAssertTrue(packagePublish.stdout.contains("invalid package name"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/package-registry/escape.json").path))

    let eventRoot = tempDir.appendingPathComponent("event-root", isDirectory: true)
    try FileManager.default.createDirectory(at: eventRoot.appendingPathComponent("receipts", isDirectory: true), withIntermediateDirectories: true)
    let replayTraversal = await app.run([
      "events", "replay", "../outside",
      "--event-root", eventRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(replayTraversal.exitCode, .failure)
    XCTAssertTrue(replayTraversal.stdout.contains("invalid event receipt id"))

    try FileManager.default.createDirectory(at: eventRoot.appendingPathComponent("schedules", isDirectory: true), withIntermediateDirectories: true)
    try """
    {
      "scheduleId": "../escape",
      "sourceId": "web-a",
      "status": "active",
      "workflowName": "worker-only-single-step",
      "kind": "cron",
      "timezone": "UTC",
      "nextDueAt": "2026-06-16T00:00:00Z"
    }
    """.write(to: eventRoot.appendingPathComponent("schedules/schedule-1.json"), atomically: true, encoding: .utf8)
    let scheduleTraversal = await app.run([
      "events", "schedules", "inspect", "../escape",
      "--event-root", eventRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(scheduleTraversal.exitCode, .failure)
    XCTAssertTrue(scheduleTraversal.stdout.contains("invalid event schedule id"))

    let scheduleCancel = await app.run([
      "events", "schedules", "cancel", "schedule-1",
      "--event-root", eventRoot.path,
      "--reason", "test",
      "--output", "json"
    ])
    XCTAssertEqual(scheduleCancel.exitCode, .failure)
    XCTAssertTrue(scheduleCancel.stdout.contains("invalid event schedule id"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: eventRoot.appendingPathComponent("escape.json").path))
  }

  func testInspectJSONFailureReturnsParseableEnvelopeForMissingWorkflow() async throws {
    let result = await RielaCLIApplication().run([
      "workflow", "inspect", "definitely-missing-workflow",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowInspectionFailureResult.self, from: result.stdout)
    XCTAssertEqual(failure.workflowId, "definitely-missing-workflow")
    XCTAssertEqual(failure.exitCode, CLIExitCode.failure.rawValue)
    XCTAssertTrue(failure.error.contains("notFound"))
  }

  func testInspectJSONFailureReturnsDiagnosticsForInvalidWorkflow() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-invalid-inspect-\(UUID().uuidString)", isDirectory: true)
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
      "workflow", "inspect", "broken",
      "--workflow-definition-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowInspectionFailureResult.self, from: result.stdout)
    XCTAssertEqual(failure.workflowId, "broken")
    XCTAssertTrue(failure.error.contains("invalidWorkflow"))
    XCTAssertTrue(failure.diagnostics.contains {
      $0.path == "workflow.entryStepId" && $0.message.contains("missing-entry")
    })
  }

  func testScenarioSequenceRetriesInvalidOutputContractBeforePublishingTransition() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let scenario = WorkflowMockScenario(responses: [
      "step": [
        MockNodeResponse(payload: ["other": .string("invalid")]),
        MockNodeResponse(payload: ["status": .string("valid")])
      ]
    ])
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: ScenarioNodeAdapter(scenario: scenario)
    )
    let workflow = WorkflowDefinition(
      workflowId: "retry-scenario",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json"),
        WorkflowNodeRegistryRef(id: "next-node", nodeFile: "nodes/next-node.json")
      ],
      steps: [
        WorkflowStepRef(id: "step", nodeId: "node", transitions: [WorkflowStepTransition(toStepId: "next")]),
        WorkflowStepRef(id: "next", nodeId: "next-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json"),
        WorkflowNodeRef(id: "next", nodeFile: "nodes/next-node.json")
      ]
    )
    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "node": AgentNodePayload(
          id: "node",
          executionBackend: .codexAgent,
          model: "gpt-5.5",
          output: NodeOutputContract(
            jsonSchema: [
              "type": .string("object"),
              "required": .array([.string("status")])
            ],
            maxValidationAttempts: 2
          )
        ),
        "next-node": AgentNodePayload(id: "next-node", executionBackend: .codexAgent, model: "gpt-5.5")
      ]
    ))

    XCTAssertEqual(result.status, .completed)
    let retriedExecutions = result.session.executions.filter { $0.stepId == "step" }
    XCTAssertEqual(retriedExecutions.map(\.attempt), [1, 2])
    XCTAssertEqual(retriedExecutions.map(\.status), [.failed, .completed])
    XCTAssertEqual(retriedExecutions.first?.acceptedOutput, nil)
    XCTAssertEqual(retriedExecutions.last?.acceptedOutput?.payload["status"], .string("valid"))
    let messages = try await store.listMessages(for: result.session.sessionId, toStepId: nil)
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?.sourceStepExecutionId, retriedExecutions.last?.executionId)
  }

  func testScenarioSequenceSkipsUnusedRetrySlotsForRepeatedStepExecutions() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let scenario = WorkflowMockScenario(responses: [
      "step": [
        MockNodeResponse(when: ["loop": true], payload: ["status": .string("first")]),
        MockNodeResponse(fail: true),
        MockNodeResponse(when: ["loop": false, "done": true], payload: ["status": .string("second")])
      ]
    ])
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: ScenarioNodeAdapter(scenario: scenario)
    )
    let workflow = WorkflowDefinition(
      workflowId: "repeat-scenario",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json"),
        WorkflowNodeRegistryRef(id: "final-node", nodeFile: "nodes/final-node.json")
      ],
      steps: [
        WorkflowStepRef(id: "step", nodeId: "node", transitions: [
          WorkflowStepTransition(toStepId: "step", label: "loop"),
          WorkflowStepTransition(toStepId: "final", label: "done")
        ]),
        WorkflowStepRef(id: "final", nodeId: "final-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json"),
        WorkflowNodeRef(id: "final", nodeFile: "nodes/final-node.json")
      ]
    )
    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "node": AgentNodePayload(
          id: "node",
          executionBackend: .codexAgent,
          model: "gpt-5.5",
          output: NodeOutputContract(
            jsonSchema: [
              "type": .string("object"),
              "required": .array([.string("status")])
            ],
            maxValidationAttempts: 2
          )
        ),
        "final-node": AgentNodePayload(id: "final-node", executionBackend: .codexAgent, model: "gpt-5.5")
      ],
      maxSteps: 3
    ))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.nodeExecutions, 3)
    XCTAssertEqual(result.transitions, 2)
    let executions = result.session.executions.filter { $0.stepId == "step" }
    XCTAssertEqual(executions.map(\.attempt), [1, 1])
    XCTAssertEqual(executions.map(\.acceptedOutput?.payload["status"]), [.string("first"), .string("second")])
    let messages = try await store.listMessages(for: result.session.sessionId, toStepId: nil)
    XCTAssertEqual(messages.map(\.toStepId), ["step", "final"])
  }

  func testScenarioLookupUsesExecutingStepIdWhenNodeIsReusable() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let scenarioURL = tempDir.appendingPathComponent("scenario.json")
    try """
    {
      "step-a": {
        "provider": "scenario-mock",
        "model": "gpt-5.5",
        "payload": {
          "status": "step-key-used"
        }
      }
    }
    """.write(to: scenarioURL, atomically: true, encoding: .utf8)
    let workflowJSON = """
    {
      "workflow": {
        "workflowId": "reusable-node-scenario",
        "defaults": {
          "maxLoopIterations": 3,
          "nodeTimeoutMs": 120000
        },
        "entryStepId": "step-a",
        "nodes": [
          {
            "id": "shared-worker",
            "nodeFile": "nodes/shared-worker.json"
          }
        ],
        "steps": [
          {
            "id": "step-a",
            "nodeId": "shared-worker",
            "role": "worker"
          }
        ]
      },
      "nodePayloads": {
        "nodes/shared-worker.json": {
          "id": "shared-worker",
          "executionBackend": "codex-agent",
          "model": "gpt-5.5",
          "variables": {}
        }
      }
    }
    """

    let result = await RielaCLIApplication().run([
      "workflow", "run", workflowJSON,
      "--mock-scenario", scenarioURL.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success)
    let run = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    XCTAssertEqual(run.rootOutput?["status"], .string("step-key-used"))
    XCTAssertEqual(run.session.executions.first?.stepId, "step-a")
    XCTAssertEqual(run.session.executions.first?.nodeId, "shared-worker")
  }

}
