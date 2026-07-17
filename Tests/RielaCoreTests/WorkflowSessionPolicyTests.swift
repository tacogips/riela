import XCTest
@testable import RielaCore

final class WorkflowSessionPolicyTests: XCTestCase {
  func testRawValidationRejectsInvalidSessionPolicyShapeAndInheritance() {
    let data = Data("""
      {
        "workflowId": "session-policy",
        "description": "Session policy validation",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "first",
        "nodes": [{ "id": "first", "nodeFile": "nodes/first.json" }],
        "steps": [{
          "id": "first",
          "nodeId": "first",
          "sessionPolicy": { "mode": "new", "inheritFromStepId": "missing" }
        }]
      }
      """.utf8)

    let result = validateAuthoredWorkflowData(data)

    XCTAssertNil(result.workflow)
    XCTAssertTrue(result.diagnostics.contains {
      $0.path == "workflow.steps[0].sessionPolicy.inheritFromStepId"
        && $0.message.contains("only when sessionPolicy.mode is 'reuse'")
    })
    XCTAssertTrue(result.diagnostics.contains {
      $0.path == "workflow.steps[0].sessionPolicy.inheritFromStepId"
        && $0.message.contains("same workflow")
    })
  }

  func testBundleValidationUsesNodePolicyAndStepPolicyPrecedence() {
    let workflow = makeWorkflow(stepPolicy: nil)
    let invalidNode = AgentNodePayload(
      id: "node",
      model: "model",
      sessionPolicy: WorkflowStepSessionPolicy(mode: .reuse, inheritFromStepId: "missing")
    )

    let nodeDiagnostics = DefaultWorkflowValidator().validate(workflow, nodePayloads: ["node": invalidNode])
    XCTAssertTrue(nodeDiagnostics.contains {
      $0.path == "workflow.steps.second.sessionPolicy.inheritFromStepId"
        && $0.message.contains("same workflow")
    })

    let overridingWorkflow = makeWorkflow(stepPolicy: WorkflowStepSessionPolicy(mode: .new))
    let overridingDiagnostics = DefaultWorkflowValidator().validate(
      overridingWorkflow,
      nodePayloads: ["node": invalidNode]
    )
    XCTAssertFalse(overridingDiagnostics.contains {
      $0.path == "workflow.steps.second.sessionPolicy.inheritFromStepId"
    })
  }

  func testBundleValidationAcceptsSameWorkflowReuseTargetEvenIfNotPreceding() {
    let workflow = makeWorkflow(
      stepPolicy: WorkflowStepSessionPolicy(mode: .reuse, inheritFromStepId: "first")
    )

    let diagnostics = DefaultWorkflowValidator().validate(workflow, nodePayloads: [:])

    XCTAssertFalse(diagnostics.contains { $0.path.contains("sessionPolicy") })
  }

  func testRunnerProvidesTypedIdentityAndCleansUpRootRunExactlyOnce() async throws {
    let adapter = LifecycleCapturingAdapter()
    let workflow = makeSingleStepWorkflow()
    let node = AgentNodePayload(
      id: "node",
      executionBackend: .codexAgent,
      model: "model",
      promptTemplate: "ordinary",
      sessionStartPromptTemplate: "session start"
    )
    let runner = DeterministicWorkflowRunner(adapter: adapter)

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["node": node]
    ))

    let capturedInput = await adapter.capturedInput()
    let captured = try XCTUnwrap(capturedInput)
    XCTAssertEqual(captured.executionIdentity?.workflowRunId, result.session.sessionId)
    XCTAssertEqual(captured.executionIdentity?.workflowSessionId, result.session.sessionId)
    XCTAssertEqual(captured.executionIdentity?.stepId, "only")
    XCTAssertEqual(captured.freshPromptText, "session start\n\nordinary")
    XCTAssertEqual(captured.resumedPromptText, "ordinary")
    let lifecycleContexts = await adapter.capturedLifecycleContexts()
    XCTAssertEqual(lifecycleContexts, [WorkflowRunLifecycleContext(workflowRunId: result.session.sessionId)])
  }

  private func makeWorkflow(stepPolicy: WorkflowStepSessionPolicy?) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "session-policy",
      description: "Session policy validation",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "first",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [
        WorkflowStepRef(id: "first", nodeId: "node"),
        WorkflowStepRef(id: "second", nodeId: "node", sessionPolicy: stepPolicy)
      ],
      nodes: [WorkflowNodeRef(id: "node", nodeFile: "nodes/node.json")]
    )
  }

  private func makeSingleStepWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "session-lifecycle",
      description: "Lifecycle validation",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "only",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "only", nodeId: "node")],
      nodes: [WorkflowNodeRef(id: "node", nodeFile: "nodes/node.json")]
    )
  }
}

private actor LifecycleCapturingAdapter: NodeAdapter {
  private var input: AdapterExecutionInput?
  private var lifecycleContexts: [WorkflowRunLifecycleContext] = []

  func execute(
    _ input: AdapterExecutionInput,
    context _: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    self.input = input
    return AdapterExecutionOutput(
      provider: "test",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["text": .string("done")]
    )
  }

  func workflowRunDidEnd(_ context: WorkflowRunLifecycleContext) async {
    lifecycleContexts.append(context)
  }

  func capturedInput() -> AdapterExecutionInput? {
    input
  }

  func capturedLifecycleContexts() -> [WorkflowRunLifecycleContext] {
    lifecycleContexts
  }
}
