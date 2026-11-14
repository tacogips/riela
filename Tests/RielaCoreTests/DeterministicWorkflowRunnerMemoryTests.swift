import XCTest
import RielaMemory
@testable import RielaCore

final class DeterministicWorkflowRunnerMemoryTests: XCTestCase {
  func testManagerRecordsNodeInboxAndOutboxToSharedCrossWorkflowMemory() async throws {
    let memoryRoot = temporaryDirectory("shared-rina-memory")
    defer {
      try? FileManager.default.removeItem(atPath: memoryRoot)
    }
    let sharedMemory = WorkflowMemoryDeclaration(
      id: "rina-shared",
      description: "Rina conversation memory shared by chat entrypoints",
      scope: .crossWorkflow
    )
    let platforms = [
      ("discord-rina", "discord-rina-node", "discord hello"),
      ("telegram-rina", "telegram-rina-node", "telegram hello"),
      ("matrix-rina", "matrix-rina-node", "matrix hello")
    ]

    for platform in platforms {
      let runner = DeterministicWorkflowRunner(
        adapter: MemoryStaticAdapter(output: adapterOutput(payload: ["reply": .string("ok")])),
        inputResolver: StaticInputResolver(payload: ["message": .string(platform.2)])
      )
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: rinaWorkflow(workflowId: platform.0, nodeId: platform.1, memory: sharedMemory),
        nodePayloads: [
          platform.1: AgentNodePayload(
            id: platform.1,
            executionBackend: .codexAgent,
            model: "gpt-5-nano",
            memories: [sharedMemory]
          )
        ],
        memoryRootDirectory: memoryRoot
      ))
    }

    let records = try RielaMemoryStore(rootDirectory: memoryRoot).search(
      memoryId: "rina-shared",
      options: MemorySearchOptions(workflowId: "telegram-rina", includeAllWorkflows: true, limit: 20)
    )

    XCTAssertEqual(records.count, 6)
    XCTAssertEqual(Set(records.map(\.workflowId)), ["discord-rina", "telegram-rina", "matrix-rina"])
    let payloads = records.compactMap(objectPayload)
    XCTAssertEqual(payloads.filter { $0["direction"] == .string("inbox") }.count, 3)
    XCTAssertEqual(payloads.filter { $0["direction"] == .string("outbox") }.count, 3)
    XCTAssertTrue(payloads.contains { payload in
      payload["workflowId"] == .string("discord-rina")
        && payload["nodeId"] == .string("discord-rina-node")
        && payload["direction"] == .string("inbox")
        && payload["input"] == .object(["message": .string("discord hello")])
    })
    XCTAssertTrue(payloads.contains { payload in
      payload["workflowId"] == .string("telegram-rina")
        && payload["direction"] == .string("outbox")
        && payload["output"] == .object(["reply": .string("ok")])
    })
  }

  func testManagerRecordsFailedNodeOutbox() async throws {
    let memoryRoot = temporaryDirectory("failed-node-memory")
    defer {
      try? FileManager.default.removeItem(atPath: memoryRoot)
    }
    let memory = WorkflowMemoryDeclaration(id: "failure-memory")
    let runner = DeterministicWorkflowRunner(
      adapter: FailingMemoryAdapter(),
      inputResolver: StaticInputResolver(payload: ["request": .string("fail please")])
    )

    await XCTAssertThrowsErrorAsync(try await runner.run(DeterministicWorkflowRunRequest(
      workflow: singleNodeWorkflow(workflowId: "failure-workflow", nodeId: "agent-node", memory: memory),
      nodePayloads: [
        "agent-node": AgentNodePayload(id: "agent-node", executionBackend: .codexAgent, model: "gpt-5-nano")
      ],
      memoryRootDirectory: memoryRoot
    )))

    let payloads = try memoryPayloads(memoryRoot: memoryRoot, memoryId: "failure-memory", workflowId: "failure-workflow")
    XCTAssertEqual(payloads.map { $0["direction"] }, [.string("outbox"), .string("inbox")])
    XCTAssertEqual(payloads.first?["status"], .string("failed"))
    XCTAssertEqual(payloads.first?["output"], .null)
    XCTAssertEqual(payloads.first?["failureReason"], .string("provider_error: forced failure"))
  }

  func testNoDeclaredMemoryDoesNotCreateMemoryDatabase() async throws {
    let memoryRoot = temporaryDirectory("no-memory")
    defer {
      try? FileManager.default.removeItem(atPath: memoryRoot)
    }
    let runner = DeterministicWorkflowRunner(
      adapter: MemoryStaticAdapter(output: adapterOutput()),
      inputResolver: StaticInputResolver(payload: ["message": .string("ignored")])
    )

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: singleNodeWorkflow(workflowId: "no-memory-workflow", nodeId: "agent-node", memory: nil),
      nodePayloads: [
        "agent-node": AgentNodePayload(id: "agent-node", executionBackend: .codexAgent, model: "gpt-5-nano")
      ],
      memoryRootDirectory: memoryRoot
    ))

    XCTAssertFalse(FileManager.default.fileExists(atPath: memoryRoot))
  }

  func testDuplicateMemoryDeclarationsAreSavedOnceAndMemoryRootCanComeFromWorkflowInput() async throws {
    let memoryRoot = temporaryDirectory("dedupe-memory")
    defer {
      try? FileManager.default.removeItem(atPath: memoryRoot)
    }
    let memory = WorkflowMemoryDeclaration(id: "dedupe-memory")
    let runner = DeterministicWorkflowRunner(
      adapter: MemoryStaticAdapter(output: adapterOutput(payload: ["status": .string("ok")])),
      inputResolver: StaticInputResolver(payload: ["message": .string("dedupe")])
    )

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: duplicatedMemoryWorkflow(memory: memory),
      nodePayloads: [
        "agent-node": AgentNodePayload(
          id: "agent-node",
          executionBackend: .codexAgent,
          model: "gpt-5-nano",
          memories: [memory]
        )
      ],
      variables: ["workflowInput": .object(["memoryRoot": .string(memoryRoot)])]
    ))

    let records = try RielaMemoryStore(rootDirectory: memoryRoot).search(
      memoryId: "dedupe-memory",
      options: MemorySearchOptions(workflowId: "dedupe-workflow")
    )
    XCTAssertEqual(records.count, 2)
    XCTAssertEqual(records.compactMap(objectPayload).map { $0["direction"] }, [.string("outbox"), .string("inbox")])
  }

  func testCommandNodeRecordsInboxAndNullOutboxWhileReceivingMemoryContext() async throws {
    let memoryRoot = temporaryDirectory("command-memory")
    defer {
      try? FileManager.default.removeItem(atPath: memoryRoot)
    }
    let memory = WorkflowMemoryDeclaration(id: "command-memory", scope: .node)
    let executor = CapturingStdioNodeExecutor(result: WorkflowStdioNodeExecutionResult(payload: nil))
    let runner = DeterministicWorkflowRunner(
      stdioNodeExecutor: executor,
      inputResolver: StaticInputResolver(payload: ["commandInput": .string("ready")])
    )

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: singleNodeWorkflow(workflowId: "command-workflow", nodeId: "command-node", memory: memory),
      nodePayloads: [
        "command-node": AgentNodePayload(
          id: "command-node",
          nodeType: .command,
          model: "",
          command: WorkflowCommandExecution(executable: "/bin/sh", arguments: ["-c", "true"])
        )
      ],
      memoryRootDirectory: memoryRoot
    ))

    let capturedInputs = await executor.capturedInputs()
    let capturedInput = try XCTUnwrap(capturedInputs.first)
    XCTAssertEqual(capturedInput.memoryRootDirectory, memoryRoot)
    XCTAssertEqual(capturedInput.availableMemories.map(\.id), ["command-memory"])
    let payloads = try memoryPayloads(memoryRoot: memoryRoot, memoryId: "command-memory", workflowId: "command-workflow")
    XCTAssertEqual(payloads.count, 2)
    XCTAssertEqual(payloads.first?["direction"], .string("outbox"))
    XCTAssertEqual(payloads.first?["output"], .null)
    XCTAssertEqual(payloads.first?["status"], .string("completed"))
  }

  func testContainerAndAddonNodesRecordMemoryThroughManager() async throws {
    let memoryRoot = temporaryDirectory("container-addon-memory")
    defer {
      try? FileManager.default.removeItem(atPath: memoryRoot)
    }
    let memory = WorkflowMemoryDeclaration(id: "node-kind-memory", scope: .crossWorkflow)
    let stdioExecutor = CapturingStdioNodeExecutor(result: WorkflowStdioNodeExecutionResult(payload: ["container": .bool(true)]))
    let addonResolver = MemoryAddonResolver(output: adapterOutput(payload: ["addon": .bool(true)]))
    let runner = DeterministicWorkflowRunner(
      addonResolver: addonResolver,
      stdioNodeExecutor: stdioExecutor,
      inputResolver: StaticInputResolver(payload: ["shared": .string("input")])
    )

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: containerAddonWorkflow(memory: memory),
      nodePayloads: [
        "container-node": AgentNodePayload(
          id: "container-node",
          nodeType: .container,
          model: "",
          container: WorkflowContainerExecution(image: "example/rina:latest", command: ["./run.sh"])
        )
      ],
      memoryRootDirectory: memoryRoot
    ))

    let capturedStdioInputs = await stdioExecutor.capturedInputs()
    let capturedStdioInput = try XCTUnwrap(capturedStdioInputs.first)
    XCTAssertEqual(capturedStdioInput.kind, .container)
    XCTAssertEqual(capturedStdioInput.memoryRootDirectory, memoryRoot)
    let maybeCapturedAddonInput = await addonResolver.capturedInput()
    let capturedAddonInput = try XCTUnwrap(maybeCapturedAddonInput)
    XCTAssertEqual(capturedAddonInput.nodeId, "addon-node")
    let payloads = try memoryPayloads(memoryRoot: memoryRoot, memoryId: "node-kind-memory", workflowId: "container-addon-workflow")
    XCTAssertEqual(payloads.filter { $0["direction"] == .string("inbox") }.count, 2)
    XCTAssertEqual(payloads.filter { $0["direction"] == .string("outbox") }.count, 2)
    XCTAssertTrue(payloads.contains { $0["nodeId"] == .string("container-node") && $0["output"] == .object(["container": .bool(true)]) })
    XCTAssertTrue(payloads.contains { $0["nodeId"] == .string("addon-node") && $0["output"] == .object(["addon": .bool(true)]) })
  }

  private func rinaWorkflow(
    workflowId: String,
    nodeId: String,
    memory: WorkflowMemoryDeclaration
  ) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: workflowId,
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      memories: [memory],
      entryStepId: "rina",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: nodeId, nodeFile: "nodes/rina.json", memories: [memory])
      ],
      steps: [WorkflowStepRef(id: "rina", nodeId: nodeId, role: .worker)],
      nodes: [WorkflowNodeRef(id: "rina", nodeFile: "nodes/rina.json", role: .worker, memories: [memory])]
    )
  }

  private func singleNodeWorkflow(
    workflowId: String,
    nodeId: String,
    memory: WorkflowMemoryDeclaration?
  ) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: workflowId,
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      memories: memory.map { [$0] },
      entryStepId: "step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: nodeId, nodeFile: "nodes/\(nodeId).json", memories: memory.map { [$0] })
      ],
      steps: [WorkflowStepRef(id: "step", nodeId: nodeId, role: .worker)],
      nodes: [WorkflowNodeRef(id: "step", nodeFile: "nodes/\(nodeId).json", role: .worker, memories: memory.map { [$0] })]
    )
  }

  private func duplicatedMemoryWorkflow(memory: WorkflowMemoryDeclaration) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "dedupe-workflow",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      memories: [memory],
      entryStepId: "step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "agent-node", nodeFile: "nodes/agent.json", memories: [memory])
      ],
      steps: [WorkflowStepRef(id: "step", nodeId: "agent-node", role: .worker)],
      nodes: [WorkflowNodeRef(id: "step", nodeFile: "nodes/agent.json", role: .worker, memories: [memory])]
    )
  }

  private func containerAddonWorkflow(memory: WorkflowMemoryDeclaration) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "container-addon-workflow",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      memories: [memory],
      entryStepId: "container-step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "container-node", nodeFile: "nodes/container.json", memories: [memory]),
        WorkflowNodeRegistryRef(
          id: "addon-node",
          addon: WorkflowNodeAddonRef(name: "example/addon"),
          memories: [memory]
        )
      ],
      steps: [
        WorkflowStepRef(id: "container-step", nodeId: "container-node", role: .worker, transitions: [WorkflowStepTransition(toStepId: "addon-step")]),
        WorkflowStepRef(id: "addon-step", nodeId: "addon-node", role: .worker)
      ],
      nodes: [
        WorkflowNodeRef(id: "container-step", nodeFile: "nodes/container.json", role: .worker, memories: [memory]),
        WorkflowNodeRef(id: "addon-step", addon: WorkflowNodeAddonRef(name: "example/addon"), role: .worker, memories: [memory])
      ]
    )
  }
}

