import Foundation
import XCTest
@testable import RielaAdapters
@testable import RielaCore

final class WorkflowStdioNodeExecutorTests: XCTestCase {
  func testCommandNodePassesInputJSONLOnStdinAndReadsStdoutJSONL() async throws {
    let runner = RecordingStdioNodeProcessRunner { configuration, stdin in
      let lines = stdin.split(whereSeparator: \.isNewline)
      XCTAssertEqual(lines.count, 1)
      let inputData = try XCTUnwrap(String(lines[0]).data(using: .utf8))
      let decoded = try JSONDecoder().decode(WorkflowStdioNodeInvocationEnvelope.self, from: inputData)
      XCTAssertEqual(decoded.workflowId, "workflow")
      XCTAssertEqual(decoded.workflowExecutionId, "session")
      XCTAssertEqual(decoded.stepId, "step")
      XCTAssertEqual(decoded.nodeId, "node")
      XCTAssertEqual(decoded.nodeType, "command")
      XCTAssertEqual(decoded.input["upstream"], .string("ready"))
      XCTAssertEqual(decoded.variables["target"], .string("prod"))
      XCTAssertEqual(decoded.policy?.allowed, true)
      XCTAssertNil(configuration.environment["RIELA_MAILBOX_DIR"])
      XCTAssertNil(configuration.environment["RIELA_WORKFLOW_INPUT"])
      XCTAssertNil(configuration.environment["RIELA_WORKFLOW_OUTPUT"])
      return #"{"status":"ok"}"# + "\n"
    }
    let executor = LocalWorkflowStdioNodeExecutor(runner: runner)

    let result = try await executor.execute(
      input(kind: .command, node: AgentNodePayload(
        id: "node",
        nodeType: .command,
        model: "",
        command: WorkflowCommandExecution(
          executable: "node",
          arguments: ["worker.js"],
          environment: [
            "RIELA_MAILBOX_DIR": "/tmp/legacy",
            "RIELA_WORKFLOW_INPUT": "legacy-input",
            "RIELA_WORKFLOW_OUTPUT": "legacy-output",
            "KEEP": "1"
          ]
        )
      ), policy: allowedPolicy()),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(result.payload, ["status": .string("ok")])
    XCTAssertEqual(result.commandEvidence?.id, "step#1")
    XCTAssertEqual(result.commandEvidence?.argvRedactionStatus, "clean")
    XCTAssertEqual(result.commandEvidence?.stdoutStoragePolicy, "summary-only")
    XCTAssertEqual(result.commandEvidence?.stderrStoragePolicy, "summary-only")
    XCTAssertEqual(result.commandEvidence?.exitCode, 0)
    XCTAssertEqual(result.commandEvidence?.argvSummary, "/usr/bin/env node worker.js")
    let configurations = await runner.configurations()
    let configuration = try XCTUnwrap(configurations.first)
    XCTAssertEqual(configuration.executableURL.path, "/usr/bin/env")
    XCTAssertEqual(configuration.arguments, ["node", "worker.js"])
    XCTAssertEqual(configuration.environment["KEEP"], "1")
    XCTAssertTrue(configuration.unsetEnvironmentKeys.contains("RIELA_WORKFLOW_INPUT"))
    XCTAssertTrue(configuration.unsetEnvironmentKeys.contains("RIELA_WORKFLOW_OUTPUT"))
  }

  func testPolicyDeniedCommandNodeFailsBeforeProcessLaunch() async throws {
    let runner = RecordingStdioNodeProcessRunner { _, _ in
      XCTFail("process runner should not be invoked when policy denies stdio execution")
      return ""
    }
    let executor = LocalWorkflowStdioNodeExecutor(runner: runner)

    do {
      _ = try await executor.execute(
        input(kind: .command, node: AgentNodePayload(
          id: "node",
          nodeType: .command,
          model: "",
          command: WorkflowCommandExecution(executable: "/bin/sh", arguments: ["-c", "codex exec"])
        ), policy: deniedPolicy()),
        context: AdapterExecutionContext()
      )
      XCTFail("expected policy blocked error")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("process.nestedCodex"))
    }

    let configurations = await runner.configurations()
    XCTAssertTrue(configurations.isEmpty)
  }

  func testEmptyStdoutMeansNoWorkflowOutput() async throws {
    let runner = RecordingStdioNodeProcessRunner { _, _ in
      ""
    }
    let executor = LocalWorkflowStdioNodeExecutor(runner: runner)

    let result = try await executor.execute(
      input(kind: .command, node: AgentNodePayload(
        id: "node",
        nodeType: .command,
        model: "",
        command: WorkflowCommandExecution(executable: "/bin/sh", arguments: ["-c", "true"])
      )),
      context: AdapterExecutionContext()
    )

    XCTAssertNil(result.payload)
  }

