import XCTest
@testable import RielaCore

final class DefaultLoopGuardTests: XCTestCase {
  func testEffectivePolicyResolutionPreservesAllFourStates() {
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore())

    let defaultPolicy = runner.effectiveLoopConvergencePolicy(workflow: workflow(loop: nil))
    XCTAssertEqual(defaultPolicy.source, .defaultPolicy)
    XCTAssertEqual(defaultPolicy.declaration?.maxGateVisits, 4)
    XCTAssertEqual(defaultPolicy.declaration?.maxRepeatedFindingRounds, 2)

    let cliDisabled = runner.effectiveLoopConvergencePolicy(
      workflow: workflow(loop: nil),
      disableDefaultLoopGuard: true
    )
    XCTAssertNil(cliDisabled.declaration)

    let authoredInactive = runner.effectiveLoopConvergencePolicy(
      workflow: workflow(loop: WorkflowLoopMetadata(required: false))
    )
    XCTAssertNil(authoredInactive.declaration)

    let declared = runner.effectiveLoopConvergencePolicy(workflow: workflow(loop: WorkflowLoopMetadata(
      convergence: LoopConvergenceDeclaration(maxGateVisits: 9)
    )))
    XCTAssertEqual(declared.source, .declared)
    XCTAssertEqual(declared.declaration?.maxGateVisits, 9)

