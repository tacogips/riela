import XCTest
@testable import RielaCore

final class WorkflowAddonExecutionIdentityTests: XCTestCase {
  func testRunnerRecordsExecutionBeforeInvokingMutatingAddonAndAcknowledgesAfterAcceptance() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let resolver = IdentityRecordingAddonResolver(store: store)
    let addon = WorkflowNodeAddonRef(
      name: "test/mutating-addon",
      version: "1",
      config: [
        "workflowExecutionId": .string("authored-session"),
        "stepExecutionId": .string("authored-execution"),
        "attempt": .number(99)
      ]
    )
    let workflow = WorkflowDefinition(
      workflowId: "identity-test",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "mutate",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "mutate", addon: addon)],
      steps: [WorkflowStepRef(id: "mutate", nodeId: "mutate")],
      nodes: [WorkflowNodeRef(id: "mutate", addon: addon)]
    )
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver)

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      variables: [
        "workflowExecutionId": .string("variable-session"),
        "stepExecutionId": .string("variable-execution"),
        "attempt": .number(100),
        "predecessorStepExecutionId": .string("variable-predecessor")
      ]
    ))

    XCTAssertEqual(result.status, .completed)
    let observation = await resolver.observation
    XCTAssertEqual(observation?.identity.workflowExecutionId, result.session.sessionId)
    XCTAssertEqual(observation?.identity.attempt, 1)
    XCTAssertNil(observation?.identity.predecessorStepExecutionId)
    XCTAssertEqual(observation?.identity.predecessorStepExecutionIds, [])
    XCTAssertEqual(observation?.recordedStatus, .running)
    let acknowledgedToken = await resolver.acknowledgedToken
    let acceptedStatusAtAcknowledgment = await resolver.acceptedStatusAtAcknowledgment
    let terminalWorkflowExecutionIds = await resolver.terminalWorkflowExecutionIds
    XCTAssertEqual(acknowledgedToken, WorkflowAddonFinalizationToken(value: "test-finalization-token"))
    XCTAssertEqual(acceptedStatusAtAcknowledgment, .completed)
    XCTAssertEqual(terminalWorkflowExecutionIds, [result.session.sessionId])
  }

  func testRunnerRecordsTerminalFailureForFinalizationMaintenance() async throws {
    let resolver = TerminalFailureRecordingAddonResolver()
    let runner = DeterministicWorkflowRunner(addonResolver: resolver)

    await XCTAssertThrowsErrorAsync(
      try await runner.run(DeterministicWorkflowRunRequest(workflow: singleAddonWorkflow()))
    )

    let executedWorkflowExecutionId = await resolver.workflowExecutionId
    let terminalWorkflowExecutionIds = await resolver.terminalWorkflowExecutionIds
    XCTAssertEqual(terminalWorkflowExecutionIds, [try XCTUnwrap(executedWorkflowExecutionId)])
  }

  func testRunnerDoesNotRecordResumableStepBudgetFailureAsTerminal() async throws {
    let resolver = TerminalRecordingAddonResolver()
    let runner = DeterministicWorkflowRunner(addonResolver: resolver)

    await XCTAssertThrowsErrorAsync(
      try await runner.run(DeterministicWorkflowRunRequest(
        workflow: twoAddonWorkflow(),
        maxSteps: 1
      ))
    )

    let terminalWorkflowExecutionIds = await resolver.terminalWorkflowExecutionIds
    XCTAssertEqual(terminalWorkflowExecutionIds, [])
  }

  func testResumeDerivesRetryAttemptAndPredecessorFromPersistedExecution() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let resolver = RetryIdentityAddonResolver()
    let workflow = singleAddonWorkflow()
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver)

    await XCTAssertThrowsErrorAsync(
      try await runner.run(DeterministicWorkflowRunRequest(workflow: workflow))
    )
    let recordedAfterFailure = await resolver.identities
    let firstIdentity = try XCTUnwrap(recordedAfterFailure.first)
    let loadedFailedSession = try await store.loadSession(id: firstIdentity.workflowExecutionId)
    var failedSession = try XCTUnwrap(loadedFailedSession)
    XCTAssertEqual(failedSession.executions.first?.status, .failed)
    failedSession.failureKind = .maxStepsExceeded
    failedSession.failureReason = "injected resumable boundary"
    failedSession.currentStepId = "mutate"
    await store.seedSession(failedSession)

    let resumed = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      variables: [
        "workflowExecutionId": .string("spoofed-session"),
        "predecessorStepExecutionId": .string("spoofed-predecessor")
      ],
      resumeSessionId: failedSession.sessionId
    ))
    let identities = await resolver.identities

    XCTAssertEqual(resumed.status, .completed)
    XCTAssertEqual(identities.count, 2)
    guard identities.count == 2 else {
      return
    }
    XCTAssertEqual(identities[0].attempt, 1)
    XCTAssertEqual(identities[1].attempt, 2)
    XCTAssertEqual(identities[1].workflowExecutionId, failedSession.sessionId)
    XCTAssertEqual(identities[1].predecessorStepExecutionId, identities[0].stepExecutionId)
    XCTAssertEqual(identities[1].predecessorStepExecutionIds, [identities[0].stepExecutionId])
    XCTAssertNotEqual(identities[1].predecessorStepExecutionId, "spoofed-predecessor")
  }

  func testResumeCarriesAllConsecutiveUnacceptedPredecessors() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let resolver = RetryIdentityAddonResolver(failureCount: 2)
    let workflow = singleAddonWorkflow()
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver)

    await XCTAssertThrowsErrorAsync(
      try await runner.run(DeterministicWorkflowRunRequest(workflow: workflow))
    )
    let firstRecordedIdentities = await resolver.identities
    let firstIdentity = try XCTUnwrap(firstRecordedIdentities.first)
    let firstLoadedSession = try await store.loadSession(id: firstIdentity.workflowExecutionId)
    var failedSession = try XCTUnwrap(firstLoadedSession)
    failedSession.failureKind = .maxStepsExceeded
    failedSession.failureReason = "injected resumable boundary"
    failedSession.currentStepId = "mutate"
    await store.seedSession(failedSession)

    await XCTAssertThrowsErrorAsync(
      try await runner.run(DeterministicWorkflowRunRequest(
        workflow: workflow,
        resumeSessionId: failedSession.sessionId
      ))
    )
    let secondLoadedSession = try await store.loadSession(id: failedSession.sessionId)
    failedSession = try XCTUnwrap(secondLoadedSession)
    failedSession.failureKind = .maxStepsExceeded
    failedSession.failureReason = "second injected resumable boundary"
    failedSession.currentStepId = "mutate"
    await store.seedSession(failedSession)

    let resumed = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      resumeSessionId: failedSession.sessionId
    ))
    let identities = await resolver.identities

    XCTAssertEqual(resumed.status, .completed)
    XCTAssertEqual(identities.count, 3)
    guard identities.count == 3 else { return }
    XCTAssertEqual(identities[2].predecessorStepExecutionId, identities[1].stepExecutionId)
    XCTAssertEqual(
      identities[2].predecessorStepExecutionIds,
      [identities[1].stepExecutionId, identities[0].stepExecutionId]
    )
  }

  func testResumeReconcilesAcceptedTokenAfterAcknowledgmentInterruption() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let resolver = InterruptingAcknowledgmentAddonResolver()
    let workflow = twoAddonWorkflow()
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver)

    await XCTAssertThrowsErrorAsync(
      try await runner.run(DeterministicWorkflowRunRequest(workflow: workflow, maxSteps: 1))
    )
    let recordedSessionId = await resolver.workflowExecutionId
    let sessionId = try XCTUnwrap(recordedSessionId)
    let loadedInterruptedSession = try await store.loadSession(id: sessionId)
    let interruptedSession = try XCTUnwrap(loadedInterruptedSession)
    XCTAssertEqual(interruptedSession.executions.count, 1)
    let initialAcknowledgmentCount = await resolver.acknowledgmentCount(for: "token-first")
    XCTAssertEqual(initialAcknowledgmentCount, 1)

    let resumed = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      maxSteps: 3,
      resumeSessionId: sessionId
    ))

    XCTAssertEqual(resumed.status, .completed)
    let firstTokenAcknowledgments = await resolver.acknowledgmentCount(for: "token-first")
    let secondTokenAcknowledgments = await resolver.acknowledgmentCount(for: "token-second")
    let executedStepIds = await resolver.executionStepIds
    XCTAssertEqual(firstTokenAcknowledgments, 2)
    XCTAssertEqual(secondTokenAcknowledgments, 1)
    XCTAssertEqual(executedStepIds, ["first", "second"])
  }

  func testLoopInvocationDoesNotReuseFailureBeforeAcceptedExecution() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let resolver = LoopingRetryIdentityAddonResolver()
    let workflow = loopingAddonWorkflow()
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver)

    await XCTAssertThrowsErrorAsync(
      try await runner.run(DeterministicWorkflowRunRequest(
        workflow: workflow,
        disableDefaultLoopGuard: true
      ))
    )
    let firstRecordedIdentities = await resolver.identities
    let firstIdentity = try XCTUnwrap(firstRecordedIdentities.first)
    let loadedFailedSession = try await store.loadSession(id: firstIdentity.workflowExecutionId)
    var failedSession = try XCTUnwrap(loadedFailedSession)
    failedSession.failureKind = .maxStepsExceeded
    failedSession.failureReason = "injected resumable boundary"
    failedSession.currentStepId = "mutate"
    await store.seedSession(failedSession)

    let resumed = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      maxSteps: 3,
      disableDefaultLoopGuard: true,
      resumeSessionId: failedSession.sessionId
    ))
    let identities = await resolver.identities

    XCTAssertEqual(resumed.status, .completed)
    XCTAssertEqual(identities.count, 3)
    guard identities.count == 3 else {
      return
    }
    XCTAssertEqual(identities.map(\.attempt), [1, 2, 3])
    XCTAssertEqual(identities[1].predecessorStepExecutionId, identities[0].stepExecutionId)
    XCTAssertEqual(identities[1].predecessorStepExecutionIds, [identities[0].stepExecutionId])
    XCTAssertNil(identities[2].predecessorStepExecutionId)
    XCTAssertEqual(identities[2].predecessorStepExecutionIds, [])
  }

  func testCompletedSessionRetriesInterruptedFinalizationAcknowledgment() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let resolver = InterruptingAcknowledgmentAddonResolver()
    let workflow = singleFinalizationAddonWorkflow()
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver)

    let completed = try await runner.run(DeterministicWorkflowRunRequest(workflow: workflow))
    XCTAssertEqual(completed.status, .completed)
    let initialAcknowledgmentCount = await resolver.acknowledgmentCount(for: "token-first")
    XCTAssertEqual(initialAcknowledgmentCount, 1)

    let resumed = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      resumeSessionId: completed.session.sessionId
    ))

    XCTAssertEqual(resumed.status, .completed)
    let finalAcknowledgmentCount = await resolver.acknowledgmentCount(for: "token-first")
    let executedStepIds = await resolver.executionStepIds
    XCTAssertEqual(finalAcknowledgmentCount, 2)
    XCTAssertEqual(executedStepIds, ["first"])
  }

  func testPendingPublicationAcknowledgmentIsRetriedAfterInterruption() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let resolver = InterruptingAcknowledgmentAddonResolver()
    let workflow = pendingFinalizationWorkflow()
    let session = try await store.createSession(WorkflowSessionCreateInput(
      workflowId: workflow.workflowId,
      entryStepId: "first"
    ))
    let execution = try await store.recordStepExecution(WorkflowStepExecutionRecordInput(
      sessionId: session.sessionId,
      stepId: "first",
      nodeId: "first",
      attempt: 1
    ))
    _ = try await store.stageWorkflowPublication(WorkflowPublicationStageInput(
      sessionId: session.sessionId,
      executionId: execution.executionId,
      acceptedOutput: WorkflowAcceptedOutputMetadata(
        payload: acceptedLoopGatePayload(),
        when: ["accepted": true],
        acceptedAt: Date(),
        runtimeFinalizationToken: WorkflowAddonFinalizationToken(value: "token-first")
      ),
      adapterOutput: nil,
      usage: nil,
      pendingRoutePublication: WorkflowPendingRoutePublication(
        selectedTransitions: [WorkflowStepTransition(toStepId: "done", label: "accepted")],
        publishesRootOutput: false,
        completesRootWithoutOutput: false,
        noSelectionDisposition: .publishPayloadAsRoot,
        intendedSuccessfulStatus: .completed
      )
    ))
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: StaticAdapter(output: AdapterExecutionOutput(
        provider: "test",
        model: "test",
        promptText: "",
        completionPassed: true,
        payload: ["status": .string("done")]
      )),
      addonResolver: resolver
    )

    let resumed = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "done": AgentNodePayload(id: "done", executionBackend: .codexAgent, model: "test")
      ],
      maxSteps: 3,
      resumeSessionId: session.sessionId
    ))

    XCTAssertEqual(resumed.status, .completed)
    let interruptedAcknowledgmentCount = await resolver.acknowledgmentCount(for: "token-first")
    let executedStepIds = await resolver.executionStepIds
    XCTAssertEqual(interruptedAcknowledgmentCount, 1)
    XCTAssertEqual(executedStepIds, [])

    let terminalResume = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "done": AgentNodePayload(id: "done", executionBackend: .codexAgent, model: "test")
      ],
      resumeSessionId: session.sessionId
    ))

    XCTAssertEqual(terminalResume.status, .completed)
    let recoveredAcknowledgmentCount = await resolver.acknowledgmentCount(for: "token-first")
    XCTAssertEqual(recoveredAcknowledgmentCount, 2)
  }

  func testExecutionInputDecodesLegacyFixtureWithoutRuntimeIdentity() throws {
    let data = Data("""
      {
        "workflowId": "legacy",
        "stepId": "step",
        "nodeId": "node",
        "addon": {"name": "riela/chat-reply-worker", "version": "1"},
        "variables": {},
        "resolvedInputPayload": {},
        "attachments": {}
      }
      """.utf8)

    let decoded = try JSONDecoder().decode(WorkflowAddonExecutionInput.self, from: data)

    XCTAssertNil(decoded.executionIdentity)
  }

  func testRuntimeFinalizationTokenIsNotEncodedInAdapterBusinessOutput() throws {
    let output = AdapterExecutionOutput(
      provider: "test",
      model: "test",
      promptText: "",
      completionPassed: true,
      payload: ["status": .string("ok")],
      runtimeFinalizationToken: WorkflowAddonFinalizationToken(value: "secret-token")
    )

    let encoded = try JSONEncoder().encode(output)
    let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

    XCTAssertFalse(text.contains("secret-token"))
    XCTAssertFalse(text.contains("runtimeFinalizationToken"))
    XCTAssertEqual(try JSONDecoder().decode(AdapterExecutionOutput.self, from: encoded).payload, output.payload)
  }
}

