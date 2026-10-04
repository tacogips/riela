import XCTest
@testable import RielaCore

final class WorkflowStepFailurePolicyTests: XCTestCase {
  func testValidationAcceptsAdvisoryWorkerWithTransition() throws {
    let result = validateAuthoredWorkflowData(workflowData(
      failurePolicy: "advisory",
      includesTransition: true
    ))

    XCTAssertEqual(result.diagnostics.filter { $0.severity == .error }, [])
    XCTAssertEqual(result.workflow?.steps.first?.failurePolicy, .advisory)
  }

  func testValidationRejectsUnknownFailurePolicy() {
    let result = validateAuthoredWorkflowData(workflowData(
      failurePolicy: "ignore",
      includesTransition: true
    ))

    XCTAssertTrue(result.diagnostics.contains {
      $0.path == "workflow.steps[0].failurePolicy" &&
        $0.message == "must be 'fail' or 'advisory' when provided"
    })
  }

  func testValidationRejectsAdvisoryTerminalStep() {
    let result = validateAuthoredWorkflowData(workflowData(
      failurePolicy: "advisory",
      includesTransition: false
    ))

    XCTAssertTrue(result.diagnostics.contains {
      $0.path == "workflow.steps[0].failurePolicy" &&
        $0.message.contains("terminal steps cannot skip their output")
    })
  }

  func testValidationRejectsAdvisoryManagerStep() {
    let result = validateAuthoredWorkflowData(workflowData(
      failurePolicy: "advisory",
      includesTransition: true,
      role: "manager"
    ))

    XCTAssertTrue(result.diagnostics.contains {
      $0.path == "workflow.steps[0].failurePolicy" &&
        $0.message == "'advisory' is not supported on the manager step"
    })
  }

  private func workflowData(
    failurePolicy: String,
    includesTransition: Bool,
    role: String = "worker"
  ) -> Data {
    let transitions = includesTransition ? #","transitions":[{"toStepId":"done"}]"# : ""
    return Data("""
      {
        "workflowId": "failure-policy",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "advisory",
        "nodes": [
          { "id": "advisory-node", "nodeFile": "nodes/advisory.json" },
          { "id": "done-node", "nodeFile": "nodes/done.json" }
        ],
        "steps": [
          {
            "id": "advisory",
            "nodeId": "advisory-node",
            "role": "\(role)",
            "failurePolicy": "\(failurePolicy)"
            \(transitions)
          },
          { "id": "done", "nodeId": "done-node", "role": "worker" }
        ]
      }
      """.utf8)
  }
}

private actor FailurePolicyAdapter: NodeAdapter {
  let failure: AdapterExecutionError
  private var executedNodeIds: [String] = []

  init(failure: AdapterExecutionError) {
    self.failure = failure
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    executedNodeIds.append(input.node.id)
    if input.node.id == "advisory" {
      throw failure
    }
    return AdapterExecutionOutput(
      provider: "test",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["status": .string("done")]
    )
  }

  func executedNodes() -> [String] {
    executedNodeIds
  }
}

