import XCTest
@testable import RielaCore

final class PromptTooLargeRecoveryTests: XCTestCase {
  func testPromptTooLargeFailureCanBeRetriedWithoutLosingSessionHistory() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let initialRequest = request()
    let failingAdapter = FailingAdapter(error: AdapterExecutionError(.providerError, "Prompt is too long"))
    await XCTAssertThrowsErrorAsync(try await DeterministicWorkflowRunner(
      store: store, adapter: failingAdapter
    ).run(initialRequest))

    let maybeFailed = await store.latestSession(workflowId: "prompt-too-large-recovery")
    let failed = try XCTUnwrap(maybeFailed)
    XCTAssertEqual(failed.status, .failed)
    XCTAssertEqual(failed.failureKind, .promptTooLarge)
    XCTAssertEqual(failed.executions.count, 1)

    var resume = initialRequest
    resume.resumeSessionId = failed.sessionId
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: StaticAdapter(output: AdapterExecutionOutput(
        provider: "test", model: "test-model", promptText: "prompt", completionPassed: true,
        when: ["always": true], payload: ["status": .string("ok")]
      ))
    )
    let unchanged = try await runner.run(resume)
    XCTAssertEqual(unchanged.session.status, .failed)
    XCTAssertEqual(unchanged.session.executions.count, 1)

    resume.retryFailedStep = true
    let recovered = try await runner.run(resume)
    XCTAssertEqual(recovered.session.sessionId, failed.sessionId)
    XCTAssertEqual(recovered.session.status, .completed)
    XCTAssertEqual(recovered.session.executions.map(\.status), [.failed, .completed])
  }

  func testRetryValidationStillRejectsMaxStepsExceededWithUpdatedMessage() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = WorkflowDefinition(
      workflowId: "prompt-too-large-validation",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "first",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "first-node", nodeFile: "first.json"),
        WorkflowNodeRegistryRef(id: "second-node", nodeFile: "second.json")
      ],
      steps: [
        WorkflowStepRef(id: "first", nodeId: "first-node", transitions: [WorkflowStepTransition(toStepId: "second")]),
        WorkflowStepRef(id: "second", nodeId: "second-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "first-node", nodeFile: "first.json"),
        WorkflowNodeRef(id: "second-node", nodeFile: "second.json")
      ]
    )
    let initialRequest = DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "first-node": AgentNodePayload(id: "first-node", executionBackend: .codexAgent, model: "test-model", agentSandbox: .readOnly),
        "second-node": AgentNodePayload(id: "second-node", executionBackend: .codexAgent, model: "test-model", agentSandbox: .readOnly)
      ],
      maxSteps: 1
    )
    let output = AdapterExecutionOutput(
      provider: "test", model: "test-model", promptText: "prompt", completionPassed: true,
      when: ["always": true], payload: ["status": .string("ok")]
    )
    do {
      _ = try await DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: output)).run(initialRequest)
      XCTFail("expected maxStepsExceeded")
    } catch DeterministicWorkflowRunnerError.maxStepsExceeded(let maxSteps) {
      XCTAssertEqual(maxSteps, 1)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    let maybeFailed = await store.latestSession(workflowId: "prompt-too-large-validation")
    let failed = try XCTUnwrap(maybeFailed)
    XCTAssertEqual(failed.failureKind, .maxStepsExceeded)

    var resume = initialRequest
    resume.resumeSessionId = failed.sessionId
    resume.retryFailedStep = true
    do {
      _ = try await DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: output)).run(resume)
      XCTFail("expected retry validation failure")
    } catch let error as DeterministicWorkflowRunnerError {
      guard case let .resumeValidation(message) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("adapter-failed, prompt-too-large or policy-blocked"))
    }
  }

  private func request() -> DeterministicWorkflowRunRequest {
    let workflow = WorkflowDefinition(
      workflowId: "prompt-too-large-recovery",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "node.json")],
      steps: [WorkflowStepRef(id: "step", nodeId: "node")],
      nodes: [WorkflowNodeRef(id: "node", nodeFile: "node.json")]
    )
    let request = DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["node": AgentNodePayload(id: "node", executionBackend: .codexAgent, model: "test-model", agentSandbox: .readOnly)]
    )
    return request
  }
}