private func singleAddonWorkflow() -> WorkflowDefinition {
  let addon = WorkflowNodeAddonRef(name: "test/mutating-addon", version: "1")
  return WorkflowDefinition(
    workflowId: "identity-retry-test",
    defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
    entryStepId: "mutate",
    nodeRegistry: [WorkflowNodeRegistryRef(id: "mutate", addon: addon)],
    steps: [WorkflowStepRef(id: "mutate", nodeId: "mutate")],
    nodes: [WorkflowNodeRef(id: "mutate", addon: addon)]
  )
}

private func twoAddonWorkflow() -> WorkflowDefinition {
  let addon = WorkflowNodeAddonRef(name: "test/mutating-addon", version: "1")
  return WorkflowDefinition(
    workflowId: "identity-acknowledgment-recovery-test",
    defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
    entryStepId: "first",
    nodeRegistry: [
      WorkflowNodeRegistryRef(id: "first", addon: addon),
      WorkflowNodeRegistryRef(id: "second", addon: addon)
    ],
    steps: [
      WorkflowStepRef(
        id: "first",
        nodeId: "first",
        transitions: [WorkflowStepTransition(toStepId: "second")]
      ),
      WorkflowStepRef(id: "second", nodeId: "second")
    ],
    nodes: [
      WorkflowNodeRef(id: "first", addon: addon),
      WorkflowNodeRef(id: "second", addon: addon)
    ]
  )
}