    let declarationDisabled = runner.effectiveLoopConvergencePolicy(workflow: workflow(loop: WorkflowLoopMetadata(
      convergence: LoopConvergenceDeclaration(enabled: false)
    )))
    XCTAssertNil(declarationDisabled.declaration)
  }

  func testDisabledConvergenceDecodesWithoutBoundsAndLegacyDeclarationDefaultsEnabled() throws {
    let disabled = try JSONDecoder().decode(
      LoopConvergenceDeclaration.self,
      from: Data(#"{"enabled":false}"#.utf8)
    )
    XCTAssertFalse(disabled.enabled)
    XCTAssertNil(disabled.maxGateVisits)
    XCTAssertNil(disabled.maxRepeatedFindingRounds)

    let legacy = try JSONDecoder().decode(
      LoopConvergenceDeclaration.self,
      from: Data(#"{"maxGateVisits":4}"#.utf8)
    )
    XCTAssertTrue(legacy.enabled)
  }

  func testValidationAcceptsDisabledDeclarationAndRejectsContradictoryBounds() {
    let accepted = validateAuthoredWorkflowData(workflowData(convergence: #"{"enabled":false}"#))
    XCTAssertTrue(accepted.diagnostics.filter { $0.severity == .error }.isEmpty)

    let rejected = validateAuthoredWorkflowData(workflowData(
      convergence: #"{"enabled":false,"maxGateVisits":4}"#
    ))
    XCTAssertTrue(rejected.diagnostics.contains {
      $0.path == "workflow.loop.convergence"
    })
  }

  func testTerminalCorridorSelectsSharedSuffixAndRejectsDistinctSinks() {
    let shared = workflow(
      loop: nil,
      steps: [
        step("review", transitions: [transition("left"), transition("right")], gate: true),
        step("left", transitions: [transition("finalize")]),
        step("right", transitions: [transition("finalize")]),
        step("finalize", transitions: [transition("done")]),
        step("done")
      ]
    )
    XCTAssertEqual(
      LoopTerminalCorridorSelector().select(workflow: shared, originStepId: "review"),
      LoopTerminalCorridor(entryStepId: "finalize", stepIds: ["finalize", "done"])
    )

    let ambiguous = workflow(
      loop: nil,
      steps: [
        step("review", transitions: [transition("left"), transition("right")], gate: true),
        step("left"),
        step("right")
      ]
    )
    XCTAssertNil(LoopTerminalCorridorSelector().select(workflow: ambiguous, originStepId: "review"))
  }

  func testDefaultRepeatedFindingViolationRoutesToTerminalCorridor() async throws {
    let recorder = WorkflowRunEventRecorder()
    let adapter = GateSequenceAdapter(reviewOutputs: [gateOutput(findingId: "same"), gateOutput(findingId: "same")])
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter)

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow(loop: nil),
      nodePayloads: nodePayloads(),
      maxSteps: 8,
      eventHandler: { await recorder.append($0) }
    ))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(
      result.session.executions.first?.acceptedOutput?.when,
      ["needs_replan": false, "needs_work": true]
    )
    XCTAssertEqual(result.session.executions.map(\.stepId), ["review", "review", "finalize", "done"])
    guard case let .object(outcome)? = result.rootOutput?["loopGuardOutcome"] else {
      return XCTFail("expected loopGuardOutcome")
    }
    XCTAssertEqual(outcome["decision"], .string("accept-with-residual-risks"))
    XCTAssertEqual(outcome["policySource"], .string("default"))
    XCTAssertEqual(outcome["gateId"], .string("implementation-review"))
    XCTAssertEqual(outcome["violationKind"], .string(LoopConvergenceViolationKind.repeatedFindingsStall.rawValue))
    XCTAssertEqual(outcome["gateVisits"], .integer(2))
    XCTAssertEqual(outcome["repeatedRounds"], .integer(2))
    guard case let .array(outcomeFingerprints)? = outcome["findingFingerprints"] else {
      return XCTFail("expected findingFingerprints")
    }
    let fingerprintValues = outcomeFingerprints.compactMap { value -> String? in
      guard case let .string(fingerprint) = value else {
        return nil
      }
      return fingerprint
    }
    XCTAssertEqual(outcomeFingerprints.count, 1)
    XCTAssertFalse(fingerprintValues.first?.isEmpty ?? true)
    XCTAssertEqual(
      outcome["residualRisks"],
      .array([.string("default loop convergence guard stopped further revision")])
    )
    let events = await recorder.events()
    let event = try XCTUnwrap(events.first { $0.type == .loopStall })
    XCTAssertEqual(event.loopStallPayload?.gateId, "implementation-review")
    XCTAssertEqual(event.loopStallPayload?.violationKind, LoopConvergenceViolationKind.repeatedFindingsStall.rawValue)
    XCTAssertEqual(event.loopStallPayload?.gateVisits, 2)
    XCTAssertEqual(event.loopStallPayload?.repeatedRounds, 2)
    XCTAssertEqual(event.loopStallPayload?.fingerprints.count, 1)
    XCTAssertEqual(event.loopStallPayload?.fingerprints, fingerprintValues)
    XCTAssertEqual(event.loopStallPayload?.policySource, "default")
    XCTAssertEqual(event.loopStallPayload?.action, "accept-with-residual-risks")
  }

  func testDefaultVisitCapTriggersOnFifthUniqueFinding() async throws {
    let recorder = WorkflowRunEventRecorder()
    let adapter = GateSequenceAdapter(reviewOutputs: (1...5).map { gateOutput(findingId: "finding-\($0)") })
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter)

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow(loop: nil),
      nodePayloads: nodePayloads(),
      maxSteps: 10,
      eventHandler: { await recorder.append($0) }
    ))

    XCTAssertEqual(result.status, .completed)
    let events = await recorder.events()
    let event = try XCTUnwrap(events.first { $0.type == .loopStall })
    XCTAssertEqual(event.loopStallPayload?.gateId, "implementation-review")
    XCTAssertEqual(event.loopStallPayload?.violationKind, LoopConvergenceViolationKind.gateVisitsExceeded.rawValue)
    XCTAssertEqual(event.loopStallPayload?.gateVisits, 5)
    XCTAssertEqual(event.loopStallPayload?.repeatedRounds, 1)
    XCTAssertEqual(event.loopStallPayload?.fingerprints.count, 1)
    XCTAssertFalse(event.loopStallPayload?.fingerprints.first?.isEmpty ?? true)
    XCTAssertEqual(event.loopStallPayload?.policySource, "default")
    XCTAssertEqual(event.loopStallPayload?.action, "accept-with-residual-risks")
  }

  func testDefaultViolationUsesPersistedSelectedBranchForDistinctTerminalSinks() async throws {
    let branchWorkflow = workflow(loop: nil, steps: [
      step("review", transitions: [
        transition("review", label: "needs_work"),
        transition("accepted-output", label: "!needs_work && !needs_replan"),
        transition("rejected-output", label: "needs_replan")
      ], gate: true),
      step("accepted-output"),
      step("rejected-output")
    ])
    let adapter = GateSequenceAdapter(reviewOutputs: [
      gateOutput(findingId: "finding-1"),
      gateOutput(findingId: "finding-2"),
      gateOutput(findingId: "finding-3"),
      gateOutput(findingId: "finding-4"),
      gateOutput(decision: "accepted", findingId: "resolved")
    ])
    let payloads = Dictionary(uniqueKeysWithValues: branchWorkflow.steps.map {
      ($0.nodeId, nodePayload($0.nodeId))
    })

    let result = try await DeterministicWorkflowRunner(
      store: InMemoryWorkflowRuntimeStore(),
      adapter: adapter
    ).run(DeterministicWorkflowRunRequest(
      workflow: branchWorkflow,
      nodePayloads: payloads,
      maxSteps: 10
    ))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(
      result.session.executions.map(\.stepId),
      ["review", "review", "review", "review", "review", "accepted-output"]
    )
    XCTAssertFalse(result.session.executions.contains { $0.stepId == "rejected-output" })
    guard case let .object(outcome)? = result.rootOutput?["loopGuardOutcome"] else {
      return XCTFail("expected selected-branch loopGuardOutcome")
    }
    XCTAssertEqual(outcome["policySource"], .string("default"))
    XCTAssertEqual(outcome["violationKind"], .string(LoopConvergenceViolationKind.gateVisitsExceeded.rawValue))
  }

  func testLoopStallEventAndOutcomeBoundFindingFingerprints() async throws {
    let recorder = WorkflowRunEventRecorder()
    let findingIds = (1...12).map { "finding-\($0)" }
    let output = gateOutput(findingIds: findingIds)
    let result = try await DeterministicWorkflowRunner(
      store: InMemoryWorkflowRuntimeStore(),
      adapter: GateSequenceAdapter(reviewOutputs: [output, output])
    ).run(DeterministicWorkflowRunRequest(
      workflow: workflow(loop: nil),
      nodePayloads: nodePayloads(),
      maxSteps: 8,
      eventHandler: { await recorder.append($0) }
    ))

    let events = await recorder.events()
    let event = try XCTUnwrap(events.first { $0.type == .loopStall })
    XCTAssertEqual(event.loopStallPayload?.fingerprints.count, 8)
    guard case let .object(outcome)? = result.rootOutput?["loopGuardOutcome"],
          case let .array(fingerprints)? = outcome["findingFingerprints"] else {
      return XCTFail("expected bounded finding fingerprints")
    }
    XCTAssertEqual(fingerprints.count, 8)
  }

  func testCLIOptOutAndExplicitDeclarationOverrideDefaultPolicy() async throws {
    let disabledAdapter = GateSequenceAdapter(reviewOutputs: [
      gateOutput(findingId: "same"),
      gateOutput(findingId: "same"),
      gateOutput(decision: "accepted", findingId: "resolved")
    ])
    let disabled = try await DeterministicWorkflowRunner(
      store: InMemoryWorkflowRuntimeStore(),
      adapter: disabledAdapter
    ).run(DeterministicWorkflowRunRequest(
      workflow: workflow(loop: nil),
      nodePayloads: nodePayloads(),
      maxSteps: 8,
      disableDefaultLoopGuard: true
    ))
    XCTAssertEqual(disabled.session.executions.map(\.stepId), ["review", "review", "review", "finalize", "done"])

    let declaredAdapter = GateSequenceAdapter(reviewOutputs: [
      gateOutput(findingId: "same"),
      gateOutput(findingId: "same"),
      gateOutput(decision: "accepted", findingId: "resolved")
    ])
    let declared = try await DeterministicWorkflowRunner(
      store: InMemoryWorkflowRuntimeStore(),
      adapter: declaredAdapter
    ).run(DeterministicWorkflowRunRequest(
      workflow: workflow(loop: WorkflowLoopMetadata(
        convergence: LoopConvergenceDeclaration(maxRepeatedFindingRounds: 3)
      )),
      nodePayloads: nodePayloads(),
      maxSteps: 8
    ))
    XCTAssertEqual(declared.status, .completed)
    XCTAssertEqual(declared.session.executions.map(\.stepId), ["review", "review", "review", "finalize", "done"])
  }

  func testDeclarationOptOutDisablesDefaultGuardEndToEnd() async throws {
    let recorder = WorkflowRunEventRecorder()
    let adapter = GateSequenceAdapter(reviewOutputs: [
      gateOutput(findingId: "same"),
      gateOutput(findingId: "same"),
      gateOutput(decision: "accepted", findingId: "resolved")
    ])
    let disabledWorkflow = workflow(loop: WorkflowLoopMetadata(
      convergence: LoopConvergenceDeclaration(enabled: false)
    ))

    let result = try await DeterministicWorkflowRunner(
      store: InMemoryWorkflowRuntimeStore(),
      adapter: adapter
    ).run(DeterministicWorkflowRunRequest(
      workflow: disabledWorkflow,
      nodePayloads: nodePayloads(),
      maxSteps: 8,
      eventHandler: { await recorder.append($0) }
    ))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.session.executions.map(\.stepId), ["review", "review", "review", "finalize", "done"])
    XCTAssertNil(result.rootOutput?["loopGuardOutcome"])
    let events = await recorder.events()
    XCTAssertFalse(events.contains { $0.type == .loopStall })
  }

  func testDefaultViolationWithoutTerminalCorridorFailsWithoutStaleRoute() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = workflow(loop: nil, steps: [
      step("review", transitions: [transition("review", label: "needs_work")], gate: true)
    ])
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: GateSequenceAdapter(reviewOutputs: [gateOutput(findingId: "same"), gateOutput(findingId: "same")])
    )

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: workflow,
        nodePayloads: ["review-node": nodePayload("review-node")],
        maxSteps: 4
      ))
      XCTFail("expected deterministic no-corridor failure")
    } catch let error as DeterministicWorkflowRunner.LoopConvergenceError {
      XCTAssertEqual(error.violation.kind, .repeatedFindingsStall)
    }

    let storedSession = await store.latestSession(workflowId: "default-loop-guard")
    let session = try XCTUnwrap(storedSession)
    let messages = try await store.listMessages(for: session.sessionId, toStepId: "review")
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?.sourceStepExecutionId, session.executions.first?.executionId)
    XCTAssertNotEqual(messages.first?.sourceStepExecutionId, session.executions.last?.executionId)
  }

  func testTerminalReservationRedirectsBeforeNonTerminalDispatch() async throws {
    let adapter = GateSequenceAdapter(reviewOutputs: [])
    let runner = DeterministicWorkflowRunner(store: InMemoryWorkflowRuntimeStore(), adapter: adapter)
    let revisionWorkflow = workflow(loop: nil, entryStepId: "revise", steps: [
      step("revise", transitions: [transition("revise"), transition("finalize")]),
      step("finalize", transitions: [transition("done")]),
      step("done")
    ])

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: revisionWorkflow,
      nodePayloads: nodePayloads(includeRevise: true),
      maxSteps: 3
    ))

    XCTAssertEqual(result.session.executions.map(\.stepId), ["finalize", "done"])
    let reviseCount = await adapter.executionCount(for: "revise")
    XCTAssertEqual(reviseCount, 0)
    guard case let .object(outcome)? = result.rootOutput?["loopGuardOutcome"] else {
      return XCTFail("expected reserve loopGuardOutcome")
    }
    XCTAssertEqual(outcome["trigger"], .string("terminal-step-reserve"))
  }

  func testStagedPublicationCommitIsIdempotentAndPersistsSelectedRoute() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let store = InMemoryWorkflowRuntimeStore(clock: FixedWorkflowRuntimeClock(date))
    let session = try await store.createSession(WorkflowSessionCreateInput(
      workflowId: "staged-publication",
      entryStepId: "review"
    ))
    let execution = try await store.recordStepExecution(WorkflowStepExecutionRecordInput(
      sessionId: session.sessionId,
      stepId: "review",
      nodeId: "review-node",
      attempt: 1
    ))
    let transition = WorkflowStepTransition(toStepId: "finalize", label: "loop_guard_terminal")
    let pending = WorkflowPendingRoutePublication(
      selectedTransitions: [transition],
      publishesRootOutput: false,
      completesRootWithoutOutput: false,
      noSelectionDisposition: .publishPayloadAsRoot,
      intendedSuccessfulStatus: .completed
    )
    let stageInput = WorkflowPublicationStageInput(
      sessionId: session.sessionId,
      executionId: execution.executionId,
      acceptedOutput: WorkflowAcceptedOutputMetadata(
        payload: ["decision": .string("needs_work")],
        when: ["needs_work": true],
        acceptedAt: date
      ),
      adapterOutput: nil,
      usage: nil,
      pendingRoutePublication: pending
    )

    let firstStage = try await store.stageWorkflowPublication(stageInput)
    let secondStage = try await store.stageWorkflowPublication(stageInput)
    XCTAssertEqual(firstStage.execution.status, .running)
    XCTAssertEqual(secondStage.execution.pendingRoutePublication, pending)

    let commitInput = WorkflowPublicationCommitInput(
      sessionId: session.sessionId,
      executionId: execution.executionId,
      messageInputs: [WorkflowMessageAppendInput(
        workflowExecutionId: session.sessionId,
        fromStepId: "review",
        toStepId: "finalize",
        sourceStepExecutionId: execution.executionId,
        transitionCondition: transition.label,
        payload: ["loopGuardOutcome": .object(["decision": .string("accept-with-residual-risks")])]
      )],
      currentStepId: "finalize",
      publishesRootOutput: false,
      completesRootWithoutOutput: false
    )
    let firstCommit = try await store.commitWorkflowPublication(commitInput)
    let secondCommit = try await store.commitWorkflowPublication(commitInput)

    XCTAssertEqual(firstCommit.execution.status, .completed)
    XCTAssertNil(firstCommit.execution.pendingRoutePublication)
    XCTAssertEqual(firstCommit.session.currentStepId, "finalize")
    XCTAssertEqual(firstCommit.messages.count, 1)
    XCTAssertEqual(secondCommit.messages, firstCommit.messages)
    let storedMessages = try await store.listMessages(for: session.sessionId, toStepId: "finalize")
    XCTAssertEqual(storedMessages.count, 1)

    let mismatchedCommit = WorkflowPublicationCommitInput(
      sessionId: session.sessionId,
      executionId: execution.executionId,
      messageInputs: commitInput.messageInputs,
      currentStepId: "different-step",
      publishesRootOutput: false,
      completesRootWithoutOutput: false
    )
    do {
      _ = try await store.commitWorkflowPublication(mismatchedCommit)
      XCTFail("expected mismatched committed publication retry to fail")
    } catch let error as WorkflowRuntimeStoreError {
      XCTAssertEqual(
        error,
        .messageAppendRejected("committed publication does not match retry input")
      )
    }
    let loadedSessionAfterMismatch = try await store.loadSession(id: session.sessionId)
    let sessionAfterMismatch = try XCTUnwrap(loadedSessionAfterMismatch)
    let messagesAfterMismatch = try await store.listMessages(for: session.sessionId, toStepId: "finalize")
    XCTAssertEqual(sessionAfterMismatch, firstCommit.session)
    XCTAssertEqual(messagesAfterMismatch, storedMessages)
  }

  func testRuntimeStoreDefaultPublicationTransactionsFailClosed() async throws {
    let store = NonTransactionalWorkflowRuntimeStore()
    do {
      _ = try await store.commitWorkflowPublication(WorkflowPublicationCommitInput(
        sessionId: "session",
        executionId: "execution",
        messageInputs: [],
        currentStepId: nil,
        publishesRootOutput: false,
        completesRootWithoutOutput: false
      ))
      XCTFail("expected unavailable atomic commit to fail closed")
    } catch let error as WorkflowRuntimeStoreError {
      XCTAssertEqual(
        error,
        .messageAppendRejected("atomic publication commit is unavailable for this runtime store")
      )
    }
  }
}

