import Foundation
import RielaCore
import XCTest

final class WorkflowAddonResolvedInputPayloadTests: XCTestCase {
  func testAddonInputIncludesPriorAcceptedOutputs() async throws {
    let resolver = CapturingResolvedInputAddonResolver()
    let runner = DeterministicWorkflowRunner(
      adapter: StaticResolvedInputAdapter(),
      addonResolver: resolver
    )

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: addonAfterWorkerWorkflow(),
      nodePayloads: [
        "worker-node": AgentNodePayload(id: "worker-node", executionBackend: .codexAgent, model: "gpt-5-nano")
      ]
    ))

    let maybeCaptured = await resolver.capturedInput()
    let captured = try XCTUnwrap(maybeCaptured)
    let upstream = try decodedResolvedOutputs(from: captured.resolvedInputPayload["upstream"])
    let firstOutput = try XCTUnwrap(upstream.first)
    XCTAssertEqual(firstOutput.stepId, "worker-step")
    XCTAssertEqual(firstOutput.nodeId, "worker-node")
    XCTAssertEqual(firstOutput.output.payload["status"], .string("ok"))
    XCTAssertNil(captured.resolvedInputPayload["latestOutputs"])
  }

  private func addonAfterWorkerWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "addon-after-worker",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "worker-step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "worker-node", nodeFile: "nodes/worker.json"),
        WorkflowNodeRegistryRef(
          id: "addon-node",
          addon: WorkflowNodeAddonRef(name: "riela/native-runner", version: "1.0.0")
        )
      ],
      steps: [
        WorkflowStepRef(
          id: "worker-step",
          nodeId: "worker-node",
          transitions: [WorkflowStepTransition(toStepId: "addon-step")]
        ),
        WorkflowStepRef(id: "addon-step", nodeId: "addon-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "worker-node", nodeFile: "nodes/worker.json"),
        WorkflowNodeRef(
          id: "addon-node",
          addon: WorkflowNodeAddonRef(name: "riela/native-runner", version: "1.0.0")
        )
      ]
    )
  }
}

private struct StaticResolvedInputAdapter: NodeAdapter {
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: "test",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["status": .string("ok")]
    )
  }
}

private actor CapturingResolvedInputAddonResolver: WorkflowAddonResolving {
  private var input: WorkflowAddonExecutionInput?

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    self.input = input
    return AdapterExecutionOutput(
      provider: "test",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      payload: ["status": .string("addon-ok")]
    )
  }

  func capturedInput() -> WorkflowAddonExecutionInput? {
    input
  }
}

private struct ResolvedOutputEntry: Decodable, Equatable {
  let stepId: String
  let nodeId: String
  let executionId: String
  let output: ResolvedNodeOutput
  let payload: JSONObject
  let when: JSONObject
}

private struct ResolvedNodeOutput: Decodable, Equatable {
  let payload: JSONObject
  let when: JSONObject
  let isRootOutput: Bool
}

private func decodedResolvedOutputs(from value: JSONValue?) throws -> [ResolvedOutputEntry] {
  let value = try XCTUnwrap(value)
  let data = try JSONEncoder().encode(value)
  return try JSONDecoder().decode([ResolvedOutputEntry].self, from: data)
}