final class RunnerFailurePolicyTests: XCTestCase {
  func testAdvisoryAdapterFailureRecordsFailureAndRunsNextStep() async throws {
    let adapter = FailurePolicyAdapter(
      failure: AdapterExecutionError(.providerError, "advisory backend failed")
    )
    let result = try await runner(adapter: adapter).run(request(failurePolicy: .advisory))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.transitions, 1)
    let executedNodes = await adapter.executedNodes()
    XCTAssertEqual(executedNodes, ["advisory", "done"])
    XCTAssertEqual(result.session.executions.map(\.status), [.failed, .completed])
    XCTAssertEqual(
      result.session.executions.first?.failureReason,
      "provider_error: advisory backend failed"
    )
    XCTAssertNil(result.session.executions.first?.acceptedOutput)
  }

  func testDefaultFailurePolicyStillFailsSession() async throws {
    let adapter = FailurePolicyAdapter(
      failure: AdapterExecutionError(.providerError, "blocking backend failed")
    )

    await XCTAssertThrowsErrorAsync(try await runner(adapter: adapter).run(request(failurePolicy: nil)))

    let executedNodes = await adapter.executedNodes()
    XCTAssertEqual(executedNodes, ["advisory"])
  }

  func testAdvisoryTimeoutFailureUsesSameNonBlockingPath() async throws {
    let adapter = FailurePolicyAdapter(
      failure: AdapterExecutionError(.timeout, "step deadline exceeded")
    )
    let result = try await runner(adapter: adapter).run(request(failurePolicy: .advisory))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.session.executions.first?.status, .failed)
    XCTAssertEqual(result.session.executions.first?.failureReason, "timeout: step deadline exceeded")
    let executedNodes = await adapter.executedNodes()
    XCTAssertEqual(executedNodes, ["advisory", "done"])
  }

  func testAdvisoryPolicyDoesNotSwallowCancellation() async {
    let runner = DeterministicWorkflowRunner(adapter: CancellingAdapter())

    do {
      _ = try await runner.run(request(failurePolicy: .advisory))
      XCTFail("expected cancellation")
    } catch is CancellationError {
      // Expected: advisory applies only to adapter failures.
    } catch {
      XCTFail("expected CancellationError, got \(error)")
    }
  }

  private func runner(
    adapter: FailurePolicyAdapter
  ) -> DeterministicWorkflowRunner {
    DeterministicWorkflowRunner(
      adapter: adapter
    )
  }

  private func request(
    failurePolicy: WorkflowStepFailurePolicy? = .advisory
  ) -> DeterministicWorkflowRunRequest {
    DeterministicWorkflowRunRequest(
      workflow: WorkflowDefinition(
        workflowId: "advisory-runner",
        defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
        entryStepId: "advisory",
        nodeRegistry: [
          WorkflowNodeRegistryRef(id: "advisory-node", nodeFile: "nodes/advisory.json"),
          WorkflowNodeRegistryRef(id: "done-node", nodeFile: "nodes/done.json")
        ],
        steps: [
          WorkflowStepRef(
            id: "advisory",
            nodeId: "advisory-node",
            failurePolicy: failurePolicy,
            transitions: [WorkflowStepTransition(toStepId: "done")]
          ),
          WorkflowStepRef(id: "done", nodeId: "done-node")
        ],
        nodes: [
          WorkflowNodeRef(id: "advisory-node", nodeFile: "nodes/advisory.json"),
          WorkflowNodeRef(id: "done-node", nodeFile: "nodes/done.json")
        ]
      ),
      nodePayloads: [
        "advisory-node": AgentNodePayload(
          id: "advisory-node",
          executionBackend: .codexAgent,
          model: "gpt-5.5", agentSandbox: .readOnly
        ),
        "done-node": AgentNodePayload(
          id: "done-node",
          executionBackend: .codexAgent,
          model: "gpt-5.5", agentSandbox: .readOnly
        )
      ]
    )
  }
}

