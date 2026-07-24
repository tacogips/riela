import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class WorkflowCommandLivePersistenceEventTests: XCTestCase {
  func testBackendRunEventsAreEligibleForThrottledLiveSnapshotPersistence() {
    let baseEvent = WorkflowRunEvent(
      type: .backendEvent,
      workflowId: "wf",
      sessionId: "session",
      stepId: "step",
      nodeId: "node",
      executionId: "execution",
      backendEventType: "response.delta"
    )

    XCTAssertTrue(workflowRunEventTriggersLiveSessionPersistence(baseEvent))
    for eventType in [
      WorkflowRunEventType.sessionStarted,
      .stepStarted,
      .stepCompleted,
      .sessionCompleted
    ] {
      let event = WorkflowRunEvent(
        type: eventType,
        workflowId: "wf",
        sessionId: "session",
        stepId: "step",
        nodeId: "node",
        executionId: "execution"
      )
      XCTAssertTrue(workflowRunEventTriggersLiveSessionPersistence(event), eventType.rawValue)
    }
  }

  func testBackendRunEventsStillReachJSONLRecorder() async throws {
    let recorder = WorkflowRunJSONLRecorder(writer: nil)
    let event = WorkflowRunEvent(
      type: .backendEvent,
      workflowId: "wf",
      sessionId: "session",
      stepId: "step",
      nodeId: "node",
      executionId: "execution",
      backendEventType: "response.delta",
      backendSessionId: "native-session",
      backendEventChannel: "assistant",
      backendEventContent: "chunk",
      backendEventIsDelta: true,
      backendEventSequence: 3
    )

    await recorder.append(event)

    let output = await recorder.bufferedOutput()
    let decoded = try JSONDecoder().decode(WorkflowRunEvent.self, from: Data(output.utf8))
    XCTAssertEqual(decoded.type, .backendEvent)
    XCTAssertEqual(decoded.backendEventType, "response.delta")
    XCTAssertEqual(decoded.backendSessionId, "native-session")
    XCTAssertEqual(decoded.backendEventContent, "chunk")
    XCTAssertEqual(decoded.backendEventSequence, 3)
  }

  func testBackendRunEventBurstIsThrottledAndNewBackendSessionIdPersistsImmediately() async {
    let recorder = WorkflowRunJSONLRecorder(writer: nil)
    let state = WorkflowRunLivePersistenceState()
    var livePersistenceTriggerCount = 0
    let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

    for sequence in 1...10_000 {
      let event = WorkflowRunEvent(
        type: .backendEvent,
        workflowId: "wf",
        sessionId: "session",
        stepId: "step",
        nodeId: "node",
        executionId: "execution",
        backendEventType: "response.delta",
        backendEventChannel: "assistant",
        backendEventContent: "chunk-\(sequence)",
        backendEventIsDelta: true,
        backendEventSequence: sequence
      )
      if await state.shouldPersist(event: event, observedAt: observedAt) {
        livePersistenceTriggerCount += 1
      }
      await recorder.append(event)
    }
    let identified = WorkflowRunEvent(
      type: .backendEvent,
      workflowId: "wf",
      sessionId: "session",
      stepId: "step",
      nodeId: "node",
      executionId: "execution",
      backendEventType: "session_identified",
      backendSessionId: "native-session"
    )
    let firstIdentifiedPersistence = await state.shouldPersist(
      event: identified,
      observedAt: observedAt.addingTimeInterval(0.1)
    )
    let repeatedIdentifiedPersistence = await state.shouldPersist(
      event: identified,
      observedAt: observedAt.addingTimeInterval(0.2)
    )
    XCTAssertTrue(firstIdentifiedPersistence)
    XCTAssertFalse(repeatedIdentifiedPersistence)

    let output = await recorder.bufferedOutput()
    XCTAssertEqual(livePersistenceTriggerCount, 1)
    XCTAssertEqual(output.split(separator: "\n", omittingEmptySubsequences: true).count, 10_000)
  }

  func testBackendEventStateIsReadableFromSQLiteBeforeStepCompletion() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-backend-event-live-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let eventAt = date.addingTimeInterval(5)
    let session = WorkflowSession(
      workflowId: "wf",
      sessionId: "session",
      status: .running,
      entryStepId: "step",
      currentStepId: "step",
      createdAt: date,
      updatedAt: eventAt,
      executions: [
        WorkflowStepExecution(
          executionId: "execution",
          stepId: "step",
          nodeId: "node",
          attempt: 1,
          backend: .codexAgent,
          backendSessionId: "native-session",
          status: .running,
          lastBackendEventAt: eventAt,
          lastBackendEventType: "turn.started",
          createdAt: date,
          updatedAt: eventAt
        )
      ]
    )
    let state = WorkflowRunLivePersistenceState()
    await state.configure(storeRoot: root.path)
    let event = WorkflowRunEvent(
      type: .backendEvent,
      workflowId: "wf",
      sessionId: "session",
      stepId: "step",
      nodeId: "node",
      executionId: "execution",
      backendEventType: "turn.started",
      backendSessionId: "native-session"
    )

    let shouldPersist = await state.shouldPersist(event: event, observedAt: eventAt)
    XCTAssertTrue(shouldPersist)
    try await state.persistLiveSnapshot(WorkflowRunLivePersistenceSaveInput(
      persistedSession: PersistedCLIWorkflowSession(
        workflowName: "wf",
        session: session,
        resolution: WorkflowResolutionOptions(workflowName: "wf", scope: .direct)
      ),
      runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: session),
      workflowMessages: [],
      artifactRoot: nil
    ))

    let loaded = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    ).loadStrictReadOnly(sessionId: session.sessionId)
    let liveExecution = try XCTUnwrap(loaded.session.executions.first)
    XCTAssertEqual(liveExecution.status, .running)
    XCTAssertEqual(liveExecution.backendSessionId, "native-session")
    XCTAssertEqual(liveExecution.lastBackendEventType, "turn.started")
    XCTAssertEqual(liveExecution.lastBackendEventAt, eventAt)
  }

  func testLivePersistenceStateTracksOnlySuccessfullyPersistedMessages() async {
    let state = WorkflowRunLivePersistenceState()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let first = message(communicationId: "comm-a", createdOrder: 1, createdAt: date)
    let second = message(communicationId: "comm-b", createdOrder: 2, createdAt: date)

    let initialPending = await state.pendingMessages(sessionId: "session", from: [first, second])
    XCTAssertEqual(initialPending.map(\.communicationId), ["comm-a", "comm-b"])
    await state.recordFailure(sessionId: "session", error: "disk full")
    let pendingAfterFailure = await state.pendingMessages(sessionId: "session", from: [first, second])
    XCTAssertEqual(pendingAfterFailure.map(\.communicationId), ["comm-a", "comm-b"])
    await state.recordSuccess(sessionId: "session", persistedMessages: [first])
    let pendingAfterFirstSuccess = await state.pendingMessages(sessionId: "session", from: [first, second])
    XCTAssertEqual(pendingAfterFirstSuccess.map(\.communicationId), ["comm-b"])
    await state.recordSuccess(sessionId: "session", persistedMessages: [second])
    let pendingAfterSecondSuccess = await state.pendingMessages(sessionId: "session", from: [first, second])
    XCTAssertEqual(pendingAfterSecondSuccess, [])
  }

  func testLivePersistenceStateReusesConnectionAcrossSnapshotSaves() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-live-persistence-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let state = WorkflowRunLivePersistenceState()
    await state.configure(storeRoot: root.path)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let first = message(communicationId: "comm-a", createdOrder: 1, createdAt: date)
    let second = message(communicationId: "comm-b", createdOrder: 2, createdAt: date.addingTimeInterval(1))
    let session = WorkflowSession(
      workflowId: "wf",
      sessionId: "session",
      status: .running,
      entryStepId: "start",
      currentStepId: "worker",
      createdAt: date,
      updatedAt: date
    )
    let persistedSession = PersistedCLIWorkflowSession(
      workflowName: "wf",
      session: session,
      resolution: WorkflowResolutionOptions(workflowName: "wf", scope: .direct)
    )

    try await state.persistLiveSnapshot(WorkflowRunLivePersistenceSaveInput(
      persistedSession: persistedSession,
      runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: session, workflowMessages: [first]),
      workflowMessages: [first],
      artifactRoot: nil
    ))
    try await state.persistLiveSnapshot(WorkflowRunLivePersistenceSaveInput(
      persistedSession: persistedSession,
      runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: session, workflowMessages: [first, second]),
      workflowMessages: [first, second],
      artifactRoot: nil
    ))

    let snapshot = await state.snapshot()
    XCTAssertEqual(snapshot.connectionOpenCount, 1)
    XCTAssertEqual(snapshot.persistedSession, true)
    let persistedMessages = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    )
    .load(sessionId: session.sessionId)
    .workflowMessages
    .map(\.communicationId)
    XCTAssertEqual(persistedMessages, ["comm-a", "comm-b"])
  }

  private func message(
    communicationId: String,
    createdOrder: Int,
    createdAt: Date
  ) -> WorkflowMessageRecord {
    WorkflowMessageRecord(
      communicationId: communicationId,
      workflowExecutionId: "session",
      fromStepId: "start",
      toStepId: "worker",
      sourceStepExecutionId: "exec-start",
      payload: ["status": .string("ok")],
      lifecycleStatus: .delivered,
      createdOrder: createdOrder,
      createdAt: createdAt
    )
  }
}
