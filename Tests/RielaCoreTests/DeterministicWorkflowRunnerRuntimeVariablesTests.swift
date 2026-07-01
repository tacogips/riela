import XCTest
@testable import RielaCore

final class WorkflowRuntimeVariablesTests: XCTestCase {
  func testPromptVariablesExposeRuntimeVariablesAliasForWorkflowRunInput() async throws {
    let adapter = InputCapturingAdapter()
    let runner = DeterministicWorkflowRunner(adapter: adapter)
    let workflowInput: JSONObject = [
      "executionMode": .string("review-and-improve-existing-work"),
      "targetFeatureArea": .string("Instances performance"),
      "requestedBehavior": .string("Review and improve list scrolling"),
      "codexAgentReferences": .array([.string("Sources/RielaApp/EntryPoint.swift")])
    ]
    let workflowCallInput: JSONObject = [
      "workflowInput": .object([
        "requestedBehavior": .string("Prefer cross-workflow behavior"),
        "targetFeatureArea": .string("Cross workflow area")
      ])
    ]

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: runtimeVariablesWorkflow(),
      nodePayloads: [
        "worker": AgentNodePayload(
          id: "worker",
          executionBackend: .codexAgent,
          model: "gpt-5.5",
          promptTemplate: """
          Direct requested behavior: {{runtimeVariables.workflowInput.requestedBehavior}}
          Direct target: {{runtimeVariables.workflowInput.targetFeatureArea}}
          Cross-workflow requested behavior: {{runtimeVariables.workflowCall.input.workflowInput.requestedBehavior}}
          Top-level compatibility target: {{workflowInput.targetFeatureArea}}
          """
        )
      ],
      variables: [
        "workflowInput": .object(workflowInput),
        "workflowCall": .object(["input": .object(workflowCallInput)])
      ]
    ))

    let capturedInput = await adapter.capturedInput()
    let input = try XCTUnwrap(capturedInput)
    XCTAssertTrue(input.promptText.contains("Direct requested behavior: Review and improve list scrolling"))
    XCTAssertTrue(input.promptText.contains("Direct target: Instances performance"))
    XCTAssertTrue(input.promptText.contains("Cross-workflow requested behavior: Prefer cross-workflow behavior"))
    XCTAssertTrue(input.promptText.contains("Top-level compatibility target: Instances performance"))
    guard case let .object(runtimeVariables)? = input.mergedVariables["runtimeVariables"] else {
      return XCTFail("runtimeVariables should be projected as an object")
    }
    XCTAssertEqual(runtimeVariables["workflowInput"], .object(workflowInput))
    XCTAssertEqual(runtimeVariables["workflowCall"], .object(["input": .object(workflowCallInput)]))
  }

  private func runtimeVariablesWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "runtime-variables",
      description: "runtime variables test",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "worker",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "worker", nodeFile: "nodes/worker.json")],
      steps: [
        WorkflowStepRef(id: "worker", nodeId: "worker", role: .worker)
      ],
      nodes: [WorkflowNodeRef(id: "worker", nodeFile: "nodes/worker.json")]
    )
  }
}