private struct MemoryStaticAdapter: NodeAdapter {
  var output: AdapterExecutionOutput

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    output
  }
}

private struct FailingMemoryAdapter: NodeAdapter {
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    throw AdapterExecutionError(.providerError, "forced failure")
  }
}

private actor CapturingStdioNodeExecutor: WorkflowStdioNodeExecuting {
  private let result: WorkflowStdioNodeExecutionResult
  private var inputs: [WorkflowStdioNodeExecutionInput] = []

  init(result: WorkflowStdioNodeExecutionResult) {
    self.result = result
  }

  func execute(
    _ input: WorkflowStdioNodeExecutionInput,
    context: AdapterExecutionContext
  ) async throws -> WorkflowStdioNodeExecutionResult {
    inputs.append(input)
    return result
  }

  func capturedInputs() -> [WorkflowStdioNodeExecutionInput] {
    inputs
  }
}

private actor MemoryAddonResolver: WorkflowAddonResolving {
  private let output: AdapterExecutionOutput
  private var input: WorkflowAddonExecutionInput?

  init(output: AdapterExecutionOutput) {
    self.output = output
  }

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    self.input = input
    return output
  }

  func capturedInput() -> WorkflowAddonExecutionInput? {
    input
  }
}

private struct StaticInputResolver: WorkflowMessageInputResolving {
  var payload: JSONObject

