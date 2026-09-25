import XCTest
@testable import RielaCore

final class RuntimePublicationTests: XCTestCase {
  func testDeclaredWhenOnlyControlRoutesAndRejectsInvalidPublication() async throws {
    for flag in [false, true] {
      let store = InMemoryWorkflowRuntimeStore()
      let session = try await store.createSession(.init(workflowId: "wf", entryStepId: "start"))
      let result = try await InMemoryWorkflowOutputPublisher(store: store).publishAcceptedOutput(.init(
        sessionId: session.sessionId, stepId: "start", nodeId: "node", attempt: 1,
        body: .adapterOutput(.init(provider: "agent", model: "model", promptText: "", completionPassed: true,
                                   when: ["flag": flag], payload: ["answer": .string("ok")])),
        outputContract: .init(schema: ["required": .array([.string("answer")])], guaranteedWhen: ["flag"]),
        transitions: [.init(toStepId: "next", label: flag ? "flag" : "!flag")]
      ))
      XCTAssertEqual(result.nextStepId, "next")
      XCTAssertEqual(result.publishedMessages.count, 1)
    }

    struct InvalidCandidate {
      var payload: JSONObject
      var when: [String: Bool]
      var reason: String
    }
    let invalid: [InvalidCandidate] = [
      .init(payload: ["answer": .string("ok")], when: [:], reason: "route.missingDeclaredWhen unused"),
      .init(payload: [:], when: ["unused": false], reason: "output contract $.answer required property is missing"),
      .init(payload: ["answer": .string("ok"), "unused": .string("bad")],
            when: ["unused": false], reason: "route.wrongType unused"),
      .init(payload: ["answer": .string("ok"), "unused": .bool(true)],
            when: ["unused": false], reason: "route.conflictingValues unused")
    ]
    for candidate in invalid {
      let store = InMemoryWorkflowRuntimeStore()
      let session = try await store.createSession(.init(workflowId: "wf", entryStepId: "start"))
      let publisher = InMemoryWorkflowOutputPublisher(store: store)
      do {
        _ = try await publisher.publishAcceptedOutput(.init(
          sessionId: session.sessionId, stepId: "start", nodeId: "node", attempt: 1,
          body: .adapterOutput(.init(provider: "agent", model: "model", promptText: "",
                                     completionPassed: true, when: candidate.when, payload: candidate.payload)),
          outputContract: .init(schema: ["required": .array([.string("answer")])],
                                guaranteedWhen: ["unused"]),
          transitions: [.init(toStepId: "next")]
        ))
        XCTFail("expected validation rejection")
      } catch WorkflowPublicationError.validationRejected(let reason) {
        XCTAssertEqual(reason, candidate.reason)
      }
      let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
      XCTAssertEqual(messages, [])
      let loaded = try await store.loadSession(id: session.sessionId)
      XCTAssertNil(loaded?.executions.first?.acceptedOutput)
    }
  }

  func testRouteControlMatrixRejectsBeforeJoinFanoutOrCalleeEffects() async throws {
    struct InvalidControl {
      var payload: JSONObject
      var when: [String: Bool]
      var reason: String
    }
    let invalid = [
      InvalidControl(payload: [:], when: [:], reason: "route.missingControl"),
      InvalidControl(payload: ["flag": .string("true")], when: [:], reason: "route.wrongType"),
      InvalidControl(payload: ["flag": .bool(true)], when: ["flag": false], reason: "route.conflictingValues")
    ]
    let fanout = WorkflowStepTransition(
      toStepId: "child", label: "flag",
      fanout: .init(groupId: "group", itemsFrom: "/payload/items", joinStepId: "join")
    )
    let transitions = [
      WorkflowStepTransition(toStepId: "next", label: "flag"),
      WorkflowStepTransition(toStepId: "child", toWorkflowId: "callee", resumeStepId: "resume", label: "flag"),
      fanout
    ]
    for transition in transitions {
      for control in invalid {
        let store = InMemoryWorkflowRuntimeStore()
        let session = try await store.createSession(.init(workflowId: "wf", entryStepId: "start"))
        let publisher = InMemoryWorkflowOutputPublisher(store: store, simulatesCrossWorkflowDispatch: true)
        do {
          _ = try await publisher.publishAcceptedOutput(.init(
            sessionId: session.sessionId, stepId: "start", nodeId: "node", attempt: 1,
            body: .adapterOutput(.init(provider: "agent", model: "model", promptText: "",
                                       completionPassed: true, when: control.when, payload: control.payload)),
            transitions: [transition]
          ))
          XCTFail("expected \(control.reason) before downstream effect")
        } catch WorkflowPublicationError.validationRejected(let reason) {
          XCTAssertTrue(reason.contains(control.reason), reason)
        }
        let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
        let loaded = try await store.loadSession(id: session.sessionId)
        XCTAssertEqual(messages, [])
        XCTAssertNil(loaded?.executions.first?.acceptedOutput)
        XCTAssertNil(loaded?.executions.first?.pendingRoutePublication)
      }
    }
  }
}