private struct NonTransactionalWorkflowRuntimeStore: WorkflowRuntimeStore {
  func createSession(_ input: WorkflowSessionCreateInput) async throws -> WorkflowSession { throw unavailable }
  func recordStepExecution(_ input: WorkflowStepExecutionRecordInput) async throws -> WorkflowStepExecution {
    throw unavailable
  }
  func updateStepExecution(_ input: WorkflowStepExecutionUpdateInput) async throws -> WorkflowStepExecution {
    throw unavailable
  }
  func markSessionFailed(_ input: WorkflowSessionFailureInput) async throws -> WorkflowSession { throw unavailable }
  func recordStepBackendEvent(_ input: WorkflowStepBackendEventInput) async throws -> WorkflowStepExecution {
    throw unavailable
  }
  func appendWorkflowMessage(_ input: WorkflowMessageAppendInput) async throws -> WorkflowMessageRecord {
    throw unavailable
  }
  func appendWorkflowMessages(_ inputs: [WorkflowMessageAppendInput]) async throws -> [WorkflowMessageRecord] {
    throw unavailable
  }
  func listMessages(for sessionId: String, toStepId: String?) async throws -> [WorkflowMessageRecord] { [] }
  func loadSession(id: String) async throws -> WorkflowSession? { nil }

  private var unavailable: WorkflowRuntimeStoreError {
    .messageAppendRejected("non-transactional store")
  }
}

