import XCTest
@testable import RielaCore

final class ForcedReadOnlySandboxRunnerTests: XCTestCase {
  func testBotContextForcesReadOnlyAtAdapterDispatch() async throws {
    let unchanged = try await adapterSandbox(forceReadOnly: false)
    let forced = try await adapterSandbox(forceReadOnly: true)
    XCTAssertEqual(unchanged, .workspaceWrite)
    XCTAssertEqual(forced, .readOnly)
  }

  private func adapterSandbox(forceReadOnly: Bool) async throws -> AgentSandboxMode {
    let workflow = WorkflowDefinition(
      workflowId: "forced-read-only",
      defaults: WorkflowDefaults(nodeTimeoutMs: 5_000, maxLoopIterations: 1),
      entryStepId: "inspect",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "agent", nodeFile: "nodes/agent.json")],
      steps: [WorkflowStepRef(id: "inspect", nodeId: "agent", role: .worker)],
      nodes: [WorkflowNodeRef(id: "inspect", nodeFile: "nodes/agent.json")]
    )
    let node = AgentNodePayload(
      id: "agent", executionBackend: .codexAgent, model: "test",
      agentSandbox: .workspaceWrite, promptTemplate: "Inspect the workspace."
    )
    var request = DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: ["agent": node])
    request.botContext = BotRunContext(botId: "bot", permissionWaitMs: 0, forceReadOnlySandbox: forceReadOnly)
    let adapter = SandboxCapturingAdapter()
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter)
    let result = try await runner.run(request)
    XCTAssertEqual(result.status, .completed)
    let sandbox = await adapter.sandbox
    return try XCTUnwrap(sandbox)
  }
}

private actor SandboxCapturingAdapter: NodeAdapter {
  private(set) var sandbox: AgentSandboxMode?

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    sandbox = input.node.agentSandbox
    return AdapterExecutionOutput(
      provider: "test", model: input.node.model, promptText: input.promptText,
      completionPassed: true, payload: ["ok": .bool(true)]
    )
  }
}
