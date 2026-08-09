import XCTest
import RielaMemory
@testable import RielaCore

extension DeterministicWorkflowRunnerTests {
  func testAdapterFailureRecordsFailedExecutionWithoutMessages() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let recorder = WorkflowRunEventRecorder()
    let runner = DeterministicWorkflowRunner(store: store, adapter: FailingAdapter())

    await XCTAssertThrowsErrorAsync(try await runner.run(request(eventHandler: { event in
      await recorder.append(event)
    })))

    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.failureKind, .adapterFailure)
    XCTAssertEqual(session.failureReason, "provider_error: forced failure")
    XCTAssertEqual(session.executions.count, 1)
    XCTAssertEqual(session.executions.first?.status, .failed)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
    let events = await recorder.events()
    XCTAssertEqual(events.last?.type, .sessionCompleted)
    XCTAssertEqual(events.last?.status, .failed)
  }

  func testInvalidInputAdapterFailureIsNotPolicyBlocked() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: FailingAdapter(error: AdapterExecutionError(.invalidInput, "missing bodyMarkdown"))
    )

    await XCTAssertThrowsErrorAsync(try await runner.run(request()))

    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.failureKind, .adapterFailure)
    XCTAssertEqual(session.failureReason, "invalid_input: missing bodyMarkdown")
  }

  func testCancellationMarksRunningSessionFailedAndEmitsTerminalEvent() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let recorder = WorkflowRunEventRecorder()
    let runner = DeterministicWorkflowRunner(store: store, adapter: CancellingAdapter())

    do {
      _ = try await runner.run(request(eventHandler: { event in
        await recorder.append(event)
      }))
      XCTFail("expected cancellation")
    } catch is CancellationError {} catch {
      XCTFail("expected cancellation, got \(error)")
    }

    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.failureKind, .cancelled)
    XCTAssertEqual(session.executions.count, 1)
    XCTAssertEqual(session.executions.first?.status, .failed)
    XCTAssertEqual(session.executions.first?.failureReason, "workflow run cancelled")
    let events = await recorder.events()
    XCTAssertEqual(events.last?.type, .sessionCompleted)
    XCTAssertEqual(events.last?.status, .failed)
  }

  func testCancellationAfterTransitionMarksSessionFailedWithoutRunningExecution() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let recorder = WorkflowRunEventRecorder()
    let workflow = twoStepWorkflow()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: StaticAdapter(output: output()),
      inputResolver: StepCancellingInputResolver(cancelledStepId: "step-b")
    )

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: workflow,
        nodePayloads: nodePayloads(for: workflow),
        eventHandler: { event in
          await recorder.append(event)
        }
      ))
      XCTFail("expected cancellation")
    } catch is CancellationError {} catch {
      XCTFail("expected cancellation, got \(error)")
    }

    let maybeSession = await store.loadSessionForTest(id: "rerun-runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.failureKind, .cancelled)
    XCTAssertEqual(session.executions.count, 1)
    XCTAssertEqual(session.executions.first?.status, .completed)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages.map(\.toStepId), ["step-b"])
    let events = await recorder.events()
    XCTAssertEqual(events.last?.type, .sessionCompleted)
    XCTAssertEqual(events.last?.status, .failed)
  }

  func testCompletionFailureRecordsFailedExecutionWithoutMessages() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: StaticAdapter(output: output(completionPassed: false, payload: ["status": .string("blocked")]))
    )

    await XCTAssertThrowsErrorAsync(try await runner.run(request()))

    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.first?.status, .failed)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }

  func testInvalidOutputContractRecordsFailedExecutionWithoutMessages() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let node = payload(
      output: NodeOutputContract(
        jsonSchema: [
          "type": .string("object"),
          "required": .array([.string("status")])
        ]
      )
    )
    let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: output(payload: ["other": .string("value")])))

    await XCTAssertThrowsErrorAsync(try await runner.run(request(nodePayload: node)))

    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.first?.status, .failed)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }

  func testMultiplePublishableTransitionsFailClosedWithoutMessages() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = WorkflowDefinition(
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
    let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: output()))

    await XCTAssertThrowsErrorAsync(try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "node": payload(),
        "left-node": payload(),
        "right-node": payload()
      ]
    )))

    let maybeSession = await store.loadSessionForTest(id: "runner-session-1")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.count, 1)
    XCTAssertEqual(session.executions.first?.status, .failed)
    XCTAssertEqual(session.executions.first?.failureReason, "invalid_output: multiple direct transitions are not supported by this sequential runner")
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
  }
}
