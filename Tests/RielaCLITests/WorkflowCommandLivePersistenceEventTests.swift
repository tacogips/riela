import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class WorkflowCommandLivePersistenceEventTests: XCTestCase {
  func testBackendRunEventsDoNotTriggerLiveSnapshotPersistence() {
    let baseEvent = WorkflowRunEvent(
      type: .backendEvent,
      workflowId: "wf",
      sessionId: "session",
      stepId: "step",
      nodeId: "node",
      executionId: "execution",
      backendEventType: "response.delta"
    )

    XCTAssertFalse(workflowRunEventTriggersLiveSessionPersistence(baseEvent))
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
    XCTAssertEqual(decoded.backendEventContent, "chunk")
    XCTAssertEqual(decoded.backendEventSequence, 3)
  }

  func testBackendRunEventBurstDoesNotTriggerLiveSnapshotPersistence() async {
    let recorder = WorkflowRunJSONLRecorder(writer: nil)
    var livePersistenceTriggerCount = 0

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
      if workflowRunEventTriggersLiveSessionPersistence(event) {
        livePersistenceTriggerCount += 1
      }
      await recorder.append(event)
    }

    let output = await recorder.bufferedOutput()
    XCTAssertEqual(livePersistenceTriggerCount, 0)
    XCTAssertEqual(output.split(separator: "\n", omittingEmptySubsequences: true).count, 10_000)
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
