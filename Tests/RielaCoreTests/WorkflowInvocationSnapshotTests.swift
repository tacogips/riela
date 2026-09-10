import XCTest
@testable import RielaCore

final class WorkflowInvocationSnapshotTests: XCTestCase {
  func testRunnerCapturesActualRenderedInputAndAcceptedOutput() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = WorkflowDefinition(
      workflowId: "snapshot", defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3), entryStepId: "work",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "node.json")],
      steps: [WorkflowStepRef(id: "work", nodeId: "node")],
      nodes: [WorkflowNodeRef(id: "node", nodeFile: "node.json")]
    )
    let result = try await DeterministicWorkflowRunner(store: store, adapter: DeterministicLocalNodeAdapter()).run(
      DeterministicWorkflowRunRequest(
        workflow: workflow,
        nodePayloads: ["node": AgentNodePayload(id: "node", model: "local", promptTemplate: "Hello {{name}}")],
        variables: ["name": .string("Riela")]
      )
    )
    let execution = try XCTUnwrap(result.session.executions.first)
    XCTAssertEqual(execution.inputSnapshot?["promptText"], .string("Hello Riela"))
    XCTAssertEqual(execution.inputSnapshot?["arguments"], .object(["name": .string("Riela")]))
    XCTAssertNotNil(execution.acceptedOutput)
    let encoded = try JSONEncoder().encode(execution)
    XCTAssertEqual(try JSONDecoder().decode(WorkflowStepExecution.self, from: encoded).inputSnapshot, execution.inputSnapshot)
  }

  func testFailureRetainsDistinctAttemptInputsAndOlderRecordsDecode() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "snapshot", entryStepId: "work"))
    let first = try await store.recordStepExecution(WorkflowStepExecutionRecordInput(
      sessionId: session.sessionId, stepId: "work", nodeId: "node", attempt: 1, inputSnapshot: ["actual": .string("first")]
    ))
    _ = try await store.updateStepExecution(WorkflowStepExecutionUpdateInput(
      sessionId: session.sessionId, executionId: first.executionId, status: .failed, failureReason: "provider failed"
    ))
    _ = try await store.recordStepExecution(WorkflowStepExecutionRecordInput(
      sessionId: session.sessionId, stepId: "work", nodeId: "node", attempt: 2, inputSnapshot: ["actual": .string("second")]
    ))
    let loaded = try await store.loadSession(id: session.sessionId)
    XCTAssertEqual(loaded?.executions.map { $0.inputSnapshot?["actual"] }, [.string("first"), .string("second")])
    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
    legacy.removeValue(forKey: "inputSnapshot")
    let decoded = try JSONDecoder().decode(WorkflowStepExecution.self, from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertNil(decoded.inputSnapshot)
  }
}