private func loopingAddonWorkflow() -> WorkflowDefinition {
  let addon = WorkflowNodeAddonRef(name: "test/mutating-addon", version: "1")
  return WorkflowDefinition(
    workflowId: "identity-loop-boundary-test",
    defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 4),
    entryStepId: "mutate",
    nodeRegistry: [WorkflowNodeRegistryRef(id: "mutate", addon: addon)],
    steps: [
      WorkflowStepRef(
        id: "mutate",
        nodeId: "mutate",
        transitions: [WorkflowStepTransition(toStepId: "mutate", label: "loop_again")]
      )
    ],
    nodes: [WorkflowNodeRef(id: "mutate", addon: addon)]
  )
}

private func singleFinalizationAddonWorkflow() -> WorkflowDefinition {
  let addon = WorkflowNodeAddonRef(name: "test/mutating-addon", version: "1")
  return WorkflowDefinition(
    workflowId: "identity-terminal-acknowledgment-test",
    defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
    entryStepId: "first",
    nodeRegistry: [WorkflowNodeRegistryRef(id: "first", addon: addon)],
    steps: [WorkflowStepRef(id: "first", nodeId: "first")],
    nodes: [WorkflowNodeRef(id: "first", addon: addon)]
  )
}

private func pendingFinalizationWorkflow() -> WorkflowDefinition {
  let addon = WorkflowNodeAddonRef(name: "test/mutating-addon", version: "1")
  return WorkflowDefinition(
    workflowId: "identity-pending-acknowledgment-test",
    defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
    entryStepId: "first",
    nodeRegistry: [
      WorkflowNodeRegistryRef(id: "first", addon: addon),
      WorkflowNodeRegistryRef(id: "done", nodeFile: "nodes/done.json")
    ],
    steps: [
      WorkflowStepRef(
        id: "first",
        nodeId: "first",
        transitions: [WorkflowStepTransition(toStepId: "done", label: "accepted")],
        loop: WorkflowStepLoopMetadata(role: "gate", gateId: "implementation-review")
      ),
      WorkflowStepRef(id: "done", nodeId: "done")
    ],
    nodes: [
      WorkflowNodeRef(id: "first", addon: addon),
      WorkflowNodeRef(id: "done", nodeFile: "nodes/done.json")
    ]
  )
}

