import XCTest
@testable import RielaCore

final class WorkflowRunnerAdmissionTests: XCTestCase {
  func testSessionExecutionAdmissionRejectsBeforeNodeEffect() async throws {
    struct Rejected: Error {}
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = WorkflowDefinition(
      workflowId: "admission-runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "step", nodeId: "node")],
      nodes: [WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json")]
    )
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: StaticAdapter(output: AdapterExecutionOutput(
        provider: "test",
        model: "test",
        promptText: "test",
        completionPassed: true,
        payload: ["status": .string("ok")]
      ))
    )

    await XCTAssertThrowsErrorAsync(try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "node": AgentNodePayload(id: "node", executionBackend: .codexAgent, model: "test")
      ],
      sessionExecutionAdmission: { _ in throw Rejected() }
    )))

    let persistedSession = await store.loadSessionForTest(id: "admission-runner-session-1")
    let session = try XCTUnwrap(persistedSession)
    XCTAssertEqual(session.status, .created)
    XCTAssertTrue(session.executions.isEmpty)
  }
}