/// Regression coverage for non-terminal step failures: an advisory failure and
/// an output-validation rejection with a retry remaining record a failed
/// execution while the session itself must stay `.running`, because the
/// fail-closed SQLite store persists every intermediate snapshot (a terminal
/// snapshot mid-run drops the loop lease and trips the terminal-write guard).
final class RunnerNonTerminalStepFailureTests: XCTestCase {
  func testAdvisoryFailureKeepsSessionRunningUntilNextStepCompletes() async throws {
    let store = SessionStatusRecordingStore()
    let adapter = ScriptedOutcomeAdapter(outcomes: [
      "advisory": [.failure(AdapterExecutionError(.providerError, "advisory backend failed"))],
      "done": [.payload(["status": .string("done")])]
    ])
    let result = try await DeterministicWorkflowRunner(store: store, adapter: adapter)
      .run(twoStepRequest(failurePolicy: .advisory))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.session.executions.map(\.status), [.failed, .completed])
    XCTAssertNil(result.session.failureReason)
    XCTAssertNil(result.session.failureKind)
    XCTAssertNil(result.session.failedAt)
    let observed = await store.sessionStatusesAfterFailedStepUpdates()
    XCTAssertFalse(observed.isEmpty)
    XCTAssertEqual(Set(observed), [.running], "advisory failure must never flip the session to failed: \(observed)")
  }

  func testDefaultFailurePolicyStillFailsSessionOnStepFailure() async throws {
    let store = SessionStatusRecordingStore()
    let adapter = ScriptedOutcomeAdapter(outcomes: [
      "advisory": [.failure(AdapterExecutionError(.providerError, "blocking backend failed"))]
    ])

    await XCTAssertThrowsErrorAsync(
      try await DeterministicWorkflowRunner(store: store, adapter: adapter).run(twoStepRequest(failurePolicy: nil))
    )

    let maybeSession = await store.latestSession(workflowId: "non-terminal-failure")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.failureKind, .adapterFailure)
    let observed = await store.sessionStatusesAfterFailedStepUpdates()
    XCTAssertEqual(observed, [.failed])
  }

  func testValidationRejectionWithRetryRemainingKeepsSessionRunning() async throws {
    let store = SessionStatusRecordingStore()
    let adapter = ScriptedOutcomeAdapter(outcomes: [
      "validated": [.payload([:]), .payload(["answer": .string("ok")])]
    ])
    let result = try await DeterministicWorkflowRunner(store: store, adapter: adapter)
      .run(validatedRequest(maxValidationAttempts: 2))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.session.executions.map(\.status), [.failed, .completed])
    XCTAssertEqual(result.session.executions.map(\.attempt), [1, 2])
    let observed = await store.sessionStatusesAfterFailedStepUpdates()
    XCTAssertEqual(observed, [.running], "a rejected attempt with a retry remaining must keep the session running")
  }

  func testValidationRejectionOnLastAttemptStillFailsSession() async throws {
    let store = SessionStatusRecordingStore()
    let adapter = ScriptedOutcomeAdapter(outcomes: [
      "validated": [.payload([:]), .payload([:])]
    ])

    await XCTAssertThrowsErrorAsync(
      try await DeterministicWorkflowRunner(store: store, adapter: adapter).run(validatedRequest(maxValidationAttempts: 2))
    )

    let maybeSession = await store.latestSession(workflowId: "validated-runner")
    let session = try XCTUnwrap(maybeSession)
    XCTAssertEqual(session.status, .failed)
    XCTAssertEqual(session.executions.map(\.status), [.failed, .failed])
    let observed = await store.sessionStatusesAfterFailedStepUpdates()
    XCTAssertEqual(observed.first, .running)
    XCTAssertEqual(observed.last, .failed)
  }

  private func twoStepRequest(failurePolicy: WorkflowStepFailurePolicy?) -> DeterministicWorkflowRunRequest {
    DeterministicWorkflowRunRequest(
      workflow: WorkflowDefinition(
        workflowId: "non-terminal-failure",
        defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
        entryStepId: "advisory",
        nodeRegistry: [
          WorkflowNodeRegistryRef(id: "advisory-node", nodeFile: "nodes/advisory.json"),
          WorkflowNodeRegistryRef(id: "done-node", nodeFile: "nodes/done.json")
        ],
        steps: [
          WorkflowStepRef(
            id: "advisory",
            nodeId: "advisory-node",
            failurePolicy: failurePolicy,
            transitions: [WorkflowStepTransition(toStepId: "done")]
          ),
          WorkflowStepRef(id: "done", nodeId: "done-node")
        ],
        nodes: [
          WorkflowNodeRef(id: "advisory-node", nodeFile: "nodes/advisory.json"),
          WorkflowNodeRef(id: "done-node", nodeFile: "nodes/done.json")
        ]
      ),
      nodePayloads: [
        "advisory-node": AgentNodePayload(id: "advisory-node", executionBackend: .codexAgent, model: "gpt-5.5", agentSandbox: .readOnly),
        "done-node": AgentNodePayload(id: "done-node", executionBackend: .codexAgent, model: "gpt-5.5", agentSandbox: .readOnly)
      ]
    )
  }

  private func validatedRequest(maxValidationAttempts: Int) -> DeterministicWorkflowRunRequest {
    DeterministicWorkflowRunRequest(
      workflow: WorkflowDefinition(
        workflowId: "validated-runner",
        defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
        entryStepId: "validated",
        nodeRegistry: [WorkflowNodeRegistryRef(id: "validated-node", nodeFile: "nodes/validated.json")],
        steps: [WorkflowStepRef(id: "validated", nodeId: "validated-node")],
        nodes: [WorkflowNodeRef(id: "validated-node", nodeFile: "nodes/validated.json")]
      ),
      nodePayloads: [
        "validated-node": AgentNodePayload(
          id: "validated-node",
          executionBackend: .codexAgent,
          model: "gpt-5.5",
          agentSandbox: .readOnly,
          output: NodeOutputContract(
            jsonSchema: ["type": .string("object"), "required": .array([.string("answer")])],
            maxValidationAttempts: maxValidationAttempts
          )
        )
      ]
    )
  }
}