private func acceptedLoopGatePayload() -> JSONObject {
  [
    "decision": .string("accepted"),
    "loopGate": .object([
      "gateId": .string("implementation-review"),
      "decision": .string("accepted"),
      "blockingFindings": .array([])
    ])
  ]
}

private actor IdentityRecordingAddonResolver: WorkflowAddonResolving, WorkflowAddonFinalizationAcknowledging,
  WorkflowAddonTerminalRecording {
  struct Observation {
    var identity: WorkflowAddonExecutionIdentity
    var recordedStatus: WorkflowStepExecutionStatus
  }

  let store: InMemoryWorkflowRuntimeStore
  var observation: Observation?
  var acknowledgedToken: WorkflowAddonFinalizationToken?
  var acceptedStatusAtAcknowledgment: WorkflowStepExecutionStatus?
  var terminalWorkflowExecutionIds: [String] = []
  private var workflowExecutionId: String?

  init(store: InMemoryWorkflowRuntimeStore) {
    self.store = store
  }

  func execute(
    _ input: WorkflowAddonExecutionInput,
    context _: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    let identity = try XCTUnwrap(input.executionIdentity)
    let loadedSession = try await store.loadSession(id: identity.workflowExecutionId)
    let session = try XCTUnwrap(loadedSession)
    let execution = try XCTUnwrap(session.executions.first { $0.executionId == identity.stepExecutionId })
    observation = Observation(identity: identity, recordedStatus: execution.status)
    workflowExecutionId = identity.workflowExecutionId
    return AdapterExecutionOutput(
      provider: "test",
      model: "test/mutating-addon@1",
      promptText: "",
      completionPassed: true,
      payload: ["status": .string("accepted")],
      runtimeFinalizationToken: WorkflowAddonFinalizationToken(value: "test-finalization-token")
    )
  }

  func acknowledgeAcceptedFinalization(_ token: WorkflowAddonFinalizationToken) async throws {
    acknowledgedToken = token
    guard let workflowExecutionId,
          let session = try await store.loadSession(id: workflowExecutionId),
          let executionId = observation?.identity.stepExecutionId else {
      return
    }
    acceptedStatusAtAcknowledgment = session.executions.first {
      $0.executionId == executionId
    }?.status
  }

  func recordTerminalFinalization(
    workflowExecutionId: String,
    stepExecutionIds _: [String]
  ) async throws {
    terminalWorkflowExecutionIds.append(workflowExecutionId)
  }
}

