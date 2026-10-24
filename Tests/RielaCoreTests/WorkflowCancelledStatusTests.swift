import XCTest
@testable import RielaCore

final class WorkflowCancelledStatusTests: XCTestCase {
  func testUnknownPersistedStatusesDecodeAsFailedAndCancelledEncodesRawValue() throws {
    let decoder = JSONDecoder()
    XCTAssertEqual(try decoder.decode(WorkflowSessionStatus.self, from: Data("\"futureStatus\"".utf8)), .failed)
    XCTAssertEqual(try decoder.decode(WorkflowStepExecutionStatus.self, from: Data("\"futureStatus\"".utf8)), .failed)
    XCTAssertEqual(String(data: try JSONEncoder().encode(WorkflowSessionStatus.cancelled), encoding: .utf8), "\"cancelled\"")
    XCTAssertEqual(String(data: try JSONEncoder().encode(WorkflowStepExecutionStatus.cancelled), encoding: .utf8), "\"cancelled\"")
  }

  func testCancelledStatusIsTerminalAndLegacyFailureIsCancellation() {
    XCTAssertTrue(WorkflowSessionStatus.cancelled.isTerminal)
    XCTAssertFalse(WorkflowSessionStatus.running.isTerminal)
    let session = WorkflowSession(
      workflowId: "workflow", sessionId: "legacy", status: .failed, entryStepId: "entry",
      createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
      failureKind: .cancelled
    )
    XCTAssertTrue(session.isCancellation)
  }

  func testMarkSessionFailedPersistsCancelledAndStalledRemainsFailed() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let cancelled = try await store.createSession(WorkflowSessionCreateInput(workflowId: "workflow", entryStepId: "entry"))
    _ = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(sessionId: cancelled.sessionId, stepId: "entry", nodeId: "node", attempt: 1)
    )
    let cancelledResult = try await store.markSessionFailed(WorkflowSessionFailureInput(
      sessionId: cancelled.sessionId, reason: "cancelled", failureKind: .cancelled
    ))
    XCTAssertEqual(cancelledResult.status, .cancelled)
    XCTAssertEqual(cancelledResult.executions.first?.status, .cancelled)
    XCTAssertTrue(cancelledResult.isCancellation)

    let stalled = try await store.createSession(WorkflowSessionCreateInput(workflowId: "workflow", entryStepId: "entry"))
    let stalledResult = try await store.markSessionFailed(WorkflowSessionFailureInput(
      sessionId: stalled.sessionId, reason: "stalled", failureKind: .stalled
    ))
    XCTAssertEqual(stalledResult.status, .failed)
  }

  func testCancelledSourceCanImportAcceptedHistory() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let source = try await store.createSession(WorkflowSessionCreateInput(workflowId: "workflow", entryStepId: "entry"))
    _ = try await store.markSessionFailed(WorkflowSessionFailureInput(
      sessionId: source.sessionId, reason: "cancelled", failureKind: .cancelled
    ))
    let target = try await store.createSession(WorkflowSessionCreateInput(workflowId: "workflow", entryStepId: "entry"))

    let imported = try await store.importAcceptedHistory(WorkflowHistoryImportInput(
      sessionId: target.sessionId, sourceSessionId: source.sessionId, executions: [], messages: []
    ))
    XCTAssertEqual(imported.parentSessionId, source.sessionId)
  }

}
