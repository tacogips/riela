import XCTest
@testable import RielaCore

final class RuntimeVariablesPromptingTests: XCTestCase {
  func testRequestVariablesAreExposedAsRuntimeVariablesInWorkerPromptContext() async throws {
    let adapter = InputCapturingAdapter()
    let workflow = runtimeVariablesWorkflow(
      workflowId: "runtime-variable-runner",
      nodeId: "echo-node",
      stepId: "echo",
      systemPromptTemplate: "workflow system"
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
    guard case let .object(projectedRuntimeVariables)? = input.mergedVariables["runtimeVariables"] else {
      return XCTFail("runtimeVariables should be projected as an object")
    }
    XCTAssertEqual(projectedRuntimeVariables["workflowInput"], runtimeVariables["workflowInput"])
    XCTAssertEqual(projectedRuntimeVariables["workflowCall"], runtimeVariables["workflowCall"])
    XCTAssertEqual(input.promptText, "requested=sentinel-from-cli")
    let systemPromptText = try XCTUnwrap(input.systemPromptText)
    XCTAssertTrue(systemPromptText.contains("Runtime variables are available under `runtimeVariables`."))
    XCTAssertTrue(systemPromptText.contains(#""requestedBehavior":"sentinel-from-cli""#))
    XCTAssertTrue(systemPromptText.contains(#""templateLikeValue":"{{must-remain-literal}}""#))
    XCTAssertTrue(systemPromptText.contains(#""requestedBehavior":"sentinel-from-call""#))
  }

  func testPromptVariablesExposeDirectAndCrossWorkflowInputPaths() async throws {
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
      workflow: runtimeVariablesWorkflow(workflowId: "runtime-variables", nodeId: "worker", stepId: "worker"),
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

  private func runtimeVariablesWorkflow(
    workflowId: String,
    nodeId: String,
    stepId: String,
    systemPromptTemplate: String? = nil
  ) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: workflowId,
      description: "runtime variables test",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      prompts: systemPromptTemplate.map { WorkflowPrompts(workerSystemPromptTemplate: $0) },
      entryStepId: stepId,
      nodeRegistry: [WorkflowNodeRegistryRef(id: nodeId, nodeFile: "nodes/\(nodeId).json")],
      steps: [
        WorkflowStepRef(id: stepId, nodeId: nodeId, role: .worker)
      ],
      nodes: [WorkflowNodeRef(id: stepId, nodeFile: "nodes/\(nodeId).json")]
    )
  }
}
