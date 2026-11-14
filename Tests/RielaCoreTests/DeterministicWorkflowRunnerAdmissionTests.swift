import XCTest
@testable import RielaCore

final class WorkflowRunnerAdmissionTests: XCTestCase {
  func testSessionExecutionAdmissionRejectsBeforeNodeEffect() async throws {
    struct Rejected: Error {}
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = AdmissionCountingAdapter()
    let admission = AdmissionCallbackProbe()
    let workflow = WorkflowDefinition(
      workflowId: "admission-runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "step", nodeId: "node")],
      nodes: [WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json")]
    )
    let runner = DeterministicWorkflowRunner(store: store, adapter: adapter)

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: workflow,
        nodePayloads: [
          "node": AgentNodePayload(
            id: "node", executionBackend: .codexAgent, model: "test", agentSandbox: .readOnly
          )
        ],
        sessionExecutionAdmission: { _ in admission.record(); throw Rejected() }
      ))
      XCTFail("admission must reject the run")
    } catch is Rejected {
      XCTAssertEqual(admission.count, 1)
    }

    let persistedSession = await store.loadSessionForTest(id: "admission-runner-session-1")
    let session = try XCTUnwrap(persistedSession)
    XCTAssertEqual(session.status, .created)
    XCTAssertTrue(session.executions.isEmpty)
    let executedBeforeControl = await adapter.executionCount
    XCTAssertEqual(executedBeforeControl, 0)

    let invalidStore = InMemoryWorkflowRuntimeStore()
    let invalidAdmission = AdmissionCallbackProbe()
    let invalidRunner = DeterministicWorkflowRunner(store: invalidStore, adapter: adapter)
    do {
      _ = try await invalidRunner.run(DeterministicWorkflowRunRequest(
        workflow: workflow,
        nodePayloads: [
          "node": AgentNodePayload(id: "node", executionBackend: .codexAgent, model: "test")
        ],
        sessionExecutionAdmission: { _ in invalidAdmission.record(); throw Rejected() }
      ))
      XCTFail("missing sandbox must fail validation")
    } catch is Rejected {
      XCTFail("invalid payload reached admission")
    } catch {
      XCTAssertTrue(String(describing: error).contains("agentSandbox"))
    }
    XCTAssertEqual(invalidAdmission.count, 0)
    let invalidSession = await invalidStore.loadSessionForTest(id: "admission-runner-session-1")
    XCTAssertNil(invalidSession)
    let executedAfterControl = await adapter.executionCount
    XCTAssertEqual(executedAfterControl, 0)
  }
}

private final class AdmissionCallbackProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func record() { lock.withLock { value += 1 } }
  var count: Int { lock.withLock { value } }
}

private actor AdmissionCountingAdapter: NodeAdapter {
  private(set) var executionCount = 0

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    executionCount += 1
    throw AdapterExecutionError(.providerError, "adapter must not run")
  }
}
