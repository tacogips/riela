import XCTest
@testable import RielaCore

final class RuntimePublicationTests: XCTestCase {
  func testPublicationRecordsAcceptedOutputAndRuntimeGeneratedMessages() async throws {
    let date = Date(timeIntervalSince1970: 300)
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(date))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let publisher = InMemoryWorkflowOutputPublisher(store: store, clock: FixedWorkflowRuntimeClock(date))

    let result = try await publisher.publishAcceptedOutput(
      WorkflowPublicationRequest(
        sessionId: session.sessionId,
        stepId: "start",
        nodeId: "node-start",
        attempt: 1,
        backend: .codexAgent,
        body: .adapterOutput(AdapterExecutionOutput(
          provider: "codex-agent",
          model: "gpt-5",
          promptText: "prompt",
          completionPassed: true,
          when: ["next": true],
          payload: ["answer": .string("ok")]
        )),
        outputContract: WorkflowOutputContract(requiredObject: true),
        transitions: [WorkflowStepTransition(toStepId: "next", label: "next")]
      )
    )

    XCTAssertEqual(result.stepExecution.status, .completed)
    XCTAssertEqual(result.stepExecution.acceptedOutput?.payload, ["answer": .string("ok")])
    XCTAssertEqual(result.stepExecution.adapterOutput?.provider, "codex-agent")
    XCTAssertEqual(result.publishedMessages.map(\.communicationId), ["comm-000001"])
    XCTAssertEqual(result.publishedMessages.first?.sourceStepExecutionId, result.stepExecution.executionId)
    XCTAssertEqual(result.publishedMessages.first?.payload, ["answer": .string("ok")])
    XCTAssertEqual(result.publishedMessages.first?.lifecycleStatus, .delivered)
    XCTAssertEqual(result.nextStepId, "next")
    XCTAssertEqual(result.session.currentStepId, "next")
    XCTAssertNil(result.rootOutput)
  }

  func testPublicationRecordsExplicitLoopRoutingReconciliationDiagnostic() async throws {
    let date = Date(timeIntervalSince1970: 300)
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(date))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "review"))
    let publisher = InMemoryWorkflowOutputPublisher(store: store, clock: FixedWorkflowRuntimeClock(date))

    let result = try await publisher.publishAcceptedOutput(
      WorkflowPublicationRequest(
        sessionId: session.sessionId,
        stepId: "review",
        nodeId: "review-node",
        attempt: 1,
        body: .adapterOutput(AdapterExecutionOutput(
          provider: "codex-agent",
          model: "gpt-5",
          promptText: "prompt",
          completionPassed: true,
          when: ["always": true],
          payload: [
            "decision": .string("needs_work"),
            "goalAchieved": .bool(false)
          ]
        )),
        routingReconciler: reconcileCompletionReviewRouting,
        transitions: [
          WorkflowStepTransition(toStepId: "rework", label: "needs_work"),
          WorkflowStepTransition(toStepId: "done", label: "accepted")
        ]
      )
    )

    XCTAssertEqual(result.nextStepId, "rework")
    XCTAssertEqual(result.stepExecution.acceptedOutput?.when, ["needs_replan": false, "needs_work": true])
    XCTAssertEqual(result.stepExecution.acceptedOutput?.routingDiagnostics.count, 1)
    XCTAssertTrue(result.stepExecution.acceptedOutput?.routingDiagnostics.first?.contains("reconciled") == true)
  }

  func testValidationFailureMarksStepFailedAndPublishesNoMessages() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let publisher = InMemoryWorkflowOutputPublisher(store: store)

    do {
      _ = try await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: session.sessionId,
          stepId: "start",
          nodeId: "node-start",
          attempt: 1,
          body: .inlineCandidate(["completionPassed": .bool(false), "when": .object(["next": .bool(true)]), "payload": .object(["answer": .string("bad")])]),
          outputContract: WorkflowOutputContract(requiredObject: true),
          transitions: [WorkflowStepTransition(toStepId: "next", label: "next")]
        )
      )
      XCTFail("expected validation failure")
    } catch WorkflowPublicationError.validationRejected(let reason) {
      XCTAssertEqual(reason, "completionPassed is false")
    }

    let listedMessages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    let loadedSession = try await store.loadSession(id: session.sessionId)
    let updatedSession = try XCTUnwrap(loadedSession)
    XCTAssertEqual(listedMessages, [])
    XCTAssertEqual(updatedSession.executions.first?.status, .failed)
  }

  func testMessageAppendFailurePreventsPublicationSuccess() async throws {
    let store = InMemoryWorkflowRuntimeStore(
      clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)),
      appendFailurePredicate: { _ in "message append blocked" }
    )
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let publisher = InMemoryWorkflowOutputPublisher(store: store)

    do {
      _ = try await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: session.sessionId,
          stepId: "start",
          nodeId: "node-start",
          attempt: 1,
          body: .inlineCandidate(["answer": .string("ok")]),
          transitions: [WorkflowStepTransition(toStepId: "next")]
        )
      )
      XCTFail("expected append failure")
    } catch WorkflowRuntimeStoreError.messageAppendRejected(let reason) {
      XCTAssertEqual(reason, "message append blocked")
    }

    let listedMessages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    let loadedSession = try await store.loadSession(id: session.sessionId)
    let updatedSession = try XCTUnwrap(loadedSession)
    XCTAssertEqual(listedMessages, [])
    XCTAssertEqual(updatedSession.executions.first?.status, .failed)
  }

  func testBatchMessageAppendFailureDoesNotLeavePartialMessages() async throws {
    let store = InMemoryWorkflowRuntimeStore(
      clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)),
      appendFailurePredicate: { input in input.toStepId == "second" ? "second append blocked" : nil }
    )
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let publisher = InMemoryWorkflowOutputPublisher(store: store)

    do {
      _ = try await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: session.sessionId,
          stepId: "start",
          nodeId: "node-start",
          attempt: 1,
          body: .inlineCandidate(["answer": .string("ok")]),
          transitions: [
            WorkflowStepTransition(toStepId: "first"),
            WorkflowStepTransition(toStepId: "second")
          ]
        )
      )
      XCTFail("expected append failure")
    } catch WorkflowRuntimeStoreError.messageAppendRejected(let reason) {
      XCTAssertEqual(reason, "second append blocked")
    }

    let listedMessages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(listedMessages, [])
  }

  func testRootOutputComesFromAcceptedOutputWithoutDownstreamMessages() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "output"))
    let publisher = InMemoryWorkflowOutputPublisher(store: store)

    let result = try await publisher.publishAcceptedOutput(
      WorkflowPublicationRequest(
        sessionId: session.sessionId,
        stepId: "output",
        nodeId: "node-output",
        attempt: 1,
        body: .inlineCandidate(["answer": .string("root")]),
        transitions: [],
        publishesRootOutput: true
      )
    )

    XCTAssertEqual(result.rootOutput, ["answer": .string("root")])
    XCTAssertEqual(result.publishedMessages, [])
    XCTAssertEqual(result.session.status, .completed)
  }

  func testNoMatchingConditionalTransitionsCompletesWithRootOutput() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "output"))
    let publisher = InMemoryWorkflowOutputPublisher(store: store)

    let result = try await publisher.publishAcceptedOutput(
      WorkflowPublicationRequest(
        sessionId: session.sessionId,
        stepId: "output",
        nodeId: "node-output",
        attempt: 1,
        body: .inlineCandidate([
          "when": .object(["handoff": .bool(false)]),
          "payload": .object(["answer": .string("done"), "handoff": .bool(false)])
        ]),
        transitions: [WorkflowStepTransition(toStepId: "next", label: "handoff")]
      )
    )

    XCTAssertEqual(result.rootOutput, ["answer": .string("done"), "handoff": .bool(false)])
    XCTAssertEqual(result.publishedMessages, [])
    XCTAssertEqual(result.session.status, .completed)
    XCTAssertEqual(result.stepExecution.acceptedOutput?.isRootOutput, true)
  }

  func testTerminalNonOutputStepDoesNotPublishRootOutput() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "cleanup"))
    let publisher = InMemoryWorkflowOutputPublisher(store: store)

    let result = try await publisher.publishAcceptedOutput(
      WorkflowPublicationRequest(
        sessionId: session.sessionId,
        stepId: "cleanup",
        nodeId: "node-cleanup",
        attempt: 1,
        body: .inlineCandidate(["internal": .bool(true)]),
        transitions: []
      )
    )

    XCTAssertNil(result.rootOutput)
    XCTAssertEqual(result.publishedMessages, [])
    XCTAssertEqual(result.session.status, .running)
    XCTAssertEqual(result.stepExecution.acceptedOutput?.isRootOutput, false)
  }

  func testMissingProviderCandidateMarksStepFailedWithoutPublishingMessages() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let publisher = InMemoryWorkflowOutputPublisher(store: store)

    do {
      _ = try await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: session.sessionId,
          stepId: "start",
          nodeId: "node-start",
          attempt: 1,
          transitions: [WorkflowStepTransition(toStepId: "next")]
        )
      )
      XCTFail("expected missing candidate failure")
    } catch WorkflowPublicationError.noCandidateOutput {}

    let listedMessages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    let loadedSession = try await store.loadSession(id: session.sessionId)
    let updatedSession = try XCTUnwrap(loadedSession)
    XCTAssertEqual(listedMessages, [])
    XCTAssertEqual(updatedSession.executions.first?.status, .failed)
  }

  func testAdapterFailureMarksStepFailedWithoutPublishingMessages() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let publisher = InMemoryWorkflowOutputPublisher(store: store)

    do {
      _ = try await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: session.sessionId,
          stepId: "start",
          nodeId: "node-start",
          attempt: 1,
          backend: .codexAgent,
          body: .failure(AdapterExecutionError(.policyBlocked, "codex login required")),
          transitions: [WorkflowStepTransition(toStepId: "next")]
        )
      )
      XCTFail("expected adapter failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
    }

    let listedMessages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    let loadedSession = try await store.loadSession(id: session.sessionId)
    let updatedSession = try XCTUnwrap(loadedSession)
    XCTAssertEqual(listedMessages, [])
    XCTAssertEqual(updatedSession.executions.first?.status, .failed)
    XCTAssertEqual(updatedSession.executions.first?.failureReason, "policy_blocked: codex login required")
  }

  func testFailurePublicationBodyCanCarryAdapterOutputMetadata() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let publisher = InMemoryWorkflowOutputPublisher(store: store)

    do {
      _ = try await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: session.sessionId,
          stepId: "start",
          nodeId: "node-start",
          attempt: 1,
          body: .failure(
            AdapterExecutionError(.invalidOutput, "bad output"),
            adapterOutput: AdapterExecutionOutput(
              provider: "codex-agent",
              model: "gpt-5",
              promptText: "prompt",
              completionPassed: false,
              when: ["repair": true],
              payload: ["answer": .string("bad")]
            )
          ),
          transitions: [WorkflowStepTransition(toStepId: "next")]
        )
      )
      XCTFail("expected adapter failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidOutput)
    }

    let listedMessages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    let loadedSession = try await store.loadSession(id: session.sessionId)
    let execution = try XCTUnwrap(loadedSession?.executions.first)
    XCTAssertEqual(listedMessages, [])
    XCTAssertEqual(execution.status, .failed)
    XCTAssertEqual(execution.adapterOutput?.provider, "codex-agent")
    XCTAssertEqual(execution.adapterOutput?.completionPassed, false)
    XCTAssertEqual(execution.failureReason, "invalid_output: bad output")
  }

  func testPublicationFinalizesCandidatePathStagingAfterSuccess() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let staging = FileSystemRuntimeCandidatePathStaging(rootDirectory: root, clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)))
    let reservation = try await staging.prepareCandidatePath(sessionId: session.sessionId, stepExecutionId: "exec", attempt: 1)
    try writeCandidate(["answer": .string("ok")], to: reservation.candidatePath)
    let publisher = InMemoryWorkflowOutputPublisher(store: store)

    let result = try await publisher.publishAcceptedOutput(
      WorkflowPublicationRequest(
        sessionId: session.sessionId,
        stepId: "start",
        nodeId: "node-start",
        attempt: 1,
        body: .candidatePath(reservation.candidatePath, reservation),
        transitions: [WorkflowStepTransition(toStepId: "next")]
      )
    )

    XCTAssertEqual(result.stepExecution.status, .completed)
    XCTAssertEqual(result.publishedMessages.map(\.communicationId), ["comm-000001"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: reservation.stagingDirectory.path))
  }

  func testPublicationFinalizesCandidatePathStagingAfterValidationFailure() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let staging = FileSystemRuntimeCandidatePathStaging(rootDirectory: root, clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)))
    let reservation = try await staging.prepareCandidatePath(sessionId: session.sessionId, stepExecutionId: "exec", attempt: 1)
    try Data(#"{"completionPassed":false,"when":{},"payload":{"answer":"bad"}}"#.utf8).write(to: reservation.candidatePath)
    let publisher = InMemoryWorkflowOutputPublisher(store: store)

    do {
      _ = try await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: session.sessionId,
          stepId: "start",
          nodeId: "node-start",
          attempt: 1,
          body: .candidatePath(reservation.candidatePath, reservation),
          outputContract: WorkflowOutputContract(requiredObject: true),
          transitions: [WorkflowStepTransition(toStepId: "next")]
        )
      )
      XCTFail("expected validation failure")
    } catch WorkflowPublicationError.validationRejected(let reason) {
      XCTAssertEqual(reason, "completionPassed is false")
    }

    let listedMessages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(listedMessages, [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: reservation.stagingDirectory.path))
  }

  func testPublicationFinalizesCandidatePathStagingAfterAppendFailure() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = InMemoryWorkflowRuntimeStore(
      clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)),
      appendFailurePredicate: { _ in "append blocked" }
    )
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let staging = FileSystemRuntimeCandidatePathStaging(rootDirectory: root, clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)))
    let reservation = try await staging.prepareCandidatePath(sessionId: session.sessionId, stepExecutionId: "exec", attempt: 1)
    try writeCandidate(["answer": .string("ok")], to: reservation.candidatePath)
    let publisher = InMemoryWorkflowOutputPublisher(store: store)

    do {
      _ = try await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: session.sessionId,
          stepId: "start",
          nodeId: "node-start",
          attempt: 1,
          body: .candidatePath(reservation.candidatePath, reservation),
          transitions: [WorkflowStepTransition(toStepId: "next")]
        )
      )
      XCTFail("expected append failure")
    } catch WorkflowRuntimeStoreError.messageAppendRejected(let reason) {
      XCTAssertEqual(reason, "append blocked")
    }

    let listedMessages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(listedMessages, [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: reservation.stagingDirectory.path))
  }

  func testCrossWorkflowTransitionWithResumeStepPublishesResumeMessage() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let publisher = InMemoryWorkflowOutputPublisher(store: store)

    _ = try await publisher.publishAcceptedOutput(
      WorkflowPublicationRequest(
        sessionId: session.sessionId,
        stepId: "start",
        nodeId: "node-start",
        attempt: 1,
        body: .inlineCandidate(["answer": .string("ok")]),
        transitions: [WorkflowStepTransition(toStepId: "child-start", toWorkflowId: "child-workflow", resumeStepId: "resume")]
      )
    )

    let listedMessages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(listedMessages.map(\.toStepId), ["resume"])
    XCTAssertEqual(listedMessages.first?.payload, ["answer": .string("ok")])
  }

  func testUnsupportedTransitionShapesFailBeforeAcceptedOutputAndMessages() async throws {
    let unsupportedTransitions: [(WorkflowStepTransition, String)] = [
      (
        WorkflowStepTransition(toStepId: "child-start", toWorkflowId: "child-workflow"),
        "cross-workflow transitions are not supported by this in-memory publisher"
      ),
      (
        WorkflowStepTransition(toStepId: "next", resumeStepId: "resume"),
        "resume-step transitions are not supported by this in-memory publisher"
      ),
      (
        WorkflowStepTransition(
          toStepId: "fanout-start",
          fanout: WorkflowStepFanout(groupId: "group", itemsFrom: "items", joinStepId: "join")
        ),
        "fanout transitions are not supported by this in-memory publisher"
      )
    ]

    for (transition, reason) in unsupportedTransitions {
      let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)))
      let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
      let publisher = InMemoryWorkflowOutputPublisher(store: store)

      do {
        _ = try await publisher.publishAcceptedOutput(
          WorkflowPublicationRequest(
            sessionId: session.sessionId,
            stepId: "start",
            nodeId: "node-start",
            attempt: 1,
            body: .inlineCandidate(["answer": .string("ok")]),
            transitions: [transition]
          )
        )
        XCTFail("expected unsupported transition failure")
      } catch WorkflowPublicationError.unsupportedTransition(let actualReason) {
        XCTAssertEqual(actualReason, reason)
      }

      let listedMessages = try await store.listMessages(for: session.sessionId, toStepId: nil)
      let loadedSession = try await store.loadSession(id: session.sessionId)
      let execution = try XCTUnwrap(loadedSession?.executions.first)
      XCTAssertEqual(listedMessages, [])
      XCTAssertEqual(execution.status, .failed)
      XCTAssertNil(execution.acceptedOutput)
      XCTAssertEqual(execution.failureReason, reason)
    }
  }

  private func writeCandidate(_ payload: JSONObject, to url: URL) throws {
    let encoded = try JSONEncoder().encode(JSONValue.object(payload))
    let payloadText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
    try Data(#"{"completionPassed":true,"when":{},"payload":\#(payloadText)}"#.utf8).write(to: url)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  }
}