private actor ScriptedOutcomeAdapter: NodeAdapter {
  enum Outcome {
    case payload(JSONObject)
    case failure(AdapterExecutionError)
  }

  private var outcomes: [String: [Outcome]]

  init(outcomes: [String: [Outcome]]) {
    self.outcomes = outcomes
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard var remaining = outcomes[input.node.id], !remaining.isEmpty else {
      throw AdapterExecutionError(.providerError, "no scripted outcome for \(input.node.id)")
    }
    let outcome = remaining.removeFirst()
    outcomes[input.node.id] = remaining
    switch outcome {
    case let .failure(error):
      throw error
    case let .payload(payload):
      return AdapterExecutionOutput(
        provider: "test",
        model: input.node.model,
        promptText: input.promptText,
        completionPassed: true,
        payload: payload
      )
    }
  }
}

/// Mirrors what the fail-closed SQLite store observes: the session snapshot
/// immediately after every `.failed` step-execution update.
private actor SessionStatusRecordingStore: WorkflowRuntimeStore {
  private let backing = InMemoryWorkflowRuntimeStore()
  private var recordedStatuses: [WorkflowSessionStatus] = []

  func sessionStatusesAfterFailedStepUpdates() -> [WorkflowSessionStatus] {
    recordedStatuses
  }

  func latestSession(workflowId: String) async -> WorkflowSession? {
    await backing.latestSession(workflowId: workflowId)
  }

  func updateStepExecution(_ input: WorkflowStepExecutionUpdateInput) async throws -> WorkflowStepExecution {
    let execution = try await backing.updateStepExecution(input)
    if input.status == .failed, let session = try await backing.loadSession(id: input.sessionId) {
      recordedStatuses.append(session.status)
    }
    return execution
  }

  func importAcceptedHistory(_ input: WorkflowHistoryImportInput) async throws -> WorkflowSession {
    try await backing.importAcceptedHistory(input)
  }

  func createSession(_ input: WorkflowSessionCreateInput) async throws -> WorkflowSession {
    try await backing.createSession(input)
  }

  func recordStepExecution(_ input: WorkflowStepExecutionRecordInput) async throws -> WorkflowStepExecution {
    try await backing.recordStepExecution(input)
  }

  func stageWorkflowPublication(_ input: WorkflowPublicationStageInput) async throws -> WorkflowPublicationStageResult {
    try await backing.stageWorkflowPublication(input)
  }

  func commitWorkflowPublication(_ input: WorkflowPublicationCommitInput) async throws -> WorkflowPublicationCommitResult {
    try await backing.commitWorkflowPublication(input)
  }

  func abortWorkflowPublication(_ input: WorkflowPublicationAbortInput) async throws -> WorkflowStepExecution {
    try await backing.abortWorkflowPublication(input)
  }

  func redirectPendingWorkflowStep(_ input: WorkflowPendingStepRedirectInput) async throws -> WorkflowPendingStepRedirectResult {
    try await backing.redirectPendingWorkflowStep(input)
  }

  func markSessionFailed(_ input: WorkflowSessionFailureInput) async throws -> WorkflowSession {
    try await backing.markSessionFailed(input)
  }

  func suspendSession(_ input: WorkflowSessionSuspendInput) async throws -> WorkflowSession {
    try await backing.suspendSession(input)
  }

  func recordStepBackendEvent(_ input: WorkflowStepBackendEventInput) async throws -> WorkflowStepExecution {
    try await backing.recordStepBackendEvent(input)
  }

  func recordStepBackendEventReceipt(_ input: WorkflowStepBackendEventInput) async throws -> WorkflowBackendEventReceipt {
    try await backing.recordStepBackendEventReceipt(input)
  }

  func appendWorkflowMessage(_ input: WorkflowMessageAppendInput) async throws -> WorkflowMessageRecord {
    try await backing.appendWorkflowMessage(input)
  }

  func appendWorkflowMessages(_ inputs: [WorkflowMessageAppendInput]) async throws -> [WorkflowMessageRecord] {
    try await backing.appendWorkflowMessages(inputs)
  }

  func appendWorkflowMessageOnce(_ input: WorkflowMessageAppendInput) async throws -> WorkflowMessageRecord {
    try await backing.appendWorkflowMessageOnce(input)
  }

  func listMessages(for sessionId: String, toStepId: String?) async throws -> [WorkflowMessageRecord] {
    try await backing.listMessages(for: sessionId, toStepId: toStepId)
  }

  func loadSession(id: String) async throws -> WorkflowSession? {
    try await backing.loadSession(id: id)
  }
}