extension RuntimePublicationTests {
  func testPublicationRecordsAcceptedOutputAndRuntimeGeneratedMessages() async throws {
    let date = Date(timeIntervalSince1970: 300)
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(date))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let publisher = InMemoryWorkflowOutputPublisher(store: store, clock: FixedWorkflowRuntimeClock(date))
    let usage = AdapterUsage(
      inputTokens: 12,
      outputTokens: 8,
      totalTokens: 20,
      providerRaw: ["input_tokens": .integer(12), "output_tokens": .integer(8), "total_tokens": .integer(20)]
    )

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
          payload: ["answer": .string("ok")],
          usage: usage
        )),
        outputContract: WorkflowOutputContract(requiredObject: true),
        transitions: [WorkflowStepTransition(toStepId: "next", label: "next")]
      )
    )

    XCTAssertEqual(result.stepExecution.status, .completed)
    XCTAssertEqual(result.stepExecution.acceptedOutput?.payload, ["answer": .string("ok")])
    XCTAssertEqual(result.stepExecution.adapterOutput?.provider, "codex-agent")
    XCTAssertEqual(result.stepExecution.usage, usage)
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
    XCTAssertEqual(result.stepExecution.acceptedOutput?.when, ["needs_replan": false, "needs_work": true, "accepted": false])
    XCTAssertEqual(result.stepExecution.acceptedOutput?.routingDiagnostics.count, 1)
    XCTAssertTrue(result.stepExecution.acceptedOutput?.routingDiagnostics.first?.contains("reconciled") == true)
  }

  func testCompletionReviewReconcilesAllThreeControlsAndIsIdempotent() {
    let cases: [(JSONObject, [String: Bool])] = [
      (["decision": .string("needs_replan")], ["needs_replan": true, "needs_work": false, "accepted": false]),
      (["decision": .string("needs_work")], ["needs_replan": false, "needs_work": true, "accepted": false]),
      (["decision": .string("accepted"), "goalAchieved": .bool(false)], ["needs_replan": false, "needs_work": true, "accepted": false]),
      (["decision": .string("accepted"), "goalAchieved": .bool(true)], ["needs_replan": false, "needs_work": false, "accepted": true])
    ]
    for (payload, expected) in cases {
      var withoutAccepted = expected
      withoutAccepted.removeValue(forKey: "accepted")
      let missing = reconcileCompletionReviewRouting(when: withoutAccepted, payload: payload)
      XCTAssertEqual(missing.when, expected)
      XCTAssertEqual(missing.diagnostics.count, 1)

      var contradictory = expected
      contradictory["accepted"]?.toggle()
      let corrected = reconcileCompletionReviewRouting(when: contradictory, payload: payload)
      XCTAssertEqual(corrected.when, expected)
      XCTAssertEqual(corrected.diagnostics.count, 1)

      let repeated = reconcileCompletionReviewRouting(when: corrected.when, payload: payload)
      XCTAssertEqual(repeated.when, expected)
      XCTAssertTrue(repeated.diagnostics.isEmpty)
    }

    let ordinary = reconcileCompletionReviewRouting(
      when: ["custom": true], payload: ["decision": .string("continue")]
    )
    XCTAssertEqual(ordinary.when, ["custom": true])
    XCTAssertTrue(ordinary.diagnostics.isEmpty)
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

  func testMissingRouteControlRejectsBeforeCandidateFinalizerAndPublication() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/workflow-defect-route-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300))
    let store = InMemoryWorkflowRuntimeStore(clock: clock)
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let staging = FileSystemRuntimeCandidatePathStaging(rootDirectory: root, clock: clock)
    let reservation = try await staging.prepareCandidatePath(
      sessionId: session.sessionId, stepExecutionId: "exec", attempt: 1
    )
    try writeCandidate(["answer": .string("ok")], to: reservation.candidatePath)
    let counter = CandidateFinalizerCounter()
    let publisher = InMemoryWorkflowOutputPublisher(
      store: store,
      candidatePathFinalizer: { _ in await counter.record() }
    )

    do {
      _ = try await publisher.publishAcceptedOutput(WorkflowPublicationRequest(
        sessionId: session.sessionId,
        stepId: "start",
        nodeId: "node-start",
        attempt: 1,
        body: .candidatePath(reservation.candidatePath, reservation),
        transitions: [.init(toStepId: "next", label: "!flag")]
      ))
      XCTFail("expected missing route-control rejection")
    } catch WorkflowPublicationError.validationRejected(let reason) {
      XCTAssertTrue(reason.contains("route.missingControl"))
      XCTAssertTrue(reason.contains("flag"))
    }

    let calls = await counter.calls
    XCTAssertEqual(calls, 0)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
    let loaded = try await store.loadSession(id: session.sessionId)
    XCTAssertEqual(loaded?.executions.first?.status, .failed)
    XCTAssertNil(loaded?.executions.first?.acceptedOutput)
    XCTAssertFalse(FileManager.default.fileExists(atPath: reservation.stagingDirectory.path))
  }

  func testMalformedCandidateDoesNotFinalizeBeforeValidation() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/workflow-defect-malformed-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300))
    let store = InMemoryWorkflowRuntimeStore(clock: clock)
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let staging = FileSystemRuntimeCandidatePathStaging(rootDirectory: root, clock: clock)
    let reservation = try await staging.prepareCandidatePath(
      sessionId: session.sessionId, stepExecutionId: "exec", attempt: 1
    )
    try Data("{".utf8).write(to: reservation.candidatePath)
    let counter = CandidateFinalizerCounter()
    let publisher = InMemoryWorkflowOutputPublisher(
      store: store, candidatePathFinalizer: { _ in await counter.record() }
    )
    do {
      _ = try await publisher.publishAcceptedOutput(WorkflowPublicationRequest(
        sessionId: session.sessionId, stepId: "start", nodeId: "node-start", attempt: 1,
        body: .candidatePath(reservation.candidatePath, reservation)
      ))
      XCTFail("expected malformed candidate rejection")
    } catch RuntimeOutputCandidateError.malformedCandidateJSON {
      // Parsing failed before the candidate could be accepted.
    }
    let calls = await counter.calls
    XCTAssertEqual(calls, 0)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
    let loaded = try await store.loadSession(id: session.sessionId)
    XCTAssertNil(loaded?.executions.first?.acceptedOutput)
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

  func testMultipleDirectTransitionsFailBeforePublishingMessages() async throws {
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
      XCTFail("expected multiple-transition rejection")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidOutput)
      XCTAssertTrue(error.message.contains("multiple direct transitions"))
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

  func testCrossWorkflowTransitionWithResumeStepPublishesResumeMessageWhenSimulationEnabled() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let publisher = InMemoryWorkflowOutputPublisher(store: store, simulatesCrossWorkflowDispatch: true)

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

}

