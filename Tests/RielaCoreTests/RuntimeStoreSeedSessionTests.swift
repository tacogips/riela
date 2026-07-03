import XCTest
@testable import RielaCore

extension RuntimeStoreTests {
  func testSeedSessionOnlyDetachesRunningBackendLiveTails() async throws {
    let date = Date(timeIntervalSince1970: 100)
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(date))
    let completed = WorkflowStepExecution(
      executionId: "completed-exec",
      stepId: "done",
      nodeId: "node-done",
      attempt: 1,
      status: .completed,
      lastBackendEventAt: date,
      lastBackendEventType: "assistant.snapshot",
      backendEventCount: 1,
      streamedResponseText: "completed live tail",
      createdAt: date,
      updatedAt: date
    )
    let running = WorkflowStepExecution(
      executionId: "running-exec",
      stepId: "run",
      nodeId: "node-run",
      attempt: 1,
      status: .running,
      lastBackendEventAt: date,
      lastBackendEventType: "assistant.delta",
      backendEventCount: 1,
      streamedResponseText: "running live tail",
      createdAt: date,
      updatedAt: date
    )

    await store.seedSession(WorkflowSession(
      workflowId: "wf",
      sessionId: "seeded-session",
      status: .running,
      entryStepId: "done",
      currentStepId: "run",
      createdAt: date,
      updatedAt: date,
      executions: [completed, running]
    ))

    let liveTailCount = await store.executionLiveTailCountForTesting()
    XCTAssertEqual(liveTailCount, 1)
    let maybeLoaded = try await store.loadSession(id: "seeded-session")
    let loaded = try XCTUnwrap(maybeLoaded)
    XCTAssertEqual(loaded.executions.map(\.streamedResponseText), ["completed live tail", "running live tail"])
  }
}
