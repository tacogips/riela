import XCTest
@testable import RielaCore

final class RuntimeEnvironmentPropagationTests: XCTestCase {
  func testRunnerResolvesAgentBindingFromExplicitExecutionSnapshot() async throws {
    let adapter = SnapshotEnvironmentAdapter()
    let workflow = WorkflowDefinition(workflowId: "environment", defaults: WorkflowDefaults(nodeTimeoutMs: 1000, maxLoopIterations: 2), entryStepId: "step",
      nodeRegistry: [.init(id: "node", nodeFile: "node.json")], steps: [.init(id: "step", nodeId: "node")],
      nodes: [.init(id: "node", nodeFile: "node.json")])
    let node = AgentNodePayload(id: "node", model: "fixture", agentEnvironment: ["API_KEY": .init(fromEnv: "RIELA_TEST_CAPTURED_ONLY", required: true)])
    let runner = DeterministicWorkflowRunner(adapter: adapter, runtimeEnvironment: ["RIELA_TEST_CAPTURED_ONLY": "captured-value"])
    let result = try await runner.run(.init(workflow: workflow, nodePayloads: ["node": node]))
    let captured = await adapter.environment
    XCTAssertEqual(captured, ["API_KEY": "captured-value"])
    XCTAssertFalse((String(data: try JSONEncoder().encode(result), encoding: .utf8) ?? "").contains("captured-value"))
  }

  func testExplicitAndAutomaticRequirementsUnionWithoutValues() throws {
    let workflow = WorkflowDefinition(workflowId: "environment", defaults: WorkflowDefaults(nodeTimeoutMs: 1000, maxLoopIterations: 2), entryStepId: "step",
      nodeRegistry: [.init(id: "node", nodeFile: "node.json", requiredEnvironment: ["REGISTRY_KEY"])],
      steps: [.init(id: "step", nodeId: "node")], nodes: [.init(id: "node", requiredEnvironment: ["COMMAND_KEY"])],
      requiredEnvironment: ["WORKFLOW_KEY"])
    let node = AgentNodePayload(id: "node", model: "fixture", agentEnvironment: ["API_KEY": .init(fromEnv: "SOURCE_KEY", required: true)],
      apiKeyEnvironment: "PROVIDER_KEY", requiredEnvironment: ["PAYLOAD_KEY"])
    let names = try WorkflowEnvironmentRequirements.names(workflow: workflow, nodePayloads: ["node": node])
    XCTAssertEqual(names, ["COMMAND_KEY", "PAYLOAD_KEY", "PROVIDER_KEY", "REGISTRY_KEY", "SOURCE_KEY", "WORKFLOW_KEY"])
    XCTAssertEqual(try WorkflowEnvironmentRequirements.names(workflow: workflow,
      nodePayloads: ["node": node], nodeIds: []), ["WORKFLOW_KEY"])
    let restored = try JSONDecoder().decode(WorkflowDefinition.self, from: JSONEncoder().encode(workflow))
    XCTAssertEqual(restored.requiredEnvironment, ["WORKFLOW_KEY"])
    XCTAssertEqual(restored.nodes[0].requiredEnvironment, ["COMMAND_KEY"])
    XCTAssertThrowsError(try WorkflowEnvironmentRequirements.validated(["INVALID=VALUE"]))
  }
}

private actor SnapshotEnvironmentAdapter: NodeAdapter {
  var environment: [String: String] = [:]
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    environment = input.agentEnvironment
    return AdapterExecutionOutput(provider: "fixture", model: "fixture", promptText: "", completionPassed: true, payload: [:])
  }
}
