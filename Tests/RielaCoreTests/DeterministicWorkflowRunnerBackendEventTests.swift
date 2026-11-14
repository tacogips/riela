import XCTest
@testable import RielaCore

extension DeterministicWorkflowRunnerTests {
  func testBackendEventHandlerUpdatesRunningExecutionHeartbeatAndEmitsRunEvent() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let recorder = WorkflowRunEventRecorder()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: BackendEventEmittingAdapter(eventType: "turn.started")
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: backendEventWorkflow(),
      nodePayloads: ["node": backendEventPayload()],
      eventHandler: { event in
        await recorder.append(event)
      }
    ))

    let execution = try XCTUnwrap(result.session.executions.first)
    XCTAssertEqual(execution.lastBackendEventType, "turn.started")
    XCTAssertNotNil(execution.lastBackendEventAt)
    let events = await recorder.events()
    XCTAssertTrue(events.contains { event in
      event.type == .backendEvent &&
        event.executionId == execution.executionId &&
        event.backendEventType == "turn.started"
    })
  }

  private func backendEventWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "step", nodeId: "node")],
      nodes: [WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json")]
    )
  }

  private func backendEventPayload() -> AgentNodePayload {
    AgentNodePayload(id: "node", executionBackend: .codexAgent, model: "gpt-5.5")
  }
}
