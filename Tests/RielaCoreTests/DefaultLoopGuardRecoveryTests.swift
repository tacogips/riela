import Foundation
import XCTest
@testable import RielaCore

final class DefaultLoopGuardRecoveryTests: XCTestCase {
  func testPendingPublicationResumeReusesPersistedSelectionWithoutAdapterOrPredicateReplay() async throws {
    let sourceStore = InMemoryWorkflowRuntimeStore()
    let workflow = Self.workflow()
    let session = try await sourceStore.createSession(WorkflowSessionCreateInput(
      workflowId: workflow.workflowId,
      entryStepId: "review"
    ))
    let execution = try await sourceStore.recordStepExecution(WorkflowStepExecutionRecordInput(
      sessionId: session.sessionId,
      stepId: "review",
      nodeId: "review-node",
      attempt: 1
    ))
    let output = Self.gateOutput(decision: "accepted", findingId: "resolved")
    _ = try await sourceStore.stageWorkflowPublication(WorkflowPublicationStageInput(
      sessionId: session.sessionId,
      executionId: execution.executionId,
      acceptedOutput: WorkflowAcceptedOutputMetadata(
        payload: output.payload,
        when: output.when,
        acceptedAt: Date()
      ),
      adapterOutput: nil,
      usage: nil,
      pendingRoutePublication: WorkflowPendingRoutePublication(
        selectedTransitions: [WorkflowStepTransition(toStepId: "finalize", label: "accepted")],
        publishesRootOutput: false,
        completesRootWithoutOutput: false,
        noSelectionDisposition: .publishPayloadAsRoot,
        intendedSuccessfulStatus: .completed
      )
    ))

    let loadedSnapshot = try await sourceStore.loadSession(id: session.sessionId)
    let snapshot = try XCTUnwrap(loadedSnapshot)
    let resumedStore = InMemoryWorkflowRuntimeStore()
    await resumedStore.seedSession(snapshot)
    let counter = LockedCallCounter()
    let publisher = InMemoryWorkflowOutputPublisher(
      store: resumedStore,
      transitionPredicateEvaluator: { _, _ in
        counter.increment("evaluated")
        return true
      }
    )
    let adapter = PerStepCountingAdapter()
    let result = try await DeterministicWorkflowRunner(
      store: resumedStore,
      adapter: adapter,
      publisher: publisher
    ).run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: Self.nodePayloads(),
      maxSteps: 4,
      resumeSessionId: session.sessionId
    ))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(counter.value, 1, "only the downstream finalize transition is evaluated after recovery")
    let reviewCount = await adapter.count(for: "review")
    XCTAssertEqual(reviewCount, 0)
    XCTAssertEqual(result.session.executions.map(\.stepId), ["review", "finalize", "done"])
  }

  func testConvergenceRedirectOutcomeSurvivesResumeBeforeTerminalExecution() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = Self.workflow()
    let session = try await store.createSession(WorkflowSessionCreateInput(
      workflowId: workflow.workflowId,
      entryStepId: workflow.entryStepId
    ))
    let policyRunner = DeterministicWorkflowRunner(store: store)
    let publisher = InMemoryWorkflowOutputPublisher(store: store)
    let request = DeterministicWorkflowRunRequest(workflow: workflow)
    let review = try XCTUnwrap(workflow.steps.first { $0.id == "review" })
    var redirectResult: WorkflowPublicationResult?

    for attempt in 1...2 {
      redirectResult = try await publisher.publishAcceptedOutput(WorkflowPublicationRequest(
        sessionId: session.sessionId,
        stepId: review.id,
        nodeId: review.nodeId,
        attempt: attempt,
        body: .adapterOutput(Self.gateOutput(decision: "needs_work", findingId: "same")),
        routingReconciler: policyRunner.workflowRoutingReconciler(workflow: workflow, step: review),
        transitions: review.transitions ?? [],
        prePersistenceRoutingDecider: policyRunner.workflowPrePersistenceRoutingDecider(
          workflow: workflow,
          step: review,
          request: request
        )
      ))
    }

    XCTAssertEqual(redirectResult?.nextStepId, "finalize")
    let result = try await DeterministicWorkflowRunner(
      store: store,
      adapter: PerStepCountingAdapter()
    ).run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: Self.nodePayloads(),
      maxSteps: 8,
      resumeSessionId: session.sessionId
    ))

    guard case let .object(outcome)? = result.rootOutput?["loopGuardOutcome"] else {
      return XCTFail("expected convergence outcome after resume")
    }
    XCTAssertEqual(outcome["policySource"], .string("default"))
    XCTAssertEqual(outcome["violationKind"], .string(LoopConvergenceViolationKind.repeatedFindingsStall.rawValue))
  }

  func testReservationRedirectOutcomeSurvivesResumeBeforeTerminalExecution() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = Self.workflow()
    let session = try await store.createSession(WorkflowSessionCreateInput(
      workflowId: workflow.workflowId,
      entryStepId: workflow.entryStepId
    ))
    let policyRunner = DeterministicWorkflowRunner(store: store)
    let redirect = try await policyRunner.redirectForTerminalReservationIfNeeded(
      session: session,
      currentStepId: workflow.entryStepId,
      workflow: workflow,
      request: DeterministicWorkflowRunRequest(workflow: workflow),
      visitedSteps: 5,
      maxSteps: 8
    )
    XCTAssertEqual(redirect?.result.replacementMessage.toStepId, "finalize")

    let result = try await DeterministicWorkflowRunner(
      store: store,
      adapter: PerStepCountingAdapter()
    ).run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: Self.nodePayloads(),
      maxSteps: 8,
      resumeSessionId: session.sessionId
    ))

    guard case let .object(outcome)? = result.rootOutput?["loopGuardOutcome"] else {
      return XCTFail("expected reservation outcome after resume")
    }
    XCTAssertEqual(outcome["policySource"], .string("step-budget"))
    XCTAssertEqual(outcome["trigger"], .string("terminal-step-reserve"))
  }

  func testInputFilterSkippedGateTriggersDefaultVisitCapAndCommitsSkippedStatus() async throws {
    let recorder = WorkflowRunEventRecorder()
    let filtered = WorkflowNodeRegistryRef(
      id: "review-node",
      nodeFile: "nodes/review-node.json",
      inputFilters: [WorkflowInputFilter(
        kind: .telegram,
        expression: "telegram.message.text.includes('@run')"
      )]
    )
    var workflow = Self.workflow()
    workflow.nodeRegistry[0] = filtered
    workflow.steps[0].transitions = [
      WorkflowStepTransition(toStepId: "review", label: "input_filter_skipped"),
      WorkflowStepTransition(toStepId: "finalize", label: "!input_filter_skipped")
    ]
    let adapter = PerStepCountingAdapter()
    let result = try await DeterministicWorkflowRunner(
      store: InMemoryWorkflowRuntimeStore(),
      adapter: adapter,
      inputFilterLogger: NoopWorkflowInputFilterLogger()
    ).run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: Self.nodePayloads(),
      variables: ["telegram": .object(["message": .object(["text": .string("skip")])])],
      maxSteps: 10,
      eventHandler: { await recorder.append($0) }
    ))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.session.executions.prefix(5).map(\.status), Array(repeating: .skipped, count: 5))
    let reviewCount = await adapter.count(for: "review")
    XCTAssertEqual(reviewCount, 0)
    let events = await recorder.events()
    let event = try XCTUnwrap(events.first { $0.type == .loopStall })
    XCTAssertEqual(event.loopStallPayload?.gateVisits, 5)
    XCTAssertEqual(event.loopStallPayload?.policySource, "default")
  }

  func testNativeAddonGateUsesStagedDefaultRoutingWithoutStaleLoopback() async throws {
    var workflow = Self.workflow()
    let addon = WorkflowNodeAddonRef(name: "test/review-addon", version: "1")
    workflow.nodeRegistry[0] = WorkflowNodeRegistryRef(id: "review-node", addon: addon)
    workflow.nodes[0] = WorkflowNodeRef(id: "review-node", addon: addon)
    let resolver = SequencedAddonResolver(outputs: [
      Self.gateOutput(decision: "needs_work", findingId: "same"),
      Self.gateOutput(decision: "needs_work", findingId: "same")
    ])
    let store = InMemoryWorkflowRuntimeStore()
    let result = try await DeterministicWorkflowRunner(
      store: store,
      adapter: PerStepCountingAdapter(),
      addonResolver: resolver
    ).run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: Self.nodePayloads().filter { $0.key != "review-node" },
      maxSteps: 8
    ))

    XCTAssertEqual(result.status, .completed)
    let executionCount = await resolver.executionCount
    XCTAssertEqual(executionCount, 2)
    let reviewMessages = try await store.listMessages(for: result.session.sessionId, toStepId: "review")
    XCTAssertEqual(reviewMessages.count, 1)
    XCTAssertEqual(result.session.executions.map(\.stepId), ["review", "review", "finalize", "done"])
  }

  func testDefaultViolationRejectsSelectedCrossWorkflowAndFanoutBoundaries() async throws {
    let boundaryTransitions = [
      WorkflowStepTransition(
        toStepId: "callee-entry",
        toWorkflowId: "callee",
        resumeStepId: "finalize",
        label: "needs_work"
      ),
      WorkflowStepTransition(
        toStepId: "branch",
        label: "needs_work",
        fanout: WorkflowStepFanout(
          groupId: "guard-boundary",
          itemsFrom: "/items",
          joinStepId: "finalize"
        )
      )
    ]

    for boundaryTransition in boundaryTransitions {
      let workflow = Self.workflowWithDispatchBoundary(boundaryTransition)
      let store = InMemoryWorkflowRuntimeStore()
      let runner = DeterministicWorkflowRunner(store: store)
      let publisher = InMemoryWorkflowOutputPublisher(
        store: store,
        supportsLiveCrossWorkflowDispatch: true
      )
      let session = try await store.createSession(WorkflowSessionCreateInput(
        workflowId: workflow.workflowId,
        entryStepId: workflow.entryStepId
      ))
      let review = try XCTUnwrap(workflow.steps.first { $0.id == "review" })
      var result: WorkflowPublicationResult?

      for attempt in 1...2 {
        result = try await publisher.publishAcceptedOutput(WorkflowPublicationRequest(
          sessionId: session.sessionId,
          stepId: review.id,
          nodeId: review.nodeId,
          attempt: attempt,
          body: .adapterOutput(Self.gateOutput(decision: "needs_work", findingId: "same")),
          routingReconciler: runner.workflowRoutingReconciler(workflow: workflow, step: review),
          transitions: review.transitions ?? [],
          prePersistenceRoutingDecider: runner.workflowPrePersistenceRoutingDecider(
            workflow: workflow,
            step: review,
            request: DeterministicWorkflowRunRequest(workflow: workflow)
          )
        ))
      }

      XCTAssertEqual(result?.loopGuard?.action, .fail)
      XCTAssertEqual(result?.loopGuard?.violation.kind, .repeatedFindingsStall)
      XCTAssertNil(result?.nextStepId)
      XCTAssertEqual(result?.publishedMessages, [])
    }
  }

  func testFailedCommitAndAbortLeaveNoPartialRoute() async throws {
    let store = InMemoryWorkflowRuntimeStore(appendFailurePredicate: {
      $0.toStepId == "second" ? "reject second route" : nil
    })
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "atomic", entryStepId: "review"))
    let execution = try await store.recordStepExecution(WorkflowStepExecutionRecordInput(
      sessionId: session.sessionId,
      stepId: "review",
      nodeId: "review-node",
      attempt: 1
    ))
    _ = try await store.stageWorkflowPublication(Self.stageInput(session: session, execution: execution))
    let commit = WorkflowPublicationCommitInput(
      sessionId: session.sessionId,
      executionId: execution.executionId,
      messageInputs: [
        WorkflowMessageAppendInput(
          workflowExecutionId: session.sessionId,
          fromStepId: "review",
          toStepId: "first",
          sourceStepExecutionId: execution.executionId,
          payload: ["status": .string("accepted")]
        ),
        WorkflowMessageAppendInput(
          workflowExecutionId: session.sessionId,
          fromStepId: "review",
          toStepId: "second",
          sourceStepExecutionId: execution.executionId,
          payload: ["status": .string("accepted")]
        )
      ],
      currentStepId: "finalize",
      publishesRootOutput: false,
      completesRootWithoutOutput: false
    )
    await XCTAssertThrowsErrorAsync(try await store.commitWorkflowPublication(commit))
    let loadedAfterFailure = try await store.loadSession(id: session.sessionId)
    let afterFailure = try XCTUnwrap(loadedAfterFailure)
    XCTAssertEqual(afterFailure.currentStepId, "review")
    XCTAssertEqual(afterFailure.executions[0].status, .running)
    XCTAssertNotNil(afterFailure.executions[0].pendingRoutePublication)
    let messagesAfterFailure = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messagesAfterFailure, [])

    _ = try await store.abortWorkflowPublication(WorkflowPublicationAbortInput(
      sessionId: session.sessionId,
      executionId: execution.executionId,
      reason: "commit failed"
    ))
    let loadedAfterAbort = try await store.loadSession(id: session.sessionId)
    let afterAbort = try XCTUnwrap(loadedAfterAbort)
    XCTAssertEqual(afterAbort.status, .failed)
    XCTAssertNil(afterAbort.executions[0].acceptedOutput)
    XCTAssertNil(afterAbort.executions[0].pendingRoutePublication)
    let messagesAfterAbort = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(messagesAfterAbort, [])
  }

  func testPublisherFirstMatchEvaluatesOnlyThroughSelectedTransition() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "selection", entryStepId: "step"))
    let counter = LockedCallCounter()
    let publisher = InMemoryWorkflowOutputPublisher(
      store: store,
      transitionPredicateEvaluator: { transition, _ in
        counter.increment(transition.toStepId)
        return transition.toStepId == "match"
      }
    )
    let result = try await publisher.publishAcceptedOutput(WorkflowPublicationRequest(
      sessionId: session.sessionId,
      stepId: "step",
      nodeId: "node",
      attempt: 1,
      body: .inlineCandidate([
        "completionPassed": .bool(true),
        "payload": .object(["status": .string("ok")])
      ]),
      transitions: [
        WorkflowStepTransition(toStepId: "miss"),
        WorkflowStepTransition(toStepId: "match"),
        WorkflowStepTransition(toStepId: "unexamined")
      ],
      transitionSelectionMode: .firstMatch
    ))

    XCTAssertEqual(counter.values, ["miss", "match"])
    XCTAssertEqual(result.nextStepId, "match")
    XCTAssertEqual(result.publishedMessages.map(\.toStepId), ["match"])
  }

  func testReservationRejectsStaleRedirectAndSkipsAmbiguousOrNonDefaultPolicies() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: "reserve", entryStepId: "revise"))
    let message = try await store.appendWorkflowMessage(WorkflowMessageAppendInput(
      workflowExecutionId: session.sessionId,
      fromStepId: "source",
      toStepId: "revise",
      sourceStepExecutionId: "source-exec",
      payload: ["value": .string("keep")]
    ))
    let loadedBefore = try await store.loadSession(id: session.sessionId)
    let before = try XCTUnwrap(loadedBefore)
    do {
      _ = try await store.redirectPendingWorkflowStep(WorkflowPendingStepRedirectInput(
        sessionId: session.sessionId,
        expectedCurrentStepId: "revise",
        displacedCommunicationIds: ["foreign"],
        replacementMessage: WorkflowMessageAppendInput(
          workflowExecutionId: session.sessionId,
          fromStepId: "source",
          toStepId: "done",
          sourceStepExecutionId: "source-exec",
          payload: [:]
        )
      ))
      XCTFail("expected stale redirect rejection")
    } catch let error as WorkflowRuntimeStoreError {
      XCTAssertEqual(
        error,
        .messageAppendRejected("displaced messages are stale or foreign")
      )
    } catch {
      XCTFail("unexpected stale redirect error: \(error)")
    }
    let sessionAfterRejection = try await store.loadSession(id: session.sessionId)
    let messagesAfterRejection = try await store.listMessages(for: session.sessionId, toStepId: nil)
    XCTAssertEqual(sessionAfterRejection, before)
    XCTAssertEqual(messagesAfterRejection, [message])

    let ambiguous = Self.ambiguousReservationWorkflow()
    let runner = DeterministicWorkflowRunner(store: store)
    let ambiguousRedirect = try await runner.redirectForTerminalReservationIfNeeded(
      session: before,
      currentStepId: "revise",
      workflow: ambiguous,
      request: DeterministicWorkflowRunRequest(workflow: ambiguous),
      visitedSteps: 0,
      maxSteps: 3
    )
    XCTAssertNil(ambiguousRedirect)
    var authoredInactive = ambiguous
    authoredInactive.loop = WorkflowLoopMetadata(required: false)
    let inactiveRedirect = try await runner.redirectForTerminalReservationIfNeeded(
      session: before,
      currentStepId: "revise",
      workflow: authoredInactive,
      request: DeterministicWorkflowRunRequest(workflow: authoredInactive),
      visitedSteps: 0,
      maxSteps: 3
    )
    XCTAssertNil(inactiveRedirect)
  }

  func testReservationUsesLongCorridorAndRemainsAbsentForOptOutAndInsufficientBudget() async throws {
    let workflow = Self.longReservationWorkflow()
    let store = InMemoryWorkflowRuntimeStore()
    let session = try await store.createSession(WorkflowSessionCreateInput(workflowId: workflow.workflowId, entryStepId: "revise"))
    let runner = DeterministicWorkflowRunner(store: store)

    let redirect = try await runner.redirectForTerminalReservationIfNeeded(
      session: session,
      currentStepId: "revise",
      workflow: workflow,
      request: DeterministicWorkflowRunRequest(workflow: workflow),
      visitedSteps: 0,
      maxSteps: 4
    )
    let routed = try XCTUnwrap(redirect)
    XCTAssertEqual(routed.result.replacementMessage.toStepId, "finalize-a")
    guard case let .object(outcome) = routed.loopGuardOutcome else {
      return XCTFail("expected reservation outcome")
    }
    XCTAssertEqual(outcome["reservedTerminalSteps"], .integer(4))

    let insufficientStore = InMemoryWorkflowRuntimeStore()
    let insufficientSession = try await insufficientStore.createSession(WorkflowSessionCreateInput(
      workflowId: workflow.workflowId,
      entryStepId: "revise"
    ))
    let insufficientRunner = DeterministicWorkflowRunner(store: insufficientStore)
    let insufficient = try await insufficientRunner.redirectForTerminalReservationIfNeeded(
      session: insufficientSession,
      currentStepId: "revise",
      workflow: workflow,
      request: DeterministicWorkflowRunRequest(workflow: workflow),
      visitedSteps: 0,
      maxSteps: 3
    )
    XCTAssertNil(insufficient)
    let optedOut = try await insufficientRunner.redirectForTerminalReservationIfNeeded(
      session: insufficientSession,
      currentStepId: "revise",
      workflow: workflow,
      request: DeterministicWorkflowRunRequest(workflow: workflow, disableDefaultLoopGuard: true),
      visitedSteps: 0,
      maxSteps: 4
    )
    XCTAssertNil(optedOut)

    var declared = workflow
    declared.loop = WorkflowLoopMetadata(convergence: LoopConvergenceDeclaration(maxGateVisits: 4))
    let declaredRedirect = try await insufficientRunner.redirectForTerminalReservationIfNeeded(
      session: insufficientSession,
      currentStepId: "revise",
      workflow: declared,
      request: DeterministicWorkflowRunRequest(workflow: declared),
      visitedSteps: 0,
      maxSteps: 4
    )
    XCTAssertNil(declaredRedirect)
  }

  func testReservationRemainsAbsentForCrossWorkflowAndFanoutBoundaries() async throws {
    let boundaryTransitions = [
      WorkflowStepTransition(
        toStepId: "callee-entry",
        toWorkflowId: "callee",
        resumeStepId: "done"
      ),
      WorkflowStepTransition(
        toStepId: "branch",
        fanout: WorkflowStepFanout(
          groupId: "reserve-boundary",
          itemsFrom: "/items",
          joinStepId: "done"
        )
      )
    ]

    for boundaryTransition in boundaryTransitions {
      let workflow = Self.reservationWorkflowWithDispatchBoundary(boundaryTransition)
      let store = InMemoryWorkflowRuntimeStore()
      let session = try await store.createSession(WorkflowSessionCreateInput(
        workflowId: workflow.workflowId,
        entryStepId: workflow.entryStepId
      ))
      let redirect = try await DeterministicWorkflowRunner(
        store: store
      ).redirectForTerminalReservationIfNeeded(
        session: session,
        currentStepId: workflow.entryStepId,
        workflow: workflow,
        request: DeterministicWorkflowRunRequest(workflow: workflow),
        visitedSteps: 0,
        maxSteps: 3
      )

      XCTAssertNil(redirect)
      let loadedSession = try await store.loadSession(id: session.sessionId)
      XCTAssertEqual(loadedSession?.currentStepId, workflow.entryStepId)
    }
  }

  func testReservationRemainsAbsentWhenInitialBudgetIsBelowReserveFloor() async throws {
    let workflow = Self.shortReservationWorkflow()
    let store = InMemoryWorkflowRuntimeStore()
    let session = try await store.createSession(WorkflowSessionCreateInput(
      workflowId: workflow.workflowId,
      entryStepId: workflow.entryStepId
    ))
    let redirect = try await DeterministicWorkflowRunner(
      store: store
    ).redirectForTerminalReservationIfNeeded(
      session: session,
      currentStepId: workflow.entryStepId,
      workflow: workflow,
      request: DeterministicWorkflowRunRequest(workflow: workflow),
      visitedSteps: 0,
      maxSteps: 1
    )

    XCTAssertNil(redirect)
    let loadedSession = try await store.loadSession(id: session.sessionId)
    XCTAssertEqual(loadedSession?.currentStepId, workflow.entryStepId)
  }
}