  func testCommandNodeRendersRielaArgumentAndEnvironmentTemplates() async throws {
    let runner = RecordingStdioNodeProcessRunner { configuration, _ in
      XCTAssertEqual(configuration.arguments, [
        "node",
        "--state",
        ".riela-data/x-follower-ai-business-digest/mock-state.json",
        "--status",
        "ready"
      ])
      XCTAssertEqual(configuration.environment["STATE_FILE"], ".riela-data/x-follower-ai-business-digest/mock-state.json")
      XCTAssertEqual(configuration.environment["UPSTREAM"], "ready")
      return #"{"status":"ok"}"# + "\n"
    }
    let executor = LocalWorkflowStdioNodeExecutor(runner: runner)

    let result = try await executor.execute(
      input(
        kind: .command,
        node: AgentNodePayload(
          id: "node",
          nodeType: .command,
          model: "",
          command: WorkflowCommandExecution(
            executable: "node",
            arguments: ["--state", "{{workflowInput.stateFile}}", "--status", "{{input.upstream}}"],
            environment: [
              "STATE_FILE": "{{workflowInput.stateFile}}",
              "UPSTREAM": "{{upstream}}"
            ]
          )
        ),
        variables: ["target": .string("prod"), "stateFile": .string(".riela-data/x-follower-ai-business-digest/mock-state.json")]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(result.payload, ["status": .string("ok")])
  }

  func testInvalidStdoutJSONLFailsBeforePublication() async throws {
    let runner = RecordingStdioNodeProcessRunner { _, _ in
      "{not-json\n"
    }
    let executor = LocalWorkflowStdioNodeExecutor(runner: runner)

    do {
      _ = try await executor.execute(
        input(kind: .command, node: AgentNodePayload(
          id: "node",
          nodeType: .command,
          model: "",
          command: WorkflowCommandExecution(executable: "/bin/sh")
        )),
        context: AdapterExecutionContext()
      )
      XCTFail("expected invalid JSON failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidOutput)
      XCTAssertTrue(error.message.contains("stdout"))
    }
  }

  func testMultipleStdoutJSONLRecordsFailClosed() async throws {
    let runner = RecordingStdioNodeProcessRunner { _, _ in
      #"{"one":1}"# + "\n" + #"{"two":2}"# + "\n"
    }
    let executor = LocalWorkflowStdioNodeExecutor(runner: runner)

    do {
      _ = try await executor.execute(
        input(kind: .command, node: AgentNodePayload(
          id: "node",
          nodeType: .command,
          model: "",
          command: WorkflowCommandExecution(executable: "/bin/sh")
        )),
        context: AdapterExecutionContext()
      )
      XCTFail("expected multiple JSONL output record failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidOutput)
      XCTAssertTrue(error.message.contains("at most one JSONL output record"))
    }
  }

  func testContainerNodeUsesStdinAndStdoutJSONLContract() async throws {
    let runner = RecordingStdioNodeProcessRunner { configuration, stdin in
      XCTAssertFalse(stdin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      XCTAssertNil(configuration.environment["RIELA_WORKFLOW_INPUT"])
      XCTAssertNil(configuration.environment["RIELA_WORKFLOW_OUTPUT"])
      return #"{"container":true}"# + "\n"
    }
    let executor = LocalWorkflowStdioNodeExecutor(runner: runner)

    let result = try await executor.execute(
      input(kind: .container, node: AgentNodePayload(
        id: "node",
        nodeType: .container,
        model: "",
        container: WorkflowContainerExecution(
          image: "ghcr.io/example/worker:latest",
          runnerKind: "docker",
          command: ["./run.sh"],
          environment: [
            "RIELA_MAILBOX_DIR": "/tmp/legacy",
            "RIELA_WORKFLOW_INPUT": "legacy-input",
            "RIELA_WORKFLOW_OUTPUT": "legacy-output",
            "APP_ENV": "test"
          ]
        )
      )),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(result.payload, ["container": .bool(true)])
    let configurations = await runner.configurations()
    let configuration = try XCTUnwrap(configurations.first)
    XCTAssertEqual(configuration.executableURL.path, "/usr/bin/env")
    XCTAssertEqual(Array(configuration.arguments.prefix(4)), ["docker", "run", "--rm", "-i"])
    XCTAssertTrue(configuration.arguments.contains("APP_ENV"))
    XCTAssertFalse(configuration.arguments.contains("RIELA_MAILBOX_DIR"))
    XCTAssertFalse(configuration.arguments.contains("RIELA_WORKFLOW_INPUT"))
    XCTAssertFalse(configuration.arguments.contains("RIELA_WORKFLOW_OUTPUT"))
  }

  func testContainerRunnerKindUsesContainerCLI() async throws {
    let runner = RecordingStdioNodeProcessRunner { _, _ in
      #"{"container":true}"# + "\n"
    }
    let executor = LocalWorkflowStdioNodeExecutor(runner: runner)

    _ = try await executor.execute(
      input(
        kind: .container,
        node: AgentNodePayload(
          id: "node",
          nodeType: .container,
          model: "",
          container: WorkflowContainerExecution(
            image: "ghcr.io/example/worker:latest",
            runnerKind: "container",
            command: ["./run.sh"],
            environment: ["APP_ENV": "test"]
          )
        ),
        variables: ["target": .string("prod")]
      ),
      context: AdapterExecutionContext()
    )

    let configurations = await runner.configurations()
    let configuration = try XCTUnwrap(configurations.first)
    XCTAssertEqual(configuration.executableURL.path, "/usr/bin/env")
    XCTAssertEqual(Array(configuration.arguments.prefix(4)), ["container", "run", "--rm", "-i"])
    XCTAssertTrue(configuration.arguments.contains("APP_ENV"))
    XCTAssertTrue(configuration.arguments.contains("ghcr.io/example/worker:latest"))
    XCTAssertTrue(configuration.arguments.contains("./run.sh"))
  }

  func testContainerNodeReceivesWritableMemoryBindAndContainerMemoryRoot() async throws {
    let memoryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-container-memory-\(UUID().uuidString)", isDirectory: true)
      .path
    defer {
      try? FileManager.default.removeItem(atPath: memoryRoot)
    }
    let runner = RecordingStdioNodeProcessRunner { configuration, stdin in
      let inputLine = try XCTUnwrap(stdin.split(whereSeparator: \.isNewline).first)
      let inputData = try XCTUnwrap(String(inputLine).data(using: .utf8))
      let decoded = try JSONDecoder().decode(WorkflowStdioNodeInvocationEnvelope.self, from: inputData)
      XCTAssertEqual(decoded.memoryRootDirectory, memoryRoot)
      XCTAssertEqual(decoded.availableMemories.map(\.id), ["rina-shared"])
      XCTAssertEqual(configuration.environment["RIELA_MEMORY_ROOT"], "/riela/memory")
      return #"{"container":true}"# + "\n"
    }
    let executor = LocalWorkflowStdioNodeExecutor(runner: runner)

    _ = try await executor.execute(
      input(
        kind: .container,
        node: AgentNodePayload(
          id: "node",
          nodeType: .container,
          model: "",
          container: WorkflowContainerExecution(
            image: "ghcr.io/example/rina:latest",
            runnerKind: "docker",
            command: ["./run.sh"]
          )
        ),
        memoryRootDirectory: memoryRoot,
        availableMemories: [WorkflowMemoryDeclaration(id: "rina-shared", scope: .crossWorkflow)]
      ),
      context: AdapterExecutionContext()
    )

    let configurations = await runner.configurations()
    let configuration = try XCTUnwrap(configurations.first)
    XCTAssertTrue(configuration.arguments.contains("-v"))
    XCTAssertTrue(configuration.arguments.contains("\(memoryRoot):/riela/memory"))
    XCTAssertTrue(configuration.arguments.contains("RIELA_MEMORY_ROOT"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: memoryRoot))
  }

  private func input(
    kind: WorkflowStdioNodeExecutionKind,
    node: AgentNodePayload,
    variables: JSONObject = ["target": .string("prod")],
    memoryRootDirectory: String? = nil,
    availableMemories: [WorkflowMemoryDeclaration] = [],
    policy: LoopPolicyStepDecision? = nil
  ) -> WorkflowStdioNodeExecutionInput {
    WorkflowStdioNodeExecutionInput(
      workflowId: "workflow",
      sessionId: "session",
      stepId: "step",
      nodeId: "node",
      executionIndex: 1,
      kind: kind,
      node: node,
      variables: variables,
      resolvedInputPayload: ["upstream": .string("ready")],
      memoryRootDirectory: memoryRootDirectory,
      availableMemories: availableMemories,
      policy: policy
    )
  }

  private func allowedPolicy() -> LoopPolicyStepDecision {
    LoopPolicyStepDecision(
      stepId: "step",
      nodeId: "node",
      allowed: true,
      decisions: [LoopPolicyDecision(id: "allow", policy: "process.allowedBackends", decision: "allow")]
    )
  }

  private func deniedPolicy() -> LoopPolicyStepDecision {
    let denial = LoopPolicyDecision(id: "deny", policy: "process.nestedCodex", decision: "deny")
    return LoopPolicyStepDecision(
      stepId: "step",
      nodeId: "node",
      allowed: false,
      decisions: [denial],
      denials: [denial]
    )
  }
}

private actor RecordingStdioNodeProcessRunner: LocalAgentProcessRunning {
  typealias Handler = @Sendable (LocalAgentProcessConfiguration, String) throws -> String

  private let handler: Handler
  private var capturedConfigurations: [LocalAgentProcessConfiguration] = []

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?
  ) async throws -> LocalAgentProcessResult {
    capturedConfigurations.append(configuration)
    let stdout = try handler(configuration, stdin)
    return LocalAgentProcessResult(stdout: stdout, stderr: "", terminationStatus: 0)
  }

  func configurations() -> [LocalAgentProcessConfiguration] {
    capturedConfigurations
  }
}