private extension DefaultLoopGuardTests {
  func workflowData(convergence: String) -> Data {
    Data("""
      {
        "workflowId":"validation",
        "defaults":{"nodeTimeoutMs":120000,"maxLoopIterations":3},
        "entryStepId":"review",
        "loop":{
          "convergence":\(convergence),
          "gates":[{"id":"implementation-review","stepId":"review"}]
        },
        "nodes":[{"id":"review-node","nodeFile":"nodes/review.json"}],
        "steps":[{
          "id":"review",
          "nodeId":"review-node",
          "loop":{"role":"gate","gateId":"implementation-review"}
        }]
      }
      """.utf8)
  }

  func workflow(
    loop: WorkflowLoopMetadata?,
    entryStepId: String = "review",
    steps: [WorkflowStepRef]? = nil
  ) -> WorkflowDefinition {
    let workflowSteps = steps ?? [
      step("review", transitions: [
        transition("review", label: "needs_work"),
        transition("finalize", label: "!needs_work && !needs_replan")
      ], gate: true),
      step("finalize", transitions: [transition("done")]),
      step("done")
    ]
    let nodeIds = Set(workflowSteps.map(\.nodeId)).sorted()
    return WorkflowDefinition(
      workflowId: "default-loop-guard",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 20),
      entryStepId: entryStepId,
      nodeRegistry: nodeIds.map { WorkflowNodeRegistryRef(id: $0, nodeFile: "nodes/\($0).json") },
      steps: workflowSteps,
      nodes: nodeIds.map { WorkflowNodeRef(id: $0, nodeFile: "nodes/\($0).json") },
      loop: loop
    )
  }

  func step(
    _ id: String,
    transitions: [WorkflowStepTransition]? = nil,
    gate: Bool = false
  ) -> WorkflowStepRef {
    WorkflowStepRef(
      id: id,
      nodeId: "\(id)-node",
      role: .worker,
      transitions: transitions,
      loop: gate ? WorkflowStepLoopMetadata(role: "gate", gateId: "implementation-review") : nil
    )
  }

  func transition(_ destination: String, label: String? = nil) -> WorkflowStepTransition {
    WorkflowStepTransition(toStepId: destination, label: label)
  }

  func nodePayloads(includeRevise: Bool = false) -> [String: AgentNodePayload] {
    var payloads = [
      "review-node": nodePayload("review-node"),
      "finalize-node": nodePayload("finalize-node"),
      "done-node": nodePayload("done-node")
    ]
    if includeRevise {
      payloads["revise-node"] = nodePayload("revise-node")
    }
    return payloads
  }

  func nodePayload(_ id: String) -> AgentNodePayload {
    AgentNodePayload(id: id, executionBackend: .codexAgent, model: "gpt-5.5")
  }

  func gateOutput(decision: String = "needs_work", findingId: String) -> AdapterExecutionOutput {
    gateOutput(decision: decision, findingIds: [findingId])
  }

  func gateOutput(
    decision: String = "needs_work",
    findingIds: [String]
  ) -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: "test",
      model: "gpt-5.5",
      promptText: "prompt",
      completionPassed: true,
      when: [
        "needs_work": decision == "needs_work",
        "accepted": decision == "accepted"
      ],
      payload: [
        "decision": .string(decision),
        "loopGate": .object([
          "gateId": .string("implementation-review"),
          "decision": .string(decision),
          "blockingFindings": .array(findingIds.map { findingId in
            .object([
              "id": .string(findingId),
              "severity": .string("high"),
              "filePath": .string("Sources/DefaultLoopGuard.swift"),
              "message": .string("blocking finding \(findingId)")
            ])
          })
        ])
      ]
    )
  }
}

private actor GateSequenceAdapter: NodeAdapter {
  private var reviewOutputs: [AdapterExecutionOutput]
  private var executionCounts: [String: Int] = [:]

  init(reviewOutputs: [AdapterExecutionOutput]) {
    self.reviewOutputs = reviewOutputs
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    executionCounts[input.node.id, default: 0] += 1
    if input.node.id == "review", !reviewOutputs.isEmpty {
      return reviewOutputs.removeFirst()
    }
    return AdapterExecutionOutput(
      provider: "test",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      when: ["always": true],
      payload: ["status": .string("ok")]
    )
  }

  func executionCount(for nodeId: String) -> Int {
    executionCounts[nodeId, default: 0]
  }
}