private extension DefaultLoopGuardRecoveryTests {
  static func workflow() -> WorkflowDefinition {
    let nodeIds = ["review-node", "finalize-node", "done-node"]
    return WorkflowDefinition(
      workflowId: "default-loop-guard-recovery",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 20),
      entryStepId: "review",
      nodeRegistry: nodeIds.map { WorkflowNodeRegistryRef(id: $0, nodeFile: "nodes/\($0).json") },
      steps: [
        WorkflowStepRef(
          id: "review",
          nodeId: "review-node",
          transitions: [
            WorkflowStepTransition(toStepId: "review", label: "needs_work"),
            WorkflowStepTransition(toStepId: "finalize", label: "accepted")
          ],
          loop: WorkflowStepLoopMetadata(role: "gate", gateId: "implementation-review")
        ),
        WorkflowStepRef(
          id: "finalize",
          nodeId: "finalize-node",
          transitions: [WorkflowStepTransition(toStepId: "done")]
        ),
        WorkflowStepRef(id: "done", nodeId: "done-node")
      ],
      nodes: nodeIds.map { WorkflowNodeRef(id: $0, nodeFile: "nodes/\($0).json") }
    )
  }

  static func ambiguousReservationWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "reserve",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "revise",
      nodeRegistry: ["revise", "left", "right"].map {
        WorkflowNodeRegistryRef(id: "\($0)-node", nodeFile: "nodes/\($0).json")
      },
      steps: [
        WorkflowStepRef(id: "revise", nodeId: "revise-node", transitions: [
          WorkflowStepTransition(toStepId: "left"),
          WorkflowStepTransition(toStepId: "right")
        ]),
        WorkflowStepRef(id: "left", nodeId: "left-node"),
        WorkflowStepRef(id: "right", nodeId: "right-node")
      ],
      nodes: []
    )
  }

  static func workflowWithDispatchBoundary(
    _ boundaryTransition: WorkflowStepTransition
  ) -> WorkflowDefinition {
    let stepIds = ["review", "finalize"]
    return WorkflowDefinition(
      workflowId: "guard-dispatch-boundary",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 20),
      entryStepId: "review",
      nodeRegistry: stepIds.map { WorkflowNodeRegistryRef(id: "\($0)-node", nodeFile: "nodes/\($0).json") },
      steps: [
        WorkflowStepRef(
          id: "review",
          nodeId: "review-node",
          transitions: [
            boundaryTransition,
            WorkflowStepTransition(toStepId: "finalize", label: "accepted")
          ],
          loop: WorkflowStepLoopMetadata(role: "gate", gateId: "implementation-review")
        ),
        WorkflowStepRef(id: "finalize", nodeId: "finalize-node")
      ],
      nodes: []
    )
  }

  static func reservationWorkflowWithDispatchBoundary(
    _ boundaryTransition: WorkflowStepTransition
  ) -> WorkflowDefinition {
    let stepIds = ["revise", "done"]
    return WorkflowDefinition(
      workflowId: "reserve-dispatch-boundary",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "revise",
      nodeRegistry: stepIds.map { WorkflowNodeRegistryRef(id: "\($0)-node", nodeFile: "nodes/\($0).json") },
      steps: [
        WorkflowStepRef(id: "revise", nodeId: "revise-node", transitions: [
          boundaryTransition,
          WorkflowStepTransition(toStepId: "done")
        ]),
        WorkflowStepRef(id: "done", nodeId: "done-node")
      ],
      nodes: []
    )
  }

  static func longReservationWorkflow() -> WorkflowDefinition {
    let stepIds = ["revise", "finalize-a", "finalize-b", "finalize-c", "done"]
    return WorkflowDefinition(
      workflowId: "long-reserve",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "revise",
      nodeRegistry: stepIds.map { WorkflowNodeRegistryRef(id: "\($0)-node", nodeFile: "nodes/\($0).json") },
      steps: [
        WorkflowStepRef(id: "revise", nodeId: "revise-node", transitions: [
          WorkflowStepTransition(toStepId: "revise", label: "needs_work"),
          WorkflowStepTransition(toStepId: "finalize-a", label: "accepted")
        ]),
        WorkflowStepRef(
          id: "finalize-a",
          nodeId: "finalize-a-node",
          transitions: [WorkflowStepTransition(toStepId: "finalize-b")]
        ),
        WorkflowStepRef(
          id: "finalize-b",
          nodeId: "finalize-b-node",
          transitions: [WorkflowStepTransition(toStepId: "finalize-c")]
        ),
        WorkflowStepRef(
          id: "finalize-c",
          nodeId: "finalize-c-node",
          transitions: [WorkflowStepTransition(toStepId: "done")]
        ),
        WorkflowStepRef(id: "done", nodeId: "done-node")
      ],
      nodes: []
    )
  }

  static func shortReservationWorkflow() -> WorkflowDefinition {
    let stepIds = ["revise", "done"]
    return WorkflowDefinition(
      workflowId: "short-reserve",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "revise",
      nodeRegistry: stepIds.map { WorkflowNodeRegistryRef(id: "\($0)-node", nodeFile: "nodes/\($0).json") },
      steps: [
        WorkflowStepRef(id: "revise", nodeId: "revise-node", transitions: [
          WorkflowStepTransition(toStepId: "revise", label: "needs_work"),
          WorkflowStepTransition(toStepId: "done", label: "accepted")
        ]),
        WorkflowStepRef(id: "done", nodeId: "done-node")
      ],
      nodes: []
    )
  }

  static func nodePayloads() -> [String: AgentNodePayload] {
    Dictionary(uniqueKeysWithValues: ["review-node", "finalize-node", "done-node"].map {
      ($0, AgentNodePayload(id: $0, executionBackend: .codexAgent, model: "gpt-5.5"))
    })
  }

  static func gateOutput(decision: String, findingId: String) -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: "test",
      model: "gpt-5.5",
      promptText: "prompt",
      completionPassed: true,
      when: ["needs_work": decision == "needs_work", "accepted": decision == "accepted"],
      payload: [
        "decision": .string(decision),
        "loopGate": .object([
          "gateId": .string("implementation-review"),
          "decision": .string(decision),
          "blockingFindings": .array([.object([
            "id": .string(findingId),
            "severity": .string("high"),
            "message": .string("finding \(findingId)")
          ])])
        ])
      ]
    )
  }

  static func stageInput(
    session: WorkflowSession,
    execution: WorkflowStepExecution
  ) -> WorkflowPublicationStageInput {
    WorkflowPublicationStageInput(
      sessionId: session.sessionId,
      executionId: execution.executionId,
      acceptedOutput: WorkflowAcceptedOutputMetadata(
        payload: ["status": .string("accepted")],
        when: [:],
        acceptedAt: Date()
      ),
      adapterOutput: nil,
      usage: nil,
      pendingRoutePublication: WorkflowPendingRoutePublication(
        selectedTransitions: [WorkflowStepTransition(toStepId: "finalize")],
        publishesRootOutput: false,
        completesRootWithoutOutput: false,
        noSelectionDisposition: .publishPayloadAsRoot,
        intendedSuccessfulStatus: .completed
      )
    )
  }
}

private final class LockedCallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [String] = []

  var value: Int {
    lock.withLock { calls.count }
  }

  var values: [String] {
    lock.withLock { calls }
  }

  func increment(_ value: String) {
    lock.withLock { calls.append(value) }
  }
}

private actor PerStepCountingAdapter: NodeAdapter {
  private var counts: [String: Int] = [:]

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    counts[input.node.id, default: 0] += 1
    return AdapterExecutionOutput(
      provider: "test",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      when: ["always": true],
      payload: ["status": .string("ok")]
    )
  }

  func count(for stepId: String) -> Int { counts[stepId, default: 0] }
}

private actor SequencedAddonResolver: WorkflowAddonResolving {
  private var outputs: [AdapterExecutionOutput]
  private(set) var executionCount = 0

  init(outputs: [AdapterExecutionOutput]) {
    self.outputs = outputs
  }

  func execute(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    executionCount += 1
    guard !outputs.isEmpty else {
      throw AdapterExecutionError(.providerError, "missing add-on test output")
    }
    return outputs.removeFirst()
  }
}