extension RuntimePublicationTests {
  func testFanoutTransitionEmitsDispatchDirectiveWithoutWorkflowMessage() async throws {
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 300)))
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let publisher = InMemoryWorkflowOutputPublisher(store: store)

    let result = try await publisher.publishAcceptedOutput(
      WorkflowPublicationRequest(
        sessionId: session.sessionId,
        stepId: "start",
        nodeId: "node-start",
        attempt: 1,
        body: .inlineCandidate([
          "payload": .object([
            "items": .array([.string("a"), .string("b")])
          ])
        ]),
        transitions: [
          WorkflowStepTransition(
            toStepId: "fanout-start",
            label: "always",
            fanout: WorkflowStepFanout(
              groupId: "group",
              itemsFrom: "/payload/items",
              itemVariable: "item",
              concurrency: 2,
              joinStepId: "join",
              failurePolicy: .collectAll,
              resultOrder: .input,
              writeOwnership: WorkflowFanoutWriteOwnership(mode: .readOnly)
            )
          )
        ]
      )
    )

    XCTAssertEqual(result.publishedMessages, [])
    XCTAssertEqual(result.nextStepId, "fanout-start")
    XCTAssertEqual(result.fanoutDispatch?.groupId, "group")
    XCTAssertEqual(result.fanoutDispatch?.sourceStepId, "start")
    XCTAssertEqual(result.fanoutDispatch?.targetStepId, "fanout-start")
    XCTAssertEqual(result.fanoutDispatch?.joinStepId, "join")
    XCTAssertEqual(result.fanoutDispatch?.itemsFrom, "/payload/items")
    XCTAssertEqual(result.fanoutDispatch?.itemVariable, "item")
    XCTAssertEqual(result.fanoutDispatch?.concurrency, 2)
    XCTAssertEqual(result.fanoutDispatch?.failurePolicy, .collectAll)
    XCTAssertEqual(result.fanoutDispatch?.sourcePayload["payload"], .object([
      "items": .array([.string("a"), .string("b")])
    ]))

    let listedMessages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(listedMessages, [])
  }

  func testFanoutRouteRejectsMissingControlBeforeDispatch() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let publisher = InMemoryWorkflowOutputPublisher(store: store)
    let transition = WorkflowStepTransition(
      toStepId: "fanout-start",
      label: "dispatch_ready",
      fanout: WorkflowStepFanout(
        groupId: "group", itemsFrom: "/payload/items", joinStepId: "join",
        failurePolicy: .collectAll, resultOrder: .input,
        writeOwnership: WorkflowFanoutWriteOwnership(mode: .readOnly)
      )
    )

    do {
      _ = try await publisher.publishAcceptedOutput(WorkflowPublicationRequest(
        sessionId: session.sessionId, stepId: "start", nodeId: "node-start", attempt: 1,
        body: .inlineCandidate(["payload": .object(["items": .array([.string("a")])])]),
        transitions: [transition]
      ))
      XCTFail("expected missing control rejection")
    } catch WorkflowPublicationError.validationRejected(let reason) {
      XCTAssertTrue(reason.contains("route.missingControl"))
      XCTAssertTrue(reason.contains("dispatch_ready"))
    }

    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    let loadedSession = try await store.loadSession(id: session.sessionId)
    let loaded = try XCTUnwrap(loadedSession)
    XCTAssertEqual(messages, [])
    XCTAssertNil(loaded.executions.first?.acceptedOutput)
    XCTAssertNil(loaded.executions.first?.pendingRoutePublication)
  }

  func testRecoveredPublicationRejectsMissingControlBeforeHookAndMessages() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let execution = try await store.recordStepExecution(WorkflowStepExecutionRecordInput(
      sessionId: session.sessionId, stepId: "start", nodeId: "node-start", attempt: 1
    ))
    let transition = WorkflowStepTransition(toStepId: "next", label: "required_flag")
    _ = try await store.stageWorkflowPublication(WorkflowPublicationStageInput(
      sessionId: session.sessionId,
      executionId: execution.executionId,
      acceptedOutput: WorkflowAcceptedOutputMetadata(payload: [:], when: [:], acceptedAt: Date()),
      adapterOutput: nil,
      usage: nil,
      pendingRoutePublication: WorkflowPendingRoutePublication(
        selectedTransitions: [transition], publishesRootOutput: false, completesRootWithoutOutput: false,
        noSelectionDisposition: .publishPayloadAsRoot, intendedSuccessfulStatus: .completed
      )
    ))
    let hookCalls = CandidateFinalizerCounter()
    let publisher = InMemoryWorkflowOutputPublisher(store: store)
    do {
      _ = try await publisher.publishAcceptedOutput(WorkflowPublicationRequest(
        sessionId: session.sessionId, stepId: "start", nodeId: "node-start", attempt: 1,
        transitions: [transition], preCommitPublicationHook: { _ in
          await hookCalls.record()
          return nil
        }
      ))
      XCTFail("expected validation rejection")
    } catch WorkflowPublicationError.validationRejected(let reason) {
      XCTAssertTrue(reason.contains("route.missingControl"))
    }
    let calls = await hookCalls.calls
    XCTAssertEqual(calls, 0)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
    let loaded = try await store.loadSession(id: session.sessionId)
    XCTAssertNil(loaded?.executions.first?.pendingRoutePublication)
    XCTAssertNotEqual(loaded?.executions.first?.status, .completed)
  }

  func testRecoveredPublicationRejectsWrongTypeAndConflictBeforeHook() async throws {
    let candidates = [
      WorkflowAcceptedOutputMetadata(payload: ["flag": .string("true")], when: [:], acceptedAt: Date()),
      WorkflowAcceptedOutputMetadata(payload: ["flag": .bool(true)], when: ["flag": false], acceptedAt: Date())
    ]
    for candidate in candidates {
      let store = InMemoryWorkflowRuntimeStore()
      let session = try await store.createSession(.init(workflowId: "wf", entryStepId: "start"))
      let execution = try await store.recordStepExecution(.init(
        sessionId: session.sessionId, stepId: "start", nodeId: "node", attempt: 1
      ))
      let transition = WorkflowStepTransition(toStepId: "next", label: "flag")
      _ = try await store.stageWorkflowPublication(.init(
        sessionId: session.sessionId, executionId: execution.executionId,
        acceptedOutput: candidate, adapterOutput: nil, usage: nil,
        pendingRoutePublication: .init(
          selectedTransitions: [transition], publishesRootOutput: false,
          completesRootWithoutOutput: false, noSelectionDisposition: .publishPayloadAsRoot,
          intendedSuccessfulStatus: .completed
        )
      ))
      let hookCalls = CandidateFinalizerCounter()
      let publisher = InMemoryWorkflowOutputPublisher(store: store)
      do {
        _ = try await publisher.publishAcceptedOutput(.init(
          sessionId: session.sessionId, stepId: "start", nodeId: "node", attempt: 1,
          transitions: [transition], preCommitPublicationHook: { _ in
            await hookCalls.record()
            return nil
          }
        ))
        XCTFail("expected recovered control rejection")
      } catch WorkflowPublicationError.validationRejected(let reason) {
        XCTAssertTrue(reason.contains("route.wrongType") || reason.contains("route.conflictingValues"), reason)
      }
      let calls = await hookCalls.calls
      let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
      let loaded = try await store.loadSession(id: session.sessionId)
      XCTAssertEqual(calls, 0)
      XCTAssertEqual(messages, [])
      XCTAssertNil(loaded?.executions.first?.pendingRoutePublication)
    }
  }

  func testCarriedPayloadCannotShadowProducerRoutingControl() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "wf", entryStepId: "start"))
    let publisher = InMemoryWorkflowOutputPublisher(store: store)
    do {
      _ = try await publisher.publishAcceptedOutput(WorkflowPublicationRequest(
        sessionId: session.sessionId, stepId: "start", nodeId: "node-start", attempt: 1,
        body: .inlineCandidate(["flag": .bool(true)]),
        transitions: [.init(toStepId: "next", label: "flag")],
        carriedPayloadFields: ["flag": .bool(false)]
      ))
      XCTFail("expected shadowing rejection")
    } catch WorkflowPublicationError.validationRejected(let reason) {
      XCTAssertTrue(reason.contains("route.conflictingValues"))
    }
    let messages = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messages, [])
    let loaded = try await store.loadSession(id: session.sessionId)
    XCTAssertNil(loaded?.executions.first?.acceptedOutput)
  }

  func testUnsupportedTransitionShapesFailBeforeAcceptedOutputAndMessages() async throws {
    let unsupportedTransitions: [(WorkflowStepTransition, String)] = [
      (
        WorkflowStepTransition(toStepId: "child-start", toWorkflowId: "child-workflow"),
        "cross-workflow transitions are not supported by this in-memory publisher"
      ),
      (
        WorkflowStepTransition(toStepId: "child-start", toWorkflowId: "child-workflow", resumeStepId: "resume"),
        "cross-workflow dispatch requires a callee workflow resolver; live runs without one cannot dispatch 'child-workflow'"
      ),
      (
        WorkflowStepTransition(toStepId: "next", resumeStepId: "resume"),
        "resume-step transitions are not supported by this in-memory publisher"
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

private actor CandidateFinalizerCounter {
  private(set) var calls = 0

  func record() {
    calls += 1
  }
}