private actor TerminalFailureRecordingAddonResolver: WorkflowAddonResolving,
  WorkflowAddonTerminalRecording {
  var workflowExecutionId: String?
  var terminalWorkflowExecutionIds: [String] = []

  func execute(
    _ input: WorkflowAddonExecutionInput,
    context _: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    workflowExecutionId = input.executionIdentity?.workflowExecutionId
    throw AdapterExecutionError(.providerError, "injected terminal failure", isRetryable: true)
  }

  func recordTerminalFinalization(
    workflowExecutionId: String,
    stepExecutionIds _: [String]
  ) async throws {
    terminalWorkflowExecutionIds.append(workflowExecutionId)
  }
}

private actor TerminalRecordingAddonResolver: WorkflowAddonResolving,
  WorkflowAddonTerminalRecording {
  var terminalWorkflowExecutionIds: [String] = []

  func execute(
    _ input: WorkflowAddonExecutionInput,
    context _: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: "test",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      payload: ["status": .string("accepted")]
    )
  }

  func recordTerminalFinalization(
    workflowExecutionId: String,
    stepExecutionIds _: [String]
  ) async throws {
    terminalWorkflowExecutionIds.append(workflowExecutionId)
  }
}

private actor RetryIdentityAddonResolver: WorkflowAddonResolving {
  var identities: [WorkflowAddonExecutionIdentity] = []
  private let failureCount: Int

  init(failureCount: Int = 1) {
    self.failureCount = failureCount
  }

  func execute(
    _ input: WorkflowAddonExecutionInput,
    context _: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    let identity = try XCTUnwrap(input.executionIdentity)
    identities.append(identity)
    if identities.count <= failureCount {
      throw AdapterExecutionError(.providerError, "injected first-attempt failure", isRetryable: true)
    }
    return AdapterExecutionOutput(
      provider: "test",
      model: "test/mutating-addon@1",
      promptText: "",
      completionPassed: true,
      payload: ["status": .string("accepted")]
    )
  }
}

