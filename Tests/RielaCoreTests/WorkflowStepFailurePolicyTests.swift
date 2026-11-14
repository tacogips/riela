import XCTest
@testable import RielaCore

final class WorkflowStepFailurePolicyTests: XCTestCase {
  func testValidationAcceptsAdvisoryWorkerWithTransition() throws {
    let result = validateAuthoredWorkflowData(workflowData(
      failurePolicy: "advisory",
      includesTransition: true
    ))

    XCTAssertEqual(result.diagnostics.filter { $0.severity == .error }, [])
    XCTAssertEqual(result.workflow?.steps.first?.failurePolicy, .advisory)
  }

  func testValidationRejectsUnknownFailurePolicy() {
    let result = validateAuthoredWorkflowData(workflowData(
      failurePolicy: "ignore",
      includesTransition: true
    ))

    XCTAssertTrue(result.diagnostics.contains {
      $0.path == "workflow.steps[0].failurePolicy" &&
        $0.message == "must be 'fail' or 'advisory' when provided"
    })
  }

  func testValidationRejectsAdvisoryTerminalStep() {
    let result = validateAuthoredWorkflowData(workflowData(
      failurePolicy: "advisory",
      includesTransition: false
    ))

    XCTAssertTrue(result.diagnostics.contains {
      $0.path == "workflow.steps[0].failurePolicy" &&
        $0.message.contains("terminal steps cannot skip their output")
    })
  }

  func testValidationRejectsAdvisoryManagerStep() {
    let result = validateAuthoredWorkflowData(workflowData(
      failurePolicy: "advisory",
      includesTransition: true,
      role: "manager"
    ))

    XCTAssertTrue(result.diagnostics.contains {
      $0.path == "workflow.steps[0].failurePolicy" &&
        $0.message == "'advisory' is not supported on the manager step"
    })
  }

  private func workflowData(
    failurePolicy: String,
    includesTransition: Bool,
    role: String = "worker"
  ) -> Data {
    let transitions = includesTransition ? #","transitions":[{"toStepId":"done"}]"# : ""
    return Data("""
      {
        "workflowId": "failure-policy",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "advisory",
        "nodes": [
          { "id": "advisory-node", "nodeFile": "nodes/advisory.json" },
          { "id": "done-node", "nodeFile": "nodes/done.json" }
        ],
        "steps": [
          {
            "id": "advisory",
            "nodeId": "advisory-node",
            "role": "\(role)",
            "failurePolicy": "\(failurePolicy)"
            \(transitions)
          },
          { "id": "done", "nodeId": "done-node", "role": "worker" }
        ]
      }
      """.utf8)
  }
}

private actor FailurePolicyAdapter: NodeAdapter {
  let failure: AdapterExecutionError
  private var executedNodeIds: [String] = []

  init(failure: AdapterExecutionError) {
    self.failure = failure
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    executedNodeIds.append(input.node.id)
    if input.node.id == "advisory" {
      throw failure
    }
    return AdapterExecutionOutput(
      provider: "test",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["status": .string("done")]
    )
  }

  func executedNodes() -> [String] {
    executedNodeIds
  }
}

final class RunnerFailurePolicyTests: XCTestCase {
  func testAdvisoryAdapterFailureRecordsFailureAndRunsNextStep() async throws {
    let adapter = FailurePolicyAdapter(
      failure: AdapterExecutionError(.providerError, "advisory backend failed")
    )
    let result = try await runner(adapter: adapter).run(request(failurePolicy: .advisory))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.transitions, 1)
    let executedNodes = await adapter.executedNodes()
    XCTAssertEqual(executedNodes, ["advisory", "done"])
    XCTAssertEqual(result.session.executions.map(\.status), [.failed, .completed])
    XCTAssertEqual(
      result.session.executions.first?.failureReason,
      "provider_error: advisory backend failed"
    )
    XCTAssertNil(result.session.executions.first?.acceptedOutput)
  }

  func testDefaultFailurePolicyStillFailsSession() async throws {
    let adapter = FailurePolicyAdapter(
      failure: AdapterExecutionError(.providerError, "blocking backend failed")
    )

    await XCTAssertThrowsErrorAsync(try await runner(adapter: adapter).run(request(failurePolicy: nil)))

    let executedNodes = await adapter.executedNodes()
    XCTAssertEqual(executedNodes, ["advisory"])
  }

  func testAdvisoryTimeoutFailureUsesSameNonBlockingPath() async throws {
    let adapter = FailurePolicyAdapter(
      failure: AdapterExecutionError(.timeout, "step deadline exceeded")
    )
    let result = try await runner(adapter: adapter).run(request(failurePolicy: .advisory))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.session.executions.first?.status, .failed)
    XCTAssertEqual(result.session.executions.first?.failureReason, "timeout: step deadline exceeded")
    let executedNodes = await adapter.executedNodes()
    XCTAssertEqual(executedNodes, ["advisory", "done"])
  }

  func testAdvisoryPolicyDoesNotSwallowCancellation() async {
    let runner = DeterministicWorkflowRunner(adapter: CancellingAdapter())

    do {
      _ = try await runner.run(request(failurePolicy: .advisory))
      XCTFail("expected cancellation")
    } catch is CancellationError {
      // Expected: advisory applies only to adapter failures.
    } catch {
      XCTFail("expected CancellationError, got \(error)")
    }
  }

  private func runner(
    adapter: FailurePolicyAdapter
  ) -> DeterministicWorkflowRunner {
    DeterministicWorkflowRunner(
      adapter: adapter
    )
  }

  private func request(
    failurePolicy: WorkflowStepFailurePolicy? = .advisory
  ) -> DeterministicWorkflowRunRequest {
    DeterministicWorkflowRunRequest(
      workflow: WorkflowDefinition(
        workflowId: "advisory-runner",
        defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
        entryStepId: "advisory",
        nodeRegistry: [
          WorkflowNodeRegistryRef(id: "advisory-node", nodeFile: "nodes/advisory.json"),
          WorkflowNodeRegistryRef(id: "done-node", nodeFile: "nodes/done.json")
        ],
        steps: [
          WorkflowStepRef(
            id: "advisory",
            nodeId: "advisory-node",
            failurePolicy: failurePolicy,
            transitions: [WorkflowStepTransition(toStepId: "done")]
          ),
          WorkflowStepRef(id: "done", nodeId: "done-node")
        ],
        nodes: [
          WorkflowNodeRef(id: "advisory-node", nodeFile: "nodes/advisory.json"),
          WorkflowNodeRef(id: "done-node", nodeFile: "nodes/done.json")
        ]
      ),
      nodePayloads: [
        "advisory-node": AgentNodePayload(
          id: "advisory-node",
          executionBackend: .codexAgent,
          model: "gpt-5.5"
        ),
        "done-node": AgentNodePayload(
          id: "done-node",
          executionBackend: .codexAgent,
          model: "gpt-5.5"
        )
      ]
    )
  }
}
