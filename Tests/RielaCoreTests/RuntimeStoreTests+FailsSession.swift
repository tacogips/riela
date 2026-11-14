import Foundation
import XCTest
@testable import RielaCore

extension RuntimeStoreTests {
  func testFailedStepUpdateWithFailsSessionFalseKeepsSessionRunning() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 100)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let execution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(sessionId: session.sessionId, stepId: "start", nodeId: "node-start", attempt: 1)
    )

    let failedExecution = try await store.updateStepExecution(WorkflowStepExecutionUpdateInput(
      sessionId: session.sessionId,
      executionId: execution.executionId,
      status: .failed,
      failureReason: "advisory: provider_error",
      failureKind: .adapterFailure,
      currentStepId: "next",
      failsSession: false
    ))
    XCTAssertEqual(failedExecution.status, .failed)
    XCTAssertEqual(failedExecution.failureReason, "advisory: provider_error")

    let maybeStored = try await store.loadSession(id: session.sessionId)
    let stored = try XCTUnwrap(maybeStored)
    XCTAssertEqual(stored.status, .running)
    XCTAssertNil(stored.failureReason)
    XCTAssertNil(stored.failureKind)
    XCTAssertNil(stored.failedAt)
    XCTAssertEqual(stored.currentStepId, "next")
    XCTAssertEqual(stored.executions.first?.status, .failed)
  }

  func testFailedStepUpdateDefaultsToFailingSession() async throws {
    let failedAt = Date(timeIntervalSince1970: 100)
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(failedAt))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let execution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(sessionId: session.sessionId, stepId: "start", nodeId: "node-start", attempt: 1)
    )

    _ = try await store.updateStepExecution(WorkflowStepExecutionUpdateInput(
      sessionId: session.sessionId,
      executionId: execution.executionId,
      status: .failed,
      failureReason: "provider_error: boom",
      failureKind: .adapterFailure
    ))

    let maybeStored = try await store.loadSession(id: session.sessionId)
    let stored = try XCTUnwrap(maybeStored)
    XCTAssertEqual(stored.status, .failed)
    XCTAssertEqual(stored.failureReason, "provider_error: boom")
    XCTAssertEqual(stored.failureKind, .adapterFailure)
    XCTAssertEqual(stored.failedAt, failedAt)
  }

  func testMarkSessionFailedFailurePredicateRejectsWithoutMutatingSession() async throws {
    let store = InMemoryWorkflowRuntimeStore(markSessionFailedFailurePredicate: { _ in "terminal write rejected" })
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    _ = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(sessionId: session.sessionId, stepId: "start", nodeId: "node-start", attempt: 1)
    )

    await XCTAssertThrowsErrorAsync(
      try await store.markSessionFailed(WorkflowSessionFailureInput(sessionId: session.sessionId, reason: "boom"))
    )

    let maybeStored = try await store.loadSession(id: session.sessionId)
    let stored = try XCTUnwrap(maybeStored)
    XCTAssertEqual(stored.status, .running)
    XCTAssertNil(stored.failureReason)
    XCTAssertEqual(stored.executions.first?.status, .running)
  }
}
