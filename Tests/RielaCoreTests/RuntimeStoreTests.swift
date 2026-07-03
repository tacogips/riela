import XCTest
@testable import RielaCore

final class RuntimeStoreTests: XCTestCase {
  func testRuntimePersistenceSnapshotProjectsSessionMessagesAndRootOutput() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 100)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let execution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(sessionId: session.sessionId, stepId: "start", nodeId: "node-start", attempt: 1)
    )
    let updated = try await store.updateStepExecution(
      WorkflowStepExecutionUpdateInput(
        sessionId: session.sessionId,
        executionId: execution.executionId,
        status: .completed,
        acceptedOutput: WorkflowAcceptedOutputMetadata(
          payload: ["status": .string("ok")],
          when: [:],
          isRootOutput: true,
          acceptedAt: Date(timeIntervalSince1970: 100)
        )
      )
    )
    _ = updated
    let message = try await store.appendWorkflowMessage(
      WorkflowMessageAppendInput(
        workflowExecutionId: session.sessionId,
        fromStepId: "start",
        toStepId: "next",
        sourceStepExecutionId: execution.executionId,
        payload: ["status": .string("ok")]
      )
    )
    let loadedSession = try await store.loadSession(id: session.sessionId)
    let persisted = try XCTUnwrap(loadedSession)
    let snapshot = WorkflowRuntimePersistenceProjector.snapshot(session: persisted, workflowMessages: [message])

    XCTAssertEqual(snapshot.session.sessionId, session.sessionId)
    XCTAssertEqual(snapshot.workflowMessages.map(\.communicationId), ["comm-000001"])
    XCTAssertEqual(snapshot.rootOutput?["status"], .string("ok"))
    XCTAssertEqual(snapshot.diagnostics, [])
  }

  func testAcceptedReviewFindingsArePersistedOnSession() async throws {
    let date = Date(timeIntervalSince1970: 100)
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(date))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "review"))
    let execution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(sessionId: session.sessionId, stepId: "review", nodeId: "node-review", attempt: 1)
    )

    _ = try await store.updateStepExecution(
      WorkflowStepExecutionUpdateInput(
        sessionId: session.sessionId,
        executionId: execution.executionId,
        status: .completed,
        acceptedOutput: WorkflowAcceptedOutputMetadata(
          payload: [
            "issueReference": .string("owner/repo#123"),
            "workflowMode": .string("issue-resolution"),
            "findings": .array([
              .object([
                "severity": .string("medium"),
                "targetStepId": .string("implement"),
                "file": .string("Sources/App.swift"),
                "line": .number(42),
                "message": .string("Retry must preserve review context."),
                "requiredChange": .string("Replay this finding to the implementation step.")
              ])
            ])
          ],
          when: [:],
          isRootOutput: true,
          acceptedAt: date
        )
      )
    )

    let maybeLoaded = try await store.loadSession(id: session.sessionId)
    let loaded = try XCTUnwrap(maybeLoaded)
    XCTAssertEqual(loaded.reviewFindings.count, 1)
    XCTAssertEqual(loaded.reviewFindings.first?.id, "\(session.sessionId)-review-attempt-1-finding-1")
    XCTAssertEqual(loaded.reviewFindings.first?.issueReference, "owner/repo#123")
    XCTAssertEqual(loaded.reviewFindings.first?.workflowMode, "issue-resolution")
    XCTAssertEqual(loaded.reviewFindings.first?.sourceReviewStepId, "review")
    XCTAssertEqual(loaded.reviewFindings.first?.sourceStepExecutionId, execution.executionId)
    XCTAssertEqual(loaded.reviewFindings.first?.targetStepId, "implement")
    XCTAssertEqual(loaded.reviewFindings.first?.filePath, "Sources/App.swift")
    XCTAssertEqual(loaded.reviewFindings.first?.line, 42)
    XCTAssertEqual(loaded.reviewFindings.first?.severity, .mid)
    XCTAssertEqual(loaded.reviewFindings.first?.message, "Retry must preserve review context.")
    XCTAssertEqual(loaded.reviewFindings.first?.feedback, "Replay this finding to the implementation step.")
    XCTAssertEqual(loaded.reviewFindings.first?.status, .open)
  }

  func testFileRuntimePersistenceRoundTripsLoopEvidenceAndDecodesLegacySnapshot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let session = WorkflowSession(
      workflowId: "wf",
      sessionId: "session-loop",
      status: .completed,
      entryStepId: "review",
      createdAt: date,
      updatedAt: date
    )
    let manifest = LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "loop-evidence-session-loop",
      workflowId: "wf",
      sessionId: "session-loop",
      workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow-directory", mutable: true),
      policy: LoopPolicyEvidence(),
      redaction: LoopRedactionSummary(policyName: "summary-only", status: "clean"),
      createdAt: date,
      updatedAt: date
    )

    let store = FileWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    try store.save(WorkflowRuntimePersistenceSnapshot(session: session, loopEvidence: manifest))
    let loaded = try store.load(sessionId: "session-loop")

    XCTAssertEqual(loaded.loopEvidence, manifest)

    let legacyData = Data(
      """
      {
        "session": {
          "workflowId": "wf",
          "sessionId": "legacy-session",
          "status": "completed",
          "entryStepId": "review",
          "createdAt": 1700000000,
          "updatedAt": 1700000000,
          "executions": []
        },
        "workflowMessages": [],
        "diagnostics": []
      }
      """.utf8
    )
    let legacy = try JSONDecoder().decode(WorkflowRuntimePersistenceSnapshot.self, from: legacyData)
    XCTAssertNil(legacy.loopEvidence)
    XCTAssertEqual(legacy.session.reviewFindings, [])
  }

  func testInMemoryStoreUsesDeterministicIdsTimestampsAndCreatedOrder() async throws {
    let date = Date(timeIntervalSince1970: 100)
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(date))

    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let execution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(sessionId: session.sessionId, stepId: "start", nodeId: "node-start", attempt: 1, backend: .codexAgent)
    )
    let first = try await store.appendWorkflowMessage(
      WorkflowMessageAppendInput(
        workflowExecutionId: session.sessionId,
        fromStepId: "start",
        toStepId: "next",
        sourceStepExecutionId: execution.executionId,
        payload: ["n": .number(1)]
      )
    )
    let second = try await store.appendWorkflowMessage(
      WorkflowMessageAppendInput(
        workflowExecutionId: session.sessionId,
        fromStepId: "start",
        toStepId: "next",
        sourceStepExecutionId: execution.executionId,
        payload: ["n": .number(2)]
      )
    )

    XCTAssertEqual(session.sessionId, "wf-session-1")
    XCTAssertEqual(execution.executionId, "start-attempt-1-exec-1")
    XCTAssertEqual(first.communicationId, "comm-000001")
    XCTAssertEqual(second.communicationId, "comm-000002")
    XCTAssertEqual(first.createdOrder, 1)
    XCTAssertEqual(second.createdOrder, 2)
    XCTAssertEqual(first.lifecycleStatus, .delivered)
    XCTAssertEqual(second.lifecycleStatus, .delivered)
    XCTAssertEqual(second.createdAt, date)
    let listedMessages = try await store.listMessages(for: session.sessionId, toStepId: "next")
    XCTAssertEqual(listedMessages, [first, second])
    let loadedSession = try await store.loadSession(id: session.sessionId)
    let loaded = try XCTUnwrap(loadedSession)
    XCTAssertEqual(loaded.currentStepId, "start")
    XCTAssertEqual(loaded.updatedAt, date)
  }

  func testRecordStepBackendEventUpdatesDedicatedHeartbeatFieldsAndLiveTail() async throws {
    let startedAt = Date(timeIntervalSince1970: 100)
    let heartbeatAt = Date(timeIntervalSince1970: 105)
    let clock = MutableWorkflowRuntimeClock(startedAt)
    let store = InMemoryWorkflowRuntimeStore(clock: clock)

    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let execution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(sessionId: session.sessionId, stepId: "start", nodeId: "node-start", attempt: 1, backend: .codexAgent)
    )

    clock.set(heartbeatAt)
    let updated = try await store.recordStepBackendEvent(
      WorkflowStepBackendEventInput(
        sessionId: session.sessionId,
        executionId: execution.executionId,
        eventType: "item.completed",
        channel: .assistant,
        contentSnapshot: "working"
      )
    )

    XCTAssertEqual(updated.updatedAt, execution.updatedAt)
    XCTAssertEqual(updated.lastBackendEventAt, heartbeatAt)
    XCTAssertEqual(updated.lastBackendEventType, "item.completed")
    XCTAssertEqual(updated.backendEventCount, 1)
    XCTAssertEqual(updated.recentBackendEvents?.first?.sequence, 1)
    XCTAssertEqual(updated.recentBackendEvents?.first?.channel, .assistant)
    XCTAssertEqual(updated.recentBackendEvents?.first?.content, "working")
    XCTAssertEqual(updated.streamedResponseText, "working")
    let maybeLoaded = try await store.loadSession(id: session.sessionId)
    let loaded = try XCTUnwrap(maybeLoaded)
    XCTAssertEqual(loaded.updatedAt, session.updatedAt)
    XCTAssertEqual(loaded.executions.first?.lastBackendEventAt, heartbeatAt)
    XCTAssertEqual(loaded.executions.first?.streamedResponseText, "working")
  }

  func testRecordStepBackendEventReceiptAvoidsReturningProjectedExecutionPayload() async throws {
    let startedAt = Date(timeIntervalSince1970: 100)
    let heartbeatAt = Date(timeIntervalSince1970: 105)
    let clock = MutableWorkflowRuntimeClock(startedAt)
    let store = InMemoryWorkflowRuntimeStore(clock: clock)
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let execution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(
        sessionId: session.sessionId,
        stepId: "start",
        nodeId: "node-start",
        attempt: 1,
        backend: .codexAgent
      )
    )

    clock.set(heartbeatAt)
    let receipt = try await store.recordStepBackendEventReceipt(
      WorkflowStepBackendEventInput(
        sessionId: session.sessionId,
        executionId: execution.executionId,
        eventType: "assistant.delta",
        channel: .assistant,
        contentDelta: "stream",
        isDelta: true
      )
    )

    XCTAssertEqual(receipt.executionId, execution.executionId)
    XCTAssertEqual(receipt.sequence, 1)
    XCTAssertEqual(receipt.at, heartbeatAt)
    let maybeLoaded = try await store.loadSession(id: session.sessionId)
    let loaded = try XCTUnwrap(maybeLoaded)
    XCTAssertEqual(loaded.executions.first?.streamedResponseText, "stream")
    XCTAssertEqual(loaded.executions.first?.backendEventCount, 1)
  }

  func testBackendLiveTailProjectsAfterStepCompletionAndLatestSessionLookup() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 100)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let execution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(
        sessionId: session.sessionId,
        stepId: "start",
        nodeId: "node-start",
        attempt: 1,
        backend: .codexAgent
      )
    )

    _ = try await store.recordStepBackendEvent(
      WorkflowStepBackendEventInput(
        sessionId: session.sessionId,
        executionId: execution.executionId,
        eventType: "assistant",
        channel: .assistant,
        contentSnapshot: "live"
      )
    )
    let completed = try await store.updateStepExecution(
      WorkflowStepExecutionUpdateInput(
        sessionId: session.sessionId,
        executionId: execution.executionId,
        status: .completed
      )
    )

    XCTAssertEqual(completed.status, .completed)
    XCTAssertEqual(completed.backendEventCount, 1)
    XCTAssertEqual(completed.streamedResponseText, "live")
    let liveTailCount = await store.executionLiveTailCountForTesting()
    XCTAssertEqual(liveTailCount, 0)
    let maybeLoaded = try await store.loadSession(id: session.sessionId)
    let loaded = try XCTUnwrap(maybeLoaded)
    XCTAssertEqual(loaded.executions.first?.status, .completed)
    XCTAssertEqual(loaded.executions.first?.streamedResponseText, "live")
    let latest = await store.latestSession(workflowId: "wf")
    XCTAssertEqual(latest?.executions.first?.streamedResponseText, "live")
  }

  func testMarkSessionFailedFoldsRunningExecutionLiveTailIntoStoredSession() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 100)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let execution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(
        sessionId: session.sessionId,
        stepId: "start",
        nodeId: "node-start",
        attempt: 1,
        backend: .codexAgent
      )
    )
    _ = try await store.recordStepBackendEventReceipt(
      WorkflowStepBackendEventInput(
        sessionId: session.sessionId,
        executionId: execution.executionId,
        eventType: "assistant",
        channel: .assistant,
        contentSnapshot: "live"
      )
    )
    let liveTailCountAfterEvent = await store.executionLiveTailCountForTesting()
    XCTAssertEqual(liveTailCountAfterEvent, 1)

    let failed = try await store.markSessionFailed(WorkflowSessionFailureInput(
      sessionId: session.sessionId,
      reason: "boom"
    ))

    let liveTailCountAfterFailure = await store.executionLiveTailCountForTesting()
    XCTAssertEqual(liveTailCountAfterFailure, 0)
    XCTAssertEqual(failed.executions.first?.status, .failed)
    XCTAssertEqual(failed.executions.first?.streamedResponseText, "live")
    let maybeLoaded = try await store.loadSession(id: session.sessionId)
    let loaded = try XCTUnwrap(maybeLoaded)
    XCTAssertEqual(loaded.executions.first?.streamedResponseText, "live")
  }

  func testRecordStepBackendEventAppendsAssistantDeltasAndLifecycleCount() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 100)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let execution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(sessionId: session.sessionId, stepId: "start", nodeId: "node-start", attempt: 1, backend: .cursorCliAgent)
    )

    _ = try await store.recordStepBackendEvent(
      WorkflowStepBackendEventInput(
        sessionId: session.sessionId,
        executionId: execution.executionId,
        eventType: "assistant",
        channel: .assistant,
        contentSnapshot: "hello"
      )
    )
    _ = try await store.recordStepBackendEvent(
      WorkflowStepBackendEventInput(
        sessionId: session.sessionId,
        executionId: execution.executionId,
        eventType: "assistant",
        channel: .assistant,
        contentDelta: " world",
        isDelta: true
      )
    )
    let lifecycle = try await store.recordStepBackendEvent(
      WorkflowStepBackendEventInput(
        sessionId: session.sessionId,
        executionId: execution.executionId,
        eventType: "result"
      )
    )

    XCTAssertEqual(lifecycle.backendEventCount, 3)
    XCTAssertEqual(lifecycle.lastBackendEventType, "result")
    XCTAssertEqual(lifecycle.recentBackendEvents?.map(\.sequence), [1, 2, 3])
    XCTAssertEqual(lifecycle.recentBackendEvents?.last?.channel, nil)
    XCTAssertEqual(lifecycle.streamedResponseText, "hello world")
  }

  func testRecordStepBackendEventBoundsRecentEventTail() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 100)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let execution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(sessionId: session.sessionId, stepId: "start", nodeId: "node-start", attempt: 1, backend: .codexAgent)
    )
    var updated = execution

    for index in 1...105 {
      updated = try await store.recordStepBackendEvent(
        WorkflowStepBackendEventInput(
          sessionId: session.sessionId,
          executionId: execution.executionId,
          eventType: "turn.started.\(index)"
        )
      )
    }

    XCTAssertEqual(updated.backendEventCount, 105)
    XCTAssertEqual(updated.recentBackendEvents?.count, 100)
    XCTAssertEqual(updated.recentBackendEvents?.first?.sequence, 6)
    XCTAssertEqual(updated.recentBackendEvents?.last?.sequence, 105)
    XCTAssertNil(updated.streamedResponseText)
  }

  func testRecordStepBackendEventCapsStreamedResponseTextWithHeadAndTail() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 100)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let execution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(sessionId: session.sessionId, stepId: "start", nodeId: "node-start", attempt: 1, backend: .codexAgent)
    )
    let snapshot = "head" + String(repeating: "x", count: 40 * 1024) + "tail"

    let updated = try await store.recordStepBackendEvent(
      WorkflowStepBackendEventInput(
        sessionId: session.sessionId,
        executionId: execution.executionId,
        eventType: "assistant.snapshot",
        channel: .assistant,
        contentSnapshot: snapshot
      )
    )

    let streamedResponseText = try XCTUnwrap(updated.streamedResponseText)
    XCTAssertLessThanOrEqual(streamedResponseText.utf8.count, 32 * 1024)
    XCTAssertTrue(streamedResponseText.hasPrefix("head"))
    XCTAssertTrue(streamedResponseText.hasSuffix("tail"))
  }

  func testRecordStepBackendEventAppendsDeltasToCappedStreamedResponseText() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 100)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let execution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(
        sessionId: session.sessionId,
        stepId: "start",
        nodeId: "node-start",
        attempt: 1,
        backend: .codexAgent
      )
    )
    let snapshot = "head" + String(repeating: "x", count: 40 * 1024) + "tail"

    _ = try await store.recordStepBackendEvent(
      WorkflowStepBackendEventInput(
        sessionId: session.sessionId,
        executionId: execution.executionId,
        eventType: "assistant.snapshot",
        channel: .assistant,
        contentSnapshot: snapshot
      )
    )
    let updated = try await store.recordStepBackendEvent(
      WorkflowStepBackendEventInput(
        sessionId: session.sessionId,
        executionId: execution.executionId,
        eventType: "assistant.delta",
        channel: .assistant,
        contentDelta: "delta-tail",
        isDelta: true
      )
    )

    let streamedResponseText = try XCTUnwrap(updated.streamedResponseText)
    XCTAssertLessThanOrEqual(streamedResponseText.utf8.count, 32 * 1024)
    XCTAssertTrue(streamedResponseText.hasPrefix("head"))
    XCTAssertTrue(streamedResponseText.hasSuffix("taildelta-tail"))
  }

  func testRecordStepBackendEventKeepsUncappedDeltaOnlyStreamUntilCap() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 100)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let execution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(
        sessionId: session.sessionId,
        stepId: "start",
        nodeId: "node-start",
        attempt: 1,
        backend: .codexAgent
      )
    )

    var updated = execution
    for delta in ["head", String(repeating: "x", count: 20 * 1024), "tail"] {
      updated = try await store.recordStepBackendEvent(
        WorkflowStepBackendEventInput(
          sessionId: session.sessionId,
          executionId: execution.executionId,
          eventType: "assistant.delta",
          channel: .assistant,
          contentDelta: delta,
          isDelta: true
        )
      )
    }

    XCTAssertEqual(updated.streamedResponseText, "head" + String(repeating: "x", count: 20 * 1024) + "tail")
  }

  func testRecordStepBackendEventKeepsCappedHeadAndNewestTailAcrossManyDeltas() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 100)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let execution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(
        sessionId: session.sessionId,
        stepId: "start",
        nodeId: "node-start",
        attempt: 1,
        backend: .codexAgent
      )
    )
    let snapshot = "head" + String(repeating: "x", count: 40 * 1024) + "tail"

    _ = try await store.recordStepBackendEvent(
      WorkflowStepBackendEventInput(
        sessionId: session.sessionId,
        executionId: execution.executionId,
        eventType: "assistant.snapshot",
        channel: .assistant,
        contentSnapshot: snapshot
      )
    )

    var updated = execution
    for index in 0..<200 {
      updated = try await store.recordStepBackendEvent(
        WorkflowStepBackendEventInput(
          sessionId: session.sessionId,
          executionId: execution.executionId,
          eventType: "assistant.delta",
          channel: .assistant,
          contentDelta: "-delta-\(index)",
          isDelta: true
        )
      )
    }

    let streamedResponseText = try XCTUnwrap(updated.streamedResponseText)
    XCTAssertLessThanOrEqual(streamedResponseText.utf8.count, 32 * 1024)
    XCTAssertTrue(streamedResponseText.hasPrefix("head"))
    XCTAssertTrue(streamedResponseText.hasSuffix("-delta-199"))
  }

  func testMarkSessionFailedFailsRunningExecutionsAndTerminalizesSession() async throws {
    let startedAt = Date(timeIntervalSince1970: 100)
    let failedAt = Date(timeIntervalSince1970: 105)
    let clock = MutableWorkflowRuntimeClock(startedAt)
    let store = InMemoryWorkflowRuntimeStore(clock: clock)

    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    _ = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(sessionId: session.sessionId, stepId: "start", nodeId: "node-start", attempt: 1)
    )

    clock.set(failedAt)
    let failedSession = try await store.markSessionFailed(
      WorkflowSessionFailureInput(sessionId: session.sessionId, reason: "workflow run cancelled")
    )

    XCTAssertEqual(failedSession.status, .failed)
    XCTAssertEqual(failedSession.updatedAt, failedAt)
    XCTAssertEqual(failedSession.executions.first?.status, .failed)
    XCTAssertEqual(failedSession.executions.first?.failureReason, "workflow run cancelled")
    XCTAssertEqual(failedSession.executions.first?.updatedAt, failedAt)
  }

  func testMarkSessionFailedTerminalizesSessionWithoutRunningExecution() async throws {
    let date = Date(timeIntervalSince1970: 100)
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(date))

    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))

    let failedSession = try await store.markSessionFailed(
      WorkflowSessionFailureInput(sessionId: session.sessionId, reason: "workflow run cancelled")
    )

    XCTAssertEqual(failedSession.status, .failed)
    XCTAssertEqual(failedSession.executions, [])
    XCTAssertEqual(failedSession.currentStepId, "start")
  }

  func testAppendFailureIsObservableAndDoesNotCreateMessages() async throws {
    let store = InMemoryWorkflowRuntimeStore(
      clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 100)),
      appendFailurePredicate: { _ in "sqlite write failed" }
    )
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let execution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(sessionId: session.sessionId, stepId: "start", nodeId: "node-start", attempt: 1)
    )

    do {
      _ = try await store.appendWorkflowMessage(
        WorkflowMessageAppendInput(
          workflowExecutionId: session.sessionId,
          fromStepId: "start",
          toStepId: "next",
          sourceStepExecutionId: execution.executionId,
          payload: ["ok": .bool(true)]
        )
      )
      XCTFail("expected append failure")
    } catch WorkflowRuntimeStoreError.messageAppendRejected(let reason) {
      XCTAssertEqual(reason, "sqlite write failed")
    }

    let listedMessages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(listedMessages, [])
  }

  func testMessageInputResolverFiltersOrdersAndMergesPayloads() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 100)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let startExecution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(sessionId: session.sessionId, stepId: "start", nodeId: "node-start", attempt: 1)
    )
    let branchExecution = try await store.recordStepExecution(
      WorkflowStepExecutionRecordInput(sessionId: session.sessionId, stepId: "branch", nodeId: "node-branch", attempt: 1)
    )

    _ = try await store.appendWorkflowMessage(
      WorkflowMessageAppendInput(
        workflowExecutionId: session.sessionId,
        fromStepId: "start",
        toStepId: "target",
        sourceStepExecutionId: startExecution.executionId,
        payload: ["shared": .string("first"), "startOnly": .bool(true)]
      )
    )
    _ = try await store.appendWorkflowMessage(
      WorkflowMessageAppendInput(
        workflowExecutionId: session.sessionId,
        fromStepId: "start",
        toStepId: "other",
        sourceStepExecutionId: startExecution.executionId,
        payload: ["other": .bool(true)]
      )
    )
    _ = try await store.appendWorkflowMessage(
      WorkflowMessageAppendInput(
        workflowExecutionId: session.sessionId,
        fromStepId: "branch",
        toStepId: "target",
        sourceStepExecutionId: branchExecution.executionId,
        payload: ["shared": .string("second"), "branchOnly": .number(2)]
      )
    )

    let resolved = try await DefaultWorkflowMessageInputResolver().resolveInput(
      for: session.sessionId,
      stepId: "target",
      store: store
    )

    XCTAssertEqual(resolved.workflowExecutionId, session.sessionId)
    XCTAssertEqual(resolved.stepId, "target")
    XCTAssertEqual(resolved.communicationIds, ["comm-000001", "comm-000003"])
    XCTAssertEqual(resolved.messages.map(\.toStepId), ["target", "target"])
    XCTAssertEqual(resolved.sourceStepIds, ["start", "branch"])
    let inputMetadata = try XCTUnwrap(resolved.payload["_rielaInput"])
    XCTAssertEqual(
      resolved.payload,
      [
        "shared": .string("second"),
        "startOnly": .bool(true),
        "branchOnly": .number(2),
        "_rielaInput": inputMetadata
      ]
    )
    XCTAssertEqual(
      inputMetadata,
      .object([
        "workflowExecutionId": .string(session.sessionId),
        "stepId": .string("target"),
        "communicationIds": .array([.string("comm-000001"), .string("comm-000003")]),
        "sourceStepIds": .array([.string("start"), .string("branch")]),
        "messages": .array([
          .object([
            "communicationId": .string("comm-000001"),
            "workflowExecutionId": .string(session.sessionId),
            "fromStepId": .string("start"),
            "toStepId": .string("target"),
            "sourceStepExecutionId": .string(startExecution.executionId),
            "deliveryKind": .string("direct"),
            "routingScope": .string("workflow"),
            "lifecycleStatus": .string("delivered"),
            "createdOrder": .number(1),
            "payload": .object(["shared": .string("first"), "startOnly": .bool(true)])
          ]),
          .object([
            "communicationId": .string("comm-000003"),
            "workflowExecutionId": .string(session.sessionId),
            "fromStepId": .string("branch"),
            "toStepId": .string("target"),
            "sourceStepExecutionId": .string(branchExecution.executionId),
            "deliveryKind": .string("direct"),
            "routingScope": .string("workflow"),
            "lifecycleStatus": .string("delivered"),
            "createdOrder": .number(3),
            "payload": .object(["shared": .string("second"), "branchOnly": .number(2)])
          ])
        ]),
        "latest": .object([
          "communicationId": .string("comm-000003"),
          "workflowExecutionId": .string(session.sessionId),
          "fromStepId": .string("branch"),
          "toStepId": .string("target"),
          "sourceStepExecutionId": .string(branchExecution.executionId),
          "deliveryKind": .string("direct"),
          "routingScope": .string("workflow"),
          "lifecycleStatus": .string("delivered"),
          "createdOrder": .number(3),
          "payload": .object(["shared": .string("second"), "branchOnly": .number(2)])
        ])
      ])
    )

    let adapterInput = resolved.applying(
      to: AdapterExecutionInput(
        node: AgentNodePayload(id: "target", model: "gpt-5"),
        promptText: "prompt",
        mergedVariables: ["existing": .string("kept"), "shared": .string("base")]
      )
    )
    XCTAssertEqual(
      adapterInput.mergedVariables,
      [
        "existing": .string("kept"),
        "shared": .string("second"),
        "startOnly": .bool(true),
        "branchOnly": .number(2),
        "_rielaInput": inputMetadata
      ]
    )
  }

  func testMessageInputResolverUsesOnlyDeliveredAndConsumedMessages() async throws {
    let date = Date(timeIntervalSince1970: 100)
    let messages = [
      message("created", lifecycleStatus: .created, createdOrder: 1, date: date, payload: ["drop": .string("created")]),
      message("delivered", lifecycleStatus: .delivered, createdOrder: 2, date: date, payload: ["keep": .string("delivered")]),
      message("failed", lifecycleStatus: .failed, createdOrder: 3, date: date, payload: ["drop": .string("failed")]),
      message("consumed", lifecycleStatus: .consumed, createdOrder: 4, date: date, payload: ["keep": .string("consumed")]),
      message("superseded", lifecycleStatus: .superseded, createdOrder: 5, date: date, payload: ["drop": .string("superseded")])
    ]
    let store = StaticWorkflowRuntimeStore(sessionId: "session", messages: messages)

    let resolved = try await DefaultWorkflowMessageInputResolver().resolveInput(
      for: "session",
      stepId: "target",
      store: store
    )

    XCTAssertEqual(resolved.communicationIds, ["delivered", "consumed"])
    XCTAssertEqual(resolved.payload["keep"], .string("consumed"))
    XCTAssertEqual(resolved.payload["_rielaInput.latest.payload"], nil)
    XCTAssertEqual(
      resolved.payload["_rielaInput"],
      .object([
        "workflowExecutionId": .string("session"),
        "stepId": .string("target"),
        "communicationIds": .array([.string("delivered"), .string("consumed")]),
        "sourceStepIds": .array([.string("source")]),
        "messages": .array([
          .object([
            "communicationId": .string("delivered"),
            "workflowExecutionId": .string("session"),
            "fromStepId": .string("source"),
            "toStepId": .string("target"),
            "sourceStepExecutionId": .string("source-exec"),
            "deliveryKind": .string("direct"),
            "routingScope": .string("workflow"),
            "lifecycleStatus": .string("delivered"),
            "createdOrder": .number(2),
            "payload": .object(["keep": .string("delivered")])
          ]),
          .object([
            "communicationId": .string("consumed"),
            "workflowExecutionId": .string("session"),
            "fromStepId": .string("source"),
            "toStepId": .string("target"),
            "sourceStepExecutionId": .string("source-exec"),
            "deliveryKind": .string("direct"),
            "routingScope": .string("workflow"),
            "lifecycleStatus": .string("consumed"),
            "createdOrder": .number(4),
            "payload": .object(["keep": .string("consumed")])
          ])
        ]),
        "latest": .object([
          "communicationId": .string("consumed"),
          "workflowExecutionId": .string("session"),
          "fromStepId": .string("source"),
          "toStepId": .string("target"),
          "sourceStepExecutionId": .string("source-exec"),
          "deliveryKind": .string("direct"),
          "routingScope": .string("workflow"),
          "lifecycleStatus": .string("consumed"),
          "createdOrder": .number(4),
          "payload": .object(["keep": .string("consumed")])
        ])
      ])
    )
  }

  private func message(
    _ communicationId: String,
    lifecycleStatus: WorkflowMessageLifecycleStatus,
    createdOrder: Int,
    date: Date,
    payload: JSONObject
  ) -> WorkflowMessageRecord {
    WorkflowMessageRecord(
      communicationId: communicationId,
      workflowExecutionId: "session",
      fromStepId: "source",
      toStepId: "target",
      sourceStepExecutionId: "source-exec",
      payload: payload,
      lifecycleStatus: lifecycleStatus,
      createdOrder: createdOrder,
      createdAt: date
    )
  }
}