  func resolveInput(
    for sessionId: String,
    stepId: String,
    store: any WorkflowRuntimeStore
  ) async throws -> WorkflowResolvedMessageInput {
    WorkflowResolvedMessageInput(
      workflowExecutionId: sessionId,
      stepId: stepId,
      messages: [],
      payload: payload,
      communicationIds: [],
      sourceStepIds: []
    )
  }
}

private func adapterOutput(
  payload: JSONObject = ["status": .string("ok")]
) -> AdapterExecutionOutput {
  AdapterExecutionOutput(
    provider: "test",
    model: "gpt-5-nano",
    promptText: "prompt",
    completionPassed: true,
    payload: payload
  )
}

private func objectPayload(_ record: MemoryRecord) -> [String: MemoryJSONValue]? {
  guard case let .object(payload) = record.payload else {
    return nil
  }
  return payload
}

private func memoryPayloads(
  memoryRoot: String,
  memoryId: String,
  workflowId: String
) throws -> [[String: MemoryJSONValue]] {
  try RielaMemoryStore(rootDirectory: memoryRoot)
    .search(memoryId: memoryId, options: MemorySearchOptions(workflowId: workflowId, limit: 20))
    .compactMap(objectPayload)
}

private func XCTAssertThrowsErrorAsync(
  _ expression: @autoclosure () async throws -> some Sendable,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("expected error", file: file, line: line)
  } catch {}
}

private func temporaryDirectory(_ name: String) -> String {
  URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("riela-\(name)-\(UUID().uuidString)", isDirectory: true)
    .path
}
