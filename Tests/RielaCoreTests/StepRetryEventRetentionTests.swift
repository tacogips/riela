import XCTest
@testable import RielaCore

final class StepRetryEventRetentionTests: XCTestCase {
  func testTypedMetadataRetentionAndRejection() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let execution = try await store.recordStepExecution(WorkflowStepExecutionRecordInput(
      sessionId: session.sessionId, stepId: "start", nodeId: "node", attempt: 1))
    let type = "riela.step.attempt.finished"
    let valid: JSONObject = [
      "attempt": .integer(1_000), "maxAttempts": .integer(1_000), "attemptDurationMs": .integer(1_000_000_000_000),
      "elapsedMs": .integer(1_000_000_000_000), "budgetRemainingMs": .integer(1_000_000_000_000),
      "queueWaitMs": .integer(1_000_000_000_000), "recordStartedDurationMs": .integer(1_000_000_000_000),
      "retryAfterMs": .integer(1_000_000_000_000), "nextDelayMs": .integer(1_000_000_000_000),
      "retryable": .bool(true), "outcome": .string("failed"), "errorCode": .string(AdapterExecutionErrorCode.timeout.rawValue),
      "effectOutcome": .string(AdapterEffectOutcome.unknown.rawValue), "timeoutKind": .string(StepTimeoutKind.attempt.rawValue),
      "timeoutSource": .string("runner-backstop")
    ]
    var invalid = [JSONObject]()
    for (key, value) in [("extra", JSONValue.string("secret")), ("attempt", .string("1")),
                         ("attemptDurationMs", .number(1)), ("elapsedMs", .integer(-1)),
                         ("attempt", .integer(1_001)), ("timeoutSource", .string("worker"))] {
      var item = valid; item[key] = value; invalid.append(item)
    }
    var missing = valid; missing.removeValue(forKey: "outcome"); invalid.append(missing)
    for item in invalid {
      _ = try await store.recordStepBackendEvent(WorkflowStepBackendEventInput(
        sessionId: session.sessionId, executionId: execution.executionId, eventType: type, metadata: item))
    }
    let updated = try await store.recordStepBackendEvent(WorkflowStepBackendEventInput(
      sessionId: session.sessionId, executionId: execution.executionId, eventType: type, metadata: valid))
    let events = try XCTUnwrap(updated.recentBackendEvents)
    XCTAssertEqual(events.count, invalid.count + 1)
    XCTAssertTrue(events.dropLast().allSatisfy { $0.metadata == nil })
    XCTAssertEqual(events.last?.metadata, valid)
    XCTAssertLessThanOrEqual(try JSONEncoder().encode(valid).count, WorkflowFailureDiagnostics.stepRetryEventMetadataByteLimit)
    let reasons: [StepRetryStopReason] = [.succeeded, .nonRetryable, .outcomeUnknown, .retryExhausted,
      .deadlineExhausted, .stepDeadline, .retryAfterExceedsMaxDelay, .cancelled]
    for reason in reasons {
      let item: JSONObject = ["attempts": .integer(1), "stopReason": .string(reason.rawValue)]
      XCTAssertEqual(WorkflowFailureDiagnostics.retainedEventMetadata(eventType: "riela.step.retry.stopped", metadata: item), item)
    }
    XCTAssertNil(WorkflowFailureDiagnostics.retainedEventMetadata(eventType: "riela.step.retry.stopped",
      metadata: ["attempts": .integer(1), "stopReason": .string("bogus")]))
    XCTAssertNil(WorkflowFailureDiagnostics.retainedEventMetadata(eventType: "riela.step.retry.stopped", metadata: ["attempts": .integer(1)]))
    XCTAssertNil(WorkflowFailureDiagnostics.retainedEventMetadata(eventType: "other", metadata: valid))
    let command = WorkflowFailureDiagnostics.eventMetadata(exitCode: 3, diagnostics: nil)
    XCTAssertEqual(WorkflowFailureDiagnostics.retainedEventMetadata(eventType: WorkflowFailureDiagnostics.eventType, metadata: command), command)
  }

  func testOnlyOneCompletedTerminalEventIsAppended() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let execution = try await store.recordStepExecution(WorkflowStepExecutionRecordInput(
      sessionId: session.sessionId, stepId: "start", nodeId: "node", attempt: 1))
    let before = try await store.updateStepExecution(WorkflowStepExecutionUpdateInput(
      sessionId: session.sessionId, executionId: execution.executionId, status: .completed))
    let metadata: JSONObject = ["elapsedMs": .integer(8), "overrunMs": .integer(3)]
    let event = WorkflowStepBackendEventInput(sessionId: session.sessionId, executionId: execution.executionId,
      eventType: "riela.step.deadline.exceededAfterSuccess", metadata: metadata)
    let receipt = try await store.recordStepBackendEventReceipt(event)
    let repeated = try await store.recordStepBackendEventReceipt(event)
    XCTAssertEqual(receipt.sequence, repeated.sequence)
    _ = try await store.recordStepBackendEventReceipt(WorkflowStepBackendEventInput(
      sessionId: session.sessionId, executionId: execution.executionId, eventType: "riela.step.retry.stopped"))
    let loaded = try await store.loadSession(id: session.sessionId)
    let after = try XCTUnwrap(loaded?.executions.first)
    XCTAssertEqual(after.recentBackendEvents?.last?.metadata, metadata)
    XCTAssertEqual(after.backendEventCount, (before.backendEventCount ?? 0) + 1)
    XCTAssertEqual(after.status, before.status)
    XCTAssertEqual(after.updatedAt, before.updatedAt)
    XCTAssertEqual(after.acceptedOutput, before.acceptedOutput)
    XCTAssertEqual(after.adapterOutput, before.adapterOutput)
    let tails = await store.executionLiveTailCountForTesting()
    XCTAssertEqual(tails, 0)

    let failed = try await store.recordStepExecution(WorkflowStepExecutionRecordInput(
      sessionId: session.sessionId, stepId: "other", nodeId: "node", attempt: 1))
    let failedBefore = try await store.updateStepExecution(WorkflowStepExecutionUpdateInput(
      sessionId: session.sessionId, executionId: failed.executionId, status: .failed))
    let failedAfter = try await store.recordStepBackendEvent(WorkflowStepBackendEventInput(
      sessionId: session.sessionId, executionId: failed.executionId, eventType: event.eventType, metadata: metadata))
    XCTAssertEqual(failedAfter.backendEventCount, failedBefore.backendEventCount)
  }
}