private struct StaticWorkflowRuntimeStore: WorkflowRuntimeStore {
  var sessionId: String
  var messages: [WorkflowMessageRecord]

  func createSession(_ input: WorkflowSessionCreateInput) async throws -> WorkflowSession {
    throw WorkflowRuntimeStoreError.messageAppendRejected("static store does not create sessions")
  }

  func recordStepExecution(_ input: WorkflowStepExecutionRecordInput) async throws -> WorkflowStepExecution {
    throw WorkflowRuntimeStoreError.messageAppendRejected("static store does not record executions")
  }

  func updateStepExecution(_ input: WorkflowStepExecutionUpdateInput) async throws -> WorkflowStepExecution {
    throw WorkflowRuntimeStoreError.messageAppendRejected("static store does not update executions")
  }

  func markSessionFailed(_ input: WorkflowSessionFailureInput) async throws -> WorkflowSession {
    throw WorkflowRuntimeStoreError.messageAppendRejected("static store does not fail sessions")
  }

  func recordStepBackendEvent(_ input: WorkflowStepBackendEventInput) async throws -> WorkflowStepExecution {
    throw WorkflowRuntimeStoreError.messageAppendRejected("static store does not record backend events")
  }

  func appendWorkflowMessage(_ input: WorkflowMessageAppendInput) async throws -> WorkflowMessageRecord {
    throw WorkflowRuntimeStoreError.messageAppendRejected("static store does not append messages")
  }

  func appendWorkflowMessages(_ inputs: [WorkflowMessageAppendInput]) async throws -> [WorkflowMessageRecord] {
    throw WorkflowRuntimeStoreError.messageAppendRejected("static store does not append messages")
  }

  func listMessages(for sessionId: String, toStepId: String?) async throws -> [WorkflowMessageRecord] {
    guard sessionId == self.sessionId else {
      throw WorkflowRuntimeStoreError.sessionNotFound(sessionId)
    }
    guard let toStepId else {
      return messages
    }
    return messages.filter { $0.toStepId == toStepId }
  }

  func loadSession(id: String) async throws -> WorkflowSession? {
    nil
  }
}

private final class MutableWorkflowRuntimeClock: WorkflowRuntimeClock, @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) {
    self.date = date
  }

  func set(_ date: Date) {
    lock.lock()
    self.date = date
    lock.unlock()
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return date
  }
}
