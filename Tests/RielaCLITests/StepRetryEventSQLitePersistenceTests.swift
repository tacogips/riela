import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaCLI

final class StepRetryEventSQLitePersistenceTests: XCTestCase {
  func testRetryAndPostCompletionEventsPersistWithMetadata() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("step-retry-events")
    defer { try? FileManager.default.removeItem(at: root) }
    let backing = InMemoryWorkflowRuntimeStore()
    let storeRoot = canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    let store = FailClosedSQLiteWorkflowRuntimeStore(backing: backing, rootDirectory: storeRoot)
    let session = try await store.createSession(
      WorkflowSessionCreateInput(workflowId: "workflow", entryStepId: "step")
    )
    let execution = try await store.recordStepExecution(WorkflowStepExecutionRecordInput(
      sessionId: session.sessionId, stepId: "step", nodeId: "node", attempt: 1, backend: .codexAgent
    ))
    let retryMetadata: JSONObject = [
      "attempts": .integer(1), "stopReason": .string("succeeded"), "elapsedMs": .integer(5)
    ]
    let deadlineMetadata: JSONObject = ["elapsedMs": .integer(10), "overrunMs": .integer(2)]
    _ = try await store.recordStepBackendEventReceipt(WorkflowStepBackendEventInput(
      sessionId: session.sessionId, executionId: execution.executionId,
      eventType: "riela.step.retry.stopped", metadata: retryMetadata
    ))
    _ = try await store.updateStepExecution(WorkflowStepExecutionUpdateInput(
      sessionId: session.sessionId, executionId: execution.executionId, status: .completed
    ))
    _ = try await store.recordStepBackendEventReceipt(WorkflowStepBackendEventInput(
      sessionId: session.sessionId, executionId: execution.executionId,
      eventType: "riela.step.deadline.exceededAfterSuccess", metadata: deadlineMetadata
    ))

    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: storeRoot).load(sessionId: session.sessionId)
    let loaded = try XCTUnwrap(snapshot.session.executions.first)
    XCTAssertEqual(loaded.status, .completed)
    let events = try XCTUnwrap(loaded.recentBackendEvents)
    XCTAssertEqual(events.map(\.eventType), ["riela.step.retry.stopped", "riela.step.deadline.exceededAfterSuccess"])
    guard events.count == 2 else { return }
    XCTAssertEqual(events[0].metadata, retryMetadata)
    XCTAssertEqual(events[1].metadata, deadlineMetadata)
  }
}
