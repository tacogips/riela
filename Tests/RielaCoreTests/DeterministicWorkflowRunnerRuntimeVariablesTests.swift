import XCTest
@testable import RielaCore

final class RuntimeVariablesPromptingTests: XCTestCase {
  func testRequestVariablesAreExposedAsRuntimeVariablesInWorkerPromptContext() async throws {
    let adapter = InputCapturingAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "runtime-variable-runner",
      description: "runtime variable test",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      prompts: WorkflowPrompts(workerSystemPromptTemplate: "workflow system"),
      entryStepId: "echo",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "echo-node", nodeFile: "nodes/echo.json")],
      steps: [WorkflowStepRef(id: "echo", nodeId: "echo-node", role: .worker)],
      nodes: [WorkflowNodeRef(id: "echo", nodeFile: "nodes/echo.json")]
    )
    let node = AgentNodePayload(
      id: "echo-node",
      executionBackend: .codexAgent,
      model: "gpt-5.5",
      promptTemplate: "requested={{runtimeVariables.workflowInput.requestedBehavior}}"
    )
    let runtimeVariables: JSONObject = [
      "workflowInput": .object([
        "requestedBehavior": .string("sentinel-from-cli"),
        "templateLikeValue": .string("{{must-remain-literal}}")
      ]),
      "workflowCall": .object([
        "input": .object([
          "workflowInput": .object([
            "requestedBehavior": .string("sentinel-from-call")
          ])
        ])
      ])
    ]
    let runner = DeterministicWorkflowRunner(adapter: adapter)

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["echo-node": node],
      variables: runtimeVariables
    ))

    let capturedInput = await adapter.capturedInput()
    let input = try XCTUnwrap(capturedInput)
    XCTAssertEqual(input.mergedVariables["runtimeVariables"], .object(runtimeVariables))
    XCTAssertEqual(input.promptText, "requested=sentinel-from-cli")
    let systemPromptText = try XCTUnwrap(input.systemPromptText)
    XCTAssertTrue(systemPromptText.contains("Runtime variables are available under `runtimeVariables`."))
    XCTAssertTrue(systemPromptText.contains(#""requestedBehavior":"sentinel-from-cli""#))
    XCTAssertTrue(systemPromptText.contains(#""templateLikeValue":"{{must-remain-literal}}""#))
    XCTAssertTrue(systemPromptText.contains(#""requestedBehavior":"sentinel-from-call""#))
  }
}
