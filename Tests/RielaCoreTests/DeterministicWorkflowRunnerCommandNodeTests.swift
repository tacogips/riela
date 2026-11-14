import XCTest
@testable import RielaCore

extension DeterministicWorkflowRunnerTests {
  func testCommandNodePublishesValidStdoutOutputThroughRuntimeStore() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let executor = StaticStdioNodeExecutor(result: WorkflowStdioNodeExecutionResult(payload: ["status": .string("ok")]))
    let runner = DeterministicWorkflowRunner(store: store, stdioNodeExecutor: executor)
    let result = try await runner.run(request(nodePayload: commandPayload()))

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.rootOutput, ["status": .string("ok")])
    let capturedInputs = await executor.capturedInputs()
    let capturedInput = try XCTUnwrap(capturedInputs.first)
    XCTAssertEqual(capturedInput.workflowId, "runner")
    XCTAssertEqual(capturedInput.stepId, "step")
    XCTAssertEqual(capturedInput.kind, .command)
    let loadedSession = await store.loadSessionForTest(id: result.session.sessionId)
    let session = try XCTUnwrap(loadedSession)
    XCTAssertEqual(session.executions.first?.acceptedOutput?.payload, ["status": .string("ok")])
  }

  func testCommandNodeEmptyStdoutCompletesWithoutAcceptedOutput() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(
      store: store,
      stdioNodeExecutor: StaticStdioNodeExecutor(result: WorkflowStdioNodeExecutionResult(payload: nil))
    )
    let result = try await runner.run(request(nodePayload: commandPayload()))

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertNil(result.rootOutput)
    let loadedSession = await store.loadSessionForTest(id: result.session.sessionId)
    let session = try XCTUnwrap(loadedSession)
    XCTAssertEqual(session.status, .completed)
    XCTAssertEqual(session.executions.first?.status, .completed)
    XCTAssertNil(session.executions.first?.acceptedOutput)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }

  func testCommandNodeInvalidStdoutRecordsFailedExecution() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(
      store: store,
      stdioNodeExecutor: StaticStdioNodeExecutor(error: AdapterExecutionError(.invalidOutput, "stdout invalid JSONL"))
    )

    await XCTAssertThrowsErrorAsync(try await runner.run(request(nodePayload: commandPayload())))

    let loadedSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(loadedSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.first?.status, .failed)
    XCTAssertEqual(session.executions.first?.failureReason, "invalid_output: stdout invalid JSONL")
  }

  func testCommandNodeMultiplePublishableTransitionsFailClosed() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = commandTransitionWorkflow()
    let runner = DeterministicWorkflowRunner(
      store: store,
      stdioNodeExecutor: StaticStdioNodeExecutor(result: WorkflowStdioNodeExecutionResult(payload: ["status": .string("ok")]))
    )

    await XCTAssertThrowsErrorAsync(try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["node": commandPayload()]
    )))

    let loadedSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(loadedSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(
      session.executions.first?.failureReason,
      "invalid_output: multiple direct transitions are not supported by this sequential runner"
    )
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }

  private func commandTransitionWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json"),
        WorkflowNodeRegistryRef(id: "left-node", nodeFile: "nodes/left-node.json"),
        WorkflowNodeRegistryRef(id: "right-node", nodeFile: "nodes/right-node.json")
      ],
      steps: [
        WorkflowStepRef(
          id: "step",
          nodeId: "node",
          transitions: [
            WorkflowStepTransition(toStepId: "left"),
            WorkflowStepTransition(toStepId: "right")
          ]
        ),
        WorkflowStepRef(id: "left", nodeId: "left-node"),
        WorkflowStepRef(id: "right", nodeId: "right-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json"),
        WorkflowNodeRef(id: "left", nodeFile: "nodes/left-node.json"),
        WorkflowNodeRef(id: "right", nodeFile: "nodes/right-node.json")
      ]
    )
  }
}