private actor LoopingRetryIdentityAddonResolver: WorkflowAddonResolving {
  var identities: [WorkflowAddonExecutionIdentity] = []

  func execute(
    _ input: WorkflowAddonExecutionInput,
    context _: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    let identity = try XCTUnwrap(input.executionIdentity)
    identities.append(identity)
    if identities.count == 1 {
      throw AdapterExecutionError(.providerError, "injected first-attempt failure", isRetryable: true)
    }
    return AdapterExecutionOutput(
      provider: "test",
      model: "test/mutating-addon@1",
      promptText: "",
      completionPassed: true,
      when: ["loop_again": identities.count == 2],
      payload: ["status": .string("accepted")]
    )
  }
}

private actor InterruptingAcknowledgmentAddonResolver: WorkflowAddonResolving, WorkflowAddonFinalizationAcknowledging {
  var workflowExecutionId: String?
  var executionStepIds: [String] = []
  private var acknowledgmentCounts: [String: Int] = [:]

  func execute(
    _ input: WorkflowAddonExecutionInput,
    context _: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    workflowExecutionId = input.executionIdentity?.workflowExecutionId
    executionStepIds.append(input.stepId)
    return AdapterExecutionOutput(
      provider: "test",
      model: "test/mutating-addon@1",
      promptText: "",
      completionPassed: true,
      payload: ["status": .string("accepted")],
      runtimeFinalizationToken: WorkflowAddonFinalizationToken(value: "token-\(input.stepId)")
    )
  }

  func acknowledgeAcceptedFinalization(_ token: WorkflowAddonFinalizationToken) async throws {
    acknowledgmentCounts[token.value, default: 0] += 1
    if token.value == "token-first", acknowledgmentCounts[token.value] == 1 {
      throw AdapterExecutionError(.providerError, "injected acknowledgment interruption", isRetryable: true)
    }
  }

  func acknowledgmentCount(for token: String) -> Int {
    acknowledgmentCounts[token, default: 0]
  }
}
