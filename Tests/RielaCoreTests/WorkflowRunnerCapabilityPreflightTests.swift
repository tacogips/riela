import XCTest
import RielaMemory
@testable import RielaCore

final class WorkflowRunnerCapabilityPreflightTests: XCTestCase {
  func testUnsupportedTransitionsFailPreflightBeforeSessionCreation() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let unsupportedTransitions: [(WorkflowStepTransition, String)] = [
      (
        WorkflowStepTransition(toStepId: "child", toWorkflowId: "child-workflow"),
        "step 'step' uses cross-workflow transitions, which this runner does not support yet"
      ),
      (
        WorkflowStepTransition(toStepId: "step", resumeStepId: "resume"),
        "step 'step' uses resume-step transitions, which this runner does not support yet"
      ),
      (
        WorkflowStepTransition(
          toStepId: "step",
          fanout: WorkflowStepFanout(groupId: "group", itemsFrom: "/items", joinStepId: "step")
        ),
        "step 'step' uses fanout transitions, which this runner does not support yet"
      )
    ]
    for (transition, message) in unsupportedTransitions {
      let workflow = workflow(transitions: [transition])
      let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: output()))

      do {
        _ = try await runner.run(request(workflow: workflow))
        XCTFail("expected preflight failure")
      } catch DeterministicWorkflowRunnerError.invalidWorkflow(let actualMessage) {
        XCTAssertTrue(actualMessage.contains(message), actualMessage)
      }
    }
    let latestSession = await store.latestSession(workflowId: "runner")
    XCTAssertNil(latestSession)
  }

  func testMaxConcurrencyFailsPreflightBeforeSessionCreation() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: output()))

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: workflow(),
        nodePayloads: ["node": payload()],
        maxConcurrency: 2
      ))
      XCTFail("expected preflight failure")
    } catch DeterministicWorkflowRunnerError.invalidWorkflow(let message) {
      XCTAssertEqual(
        message,
        "run.maxConcurrency: maxConcurrency is reserved for fanout execution and is not supported yet"
      )
    }
    let latestSession = await store.latestSession(workflowId: "runner")
    XCTAssertNil(latestSession)
  }

  private func request(workflow: WorkflowDefinition) -> DeterministicWorkflowRunRequest {
    DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["node": payload()]
    )
  }

  private func workflow(transitions: [WorkflowStepTransition]? = nil) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "step", nodeId: "node", transitions: transitions)],
      nodes: [WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json")]
    )
  }

  private func payload() -> AgentNodePayload {
    AgentNodePayload(id: "node", executionBackend: .codexAgent, model: "gpt-5.5")
  }

  private func output() -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: "test",
      model: "gpt-5.5",
      promptText: "prompt",
      completionPassed: true,
      payload: ["status": .string("ok")]
    )
  }
}
