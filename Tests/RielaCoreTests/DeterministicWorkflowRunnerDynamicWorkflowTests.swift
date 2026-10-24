import XCTest
@testable import RielaCore

// swiftlint:disable:next type_name
final class DeterministicWorkflowRunnerDynamicWorkflowTests: XCTestCase {
  func testTwoDynamicIterationsRunWithLineageAndReturnResultsInMockMode() async throws {
    for simulates in [false, true] {
      let store = InMemoryWorkflowRuntimeStore()
      let adapter = DynamicWorkflowScriptedAdapter(responses: [
        "brain": [
          output(try envelope(workflowId: "generated-inventory", nodeId: "inventory", resultKey: "stock"), when: ["execute_workflow": true]),
          output(try envelope(workflowId: "generated-verify", nodeId: "verify", resultKey: "checked"), when: ["execute_workflow": true]),
          output(["decision": .string("finish"), "rationale": .string("complete")], when: ["finish": true])
        ],
        "inventory": [output(["missingVerification": .string("inventory evidence")])],
        "verify": [output(["verified": .bool(true)])]
      ])
      let runner = DeterministicWorkflowRunner(store: store, adapter: adapter, simulatesCrossWorkflowDispatch: simulates)
      let result = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: parentWorkflow(),
        nodePayloads: parentPayloads(),
        maxSteps: 12,
        maxLoopIterations: 8
      ))
      XCTAssertEqual(result.status, .completed)
      XCTAssertEqual(result.rootOutput?["decision"], .string("finish"))
      let messages = try await store.listMessages(for: result.session.sessionId, toStepId: "brain")
      XCTAssertEqual(messages.count, 2)
      let resultPayloads = messages.compactMap { message -> JSONObject? in
        guard case let .object(value)? = message.payload["dynamicWorkflowResult"] else { return nil }
        return value
      }
      XCTAssertEqual(resultPayloads.count, 2)
      XCTAssertEqual(resultPayloads.map { $0["outcome"] }, [.string("completed"), .string("completed")], "results: \(resultPayloads)")
      let childIds = resultPayloads.compactMap { payload -> String? in
        guard case let .string(id)? = payload["childSessionId"] else { return nil }
        return id
      }
      XCTAssertEqual(childIds.count, 2)
      var children: [WorkflowSession] = []
      for childId in childIds {
        if let child = try await store.loadSession(id: childId) { children.append(child) }
      }
      XCTAssertEqual(children.count, 2)
      XCTAssertEqual(children.map { $0.generatedWorkflow?.iteration }, [1, 2])
      XCTAssertEqual(children.map(\.parentSessionId), [result.session.sessionId, result.session.sessionId])
      XCTAssertEqual(children.map(\.rootSessionId), [result.session.sessionId, result.session.sessionId])
      XCTAssertNotEqual(children.first?.generatedWorkflow?.definitionDigest, children.last?.generatedWorkflow?.definitionDigest)
      let inventoryPayloadValue = await adapter.payloads(for: "inventory").first
      let verifyPayloadValue = await adapter.payloads(for: "verify").first
      let inventoryPayload = try XCTUnwrap(inventoryPayloadValue)
      let verifyPayload = try XCTUnwrap(verifyPayloadValue)
      XCTAssertEqual(inventoryPayload.agentSandbox, .workspaceWrite)
      XCTAssertEqual(verifyPayload.agentSandbox, .workspaceWrite)
      XCTAssertEqual(inventoryPayload.agentToolPolicy, AgentToolPolicy(mode: .backendDefault))
    }
  }

  func testTwoSelectedDynamicTransitionsAreRejectedInMemory() async throws {
    try await assertMultipleSelectedDynamicTransitionsAreRejected(durable: false)
  }

  func testTwoSelectedDynamicTransitionsAreRejectedDurably() async throws {
    try await assertMultipleSelectedDynamicTransitionsAreRejected(durable: true)
  }

  func testInvalidDefinitionReturnsDiagnosticsAndBrainCanFinish() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let invalid: JSONObject = [
      "decision": .string("execute_workflow"),
      "rationale": .string("bad definition"),
      "workflow": .object(["workflowId": .string("generated-invalid"), "handover": .object([:])]),
      "nodePayloads": .object([:])
    ]
    let adapter = DynamicWorkflowScriptedAdapter(responses: ["brain": [
      output(invalid, when: ["execute_workflow": true]),
      output(["decision": .string("finish")], when: ["finish": true])
    ]])
    let result = try await DeterministicWorkflowRunner(store: store, adapter: adapter).run(
      DeterministicWorkflowRunRequest(workflow: parentWorkflow(), nodePayloads: parentPayloads(), maxSteps: 8)
    )
    XCTAssertEqual(result.status, .completed)
    let messages = try await store.listMessages(for: result.session.sessionId, toStepId: "brain")
    XCTAssertEqual(messages.count, 1)
    guard case let .object(dynamicResult)? = messages.first?.payload["dynamicWorkflowResult"] else {
      return XCTFail("expected dynamicWorkflowResult")
    }
    XCTAssertEqual(dynamicResult["outcome"], .string("invalid"))
    guard case let .array(diagnostics)? = dynamicResult["diagnostics"] else {
      return XCTFail("expected validation diagnostics")
    }
    XCTAssertFalse(diagnostics.isEmpty)
    XCTAssertEqual(dynamicResult["childSessionId"], .null)
  }

  func testFailedChildIsReturnedToBrainByDefault() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = DynamicWorkflowScriptedAdapter(
      responses: [
        "brain": [
          output(try envelope(workflowId: "generated-failing", nodeId: "inventory", resultKey: "stock"), when: ["execute_workflow": true]),
          output(["decision": .string("finish")], when: ["finish": true])
        ]
      ],
      failingNodeIds: ["inventory"]
    )
    let result = try await DeterministicWorkflowRunner(store: store, adapter: adapter).run(
      DeterministicWorkflowRunRequest(workflow: parentWorkflow(), nodePayloads: parentPayloads(), maxSteps: 8)
    )
    XCTAssertEqual(result.status, .completed)
    let messages = try await store.listMessages(for: result.session.sessionId, toStepId: "brain")
    guard case let .object(dynamicResult)? = messages.first?.payload["dynamicWorkflowResult"] else {
      return XCTFail("expected dynamicWorkflowResult")
    }
    XCTAssertEqual(dynamicResult["outcome"], .string("failed"), "result: \(dynamicResult)")
    XCTAssertNotNil(dynamicResult["failureKind"])
  }

  func testInvalidDefinitionFailsParentWhenOnFailureIsFail() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let invalid: JSONObject = [
      "decision": .string("execute_workflow"),
      "workflow": .object(["workflowId": .string("generated-invalid"), "handover": .object([:])]),
      "nodePayloads": .object([:])
    ]
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: DynamicWorkflowScriptedAdapter(responses: ["brain": [output(invalid, when: ["execute_workflow": true])]])
    )
    let workflow = parentWorkflow(onFailure: .fail)
    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: parentPayloads(), maxSteps: 8))
      XCTFail("expected invalid generated workflow to fail parent")
    } catch let DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(workflowId, reason) {
      XCTAssertEqual(workflowId, "generated-invalid")
      XCTAssertTrue(reason.contains("invalid generated workflow"), reason)
    }
    let parent = await store.latestSession(workflowId: "dynamic-parent")
    XCTAssertEqual(parent?.status, .failed)
    let messages = try await store.listMessages(for: try XCTUnwrap(parent?.sessionId), toStepId: "brain")
    XCTAssertTrue(messages.isEmpty)
  }

  func testFifthDynamicSelectionFailsBeforeFifthReservation() async throws {
    let root = try temporaryRuntimeDirectory("budget")
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let store = InMemoryWorkflowRuntimeStore()
    let generated = try envelope(workflowId: "generated-budget", nodeId: "worker", resultKey: "work")
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: DynamicWorkflowScriptedAdapter(responses: [
        "brain": Array(repeating: output(generated, when: ["execute_workflow": true]), count: 5)
      ]),
      nestedInvocationPersistenceStore: persistence
    )
    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: parentWorkflow(), nodePayloads: parentPayloads(), maxSteps: 20, maxLoopIterations: 8
      ))
      XCTFail("expected fifth dynamic selection to exceed budget")
    } catch let DeterministicWorkflowRunnerError.loopBudgetExceeded(reason) {
      XCTAssertEqual(reason, "dynamic workflow iteration budget exhausted (4)")
    }
    let parentValue = await store.latestSession(workflowId: "dynamic-parent")
    let parent = try XCTUnwrap(parentValue)
    XCTAssertEqual(parent.status, .failed)
    XCTAssertEqual(parent.failureKind, .budgetExceeded)
    let records = try persistence.nestedInvocationRecords(parentSessionId: parent.sessionId)
    XCTAssertEqual(records.filter { $0.reservation.branchId == "dynamic-workflow" }.count, 4)
  }

  func testDurableResumeDeliversOneResultWithoutReexecutingBrainIteration() async throws {
    let root = try temporaryRuntimeDirectory("resume")
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = DynamicWorkflowScriptedAdapter(responses: [
      "brain": [
        output(try envelope(workflowId: "generated-resume", nodeId: "worker", resultKey: "work"), when: ["execute_workflow": true]),
        output(["decision": .string("finish")], when: ["finish": true])
      ],
      "worker": [output(["complete": .bool(true)])]
    ])
    let checkpointer = DynamicWorkflowOneShotCheckpointer(target: .beforeParentPublication)
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: adapter,
      nestedInvocationPersistenceStore: persistence,
      nestedInvocationRecoveryCheckpointer: checkpointer
    )
    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: parentWorkflow(), nodePayloads: parentPayloads(), maxSteps: 8
      ))
      XCTFail("expected controlled stop before parent result publication")
    } catch is NestedRecoveryInterruption {}
    let waitingParentValue = await store.latestSession(workflowId: "dynamic-parent")
    let waitingParent = try XCTUnwrap(waitingParentValue)
    let resumed = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: parentWorkflow(), nodePayloads: parentPayloads(), maxSteps: 8, resumeSessionId: waitingParent.sessionId
    ))
    XCTAssertEqual(resumed.status, .completed)
    let brainExecutions = resumed.session.executions.filter { $0.stepId == "brain" }
    XCTAssertEqual(brainExecutions.count, 2, "resume should run the finish decision but not replay the original execute_workflow decision")
    let messages = try await store.listMessages(for: resumed.session.sessionId, toStepId: "brain")
    XCTAssertEqual(messages.filter { $0.payload["dynamicWorkflowResult"] != nil }.count, 1)
    let records = try persistence.nestedInvocationRecords(parentSessionId: resumed.session.sessionId)
    XCTAssertEqual(records.filter { $0.reservation.branchId == "dynamic-workflow" && $0.phase == .delivered }.count, 1)
    let generatedWorkflow = try XCTUnwrap(records.first?.reservation.calleeWorkflow)
    XCTAssertEqual(generatedWorkflow.defaults.nodeTimeoutMs, 10_000)
    XCTAssertEqual(generatedWorkflow.steps.first?.timeoutMs, 10_000)
  }

  func testParentCancellationDuringChildProducesNoDynamicResult() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = DynamicWorkflowBlockingAdapter(
      brainOutput: output(
        try envelope(workflowId: "generated-cancel", nodeId: "worker", resultKey: "work"),
        when: ["execute_workflow": true]
      )
    )
    let runner = DeterministicWorkflowRunner(store: store, adapter: adapter)
    let request = DeterministicWorkflowRunRequest(
      workflow: parentWorkflow(), nodePayloads: parentPayloads(), maxSteps: 8
    )
    let run = Task {
      try await runner.run(request)
    }
    await adapter.waitUntilChildStarts()
    run.cancel()
    do {
      _ = try await run.value
      XCTFail("expected cancelled parent run")
    } catch {}
    let parentValue = await store.latestSession(workflowId: "dynamic-parent")
    let parent = try XCTUnwrap(parentValue)
    XCTAssertEqual(parent.status, .cancelled)
    let messages = try await store.listMessages(for: parent.sessionId, toStepId: "brain")
    XCTAssertTrue(messages.isEmpty)
  }

  func testDurableInvalidIterationRecoveryDoesNotRerunBrain() async throws {
    let root = try temporaryRuntimeDirectory("invalid-recovery")
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let store = InMemoryWorkflowRuntimeStore()
    let invalid: JSONObject = [
      "decision": .string("execute_workflow"),
      "workflow": .object(["workflowId": .string("generated-invalid"), "handover": .object([:])]),
      "nodePayloads": .object([:])
    ]
    let adapter = DynamicWorkflowScriptedAdapter(responses: ["brain": [
      output(invalid, when: ["execute_workflow": true]),
      output(["decision": .string("finish")], when: ["finish": true])
    ]])
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: adapter,
      nestedInvocationPersistenceStore: persistence,
      nestedInvocationRecoveryCheckpointer: DynamicWorkflowOneShotCheckpointer(target: .beforeParentPublication)
    )
    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: parentWorkflow(), nodePayloads: parentPayloads(), maxSteps: 8
      ))
      XCTFail("expected interruption before invalid dynamic result append")
    } catch is NestedRecoveryInterruption {}
    let waitingParentValue = await store.latestSession(workflowId: "dynamic-parent")
    let waitingParent = try XCTUnwrap(waitingParentValue)
    XCTAssertEqual(waitingParent.executions.filter { $0.stepId == "brain" }.count, 1)
    let resumed = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: parentWorkflow(), nodePayloads: parentPayloads(), maxSteps: 8, resumeSessionId: waitingParent.sessionId
    ))
    XCTAssertEqual(resumed.status, .completed)
    XCTAssertEqual(resumed.session.executions.filter { $0.stepId == "brain" }.count, 2)
    let messages = try await store.listMessages(for: resumed.session.sessionId, toStepId: "brain")
    XCTAssertEqual(messages.filter { $0.payload["dynamicWorkflowResult"] != nil }.count, 1)
    guard case let .object(dynamicResult)? = messages.first?.payload["dynamicWorkflowResult"] else {
      return XCTFail("expected recovered invalid result")
    }
    XCTAssertEqual(dynamicResult["outcome"], .string("invalid"))
    XCTAssertTrue(try persistence.nestedInvocationRecords(parentSessionId: resumed.session.sessionId).isEmpty)
  }

  private func assertMultipleSelectedDynamicTransitionsAreRejected(durable: Bool) async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let root = durable ? try temporaryRuntimeDirectory("multiple-transitions") : nil
    defer {
      if let root {
        try? FileManager.default.removeItem(at: root)
      }
    }
    let persistence = root.map { SQLiteWorkflowRuntimePersistenceStore(rootDirectory: $0.path) }
    let adapter = DynamicWorkflowScriptedAdapter(responses: [
      "brain": [output(
        try envelope(workflowId: "generated-multiple", nodeId: "worker", resultKey: "work"),
        when: ["a": true, "b": true]
      )]
    ])
    let transitions = ["a", "b"].map { label in
      WorkflowStepTransition(
        toStepId: "brain",
        label: label,
        dynamicWorkflow: WorkflowDynamicWorkflowTransition(maxIterations: 4)
      )
    }
    let workflow = parentWorkflow(transitions: transitions)
    let request = DeterministicWorkflowRunRequest(workflow: workflow, nodePayloads: parentPayloads(), maxSteps: 4)
    let parent = try await store.createSession(WorkflowSessionCreateInput(
      sessionId: "dynamic-multiple-parent",
      workflowId: workflow.workflowId,
      entryStepId: workflow.entryStepId
    ))
    let generatedEnvelope = try envelope(workflowId: "generated-multiple", nodeId: "worker", resultKey: "work")
    if durable {
      let runner = DeterministicWorkflowRunner(
        store: store,
        adapter: adapter,
        nestedInvocationPersistenceStore: persistence
      )
      let now = Date()
      let execution = WorkflowStepExecution(
        executionId: "dynamic-multiple-execution",
        stepId: "brain",
        nodeId: "brain",
        attempt: 1,
        createdAt: now,
        updatedAt: now
      )
      let context = WorkflowPrePersistenceRoutingContext(
        session: parent,
        stepExecution: execution,
        payload: generatedEnvelope,
        when: ["a": true, "b": true],
        selectedTransitions: transitions,
        publishesRootOutput: false,
        completesRootWithoutOutput: false,
        intendedSuccessfulStatus: .completed
      )
      let step = try XCTUnwrap(workflow.steps.first)
      let hook = try XCTUnwrap(runner.nestedInvocationPreCommitPublicationHook(
        workflow: workflow,
        step: step,
        request: request
      ))
      do {
        _ = try await hook(context)
        XCTFail("expected durable hook to reject simultaneous dynamic transitions")
      } catch let DeterministicWorkflowRunnerError.invalidWorkflow(message) {
        XCTAssertTrue(message.contains("more than one nested callee"), message)
      }
    } else {
      let publisher = InMemoryWorkflowOutputPublisher(store: store)
      let publicationRequest = WorkflowPublicationRequest(
        sessionId: parent.sessionId,
        stepId: "brain",
        nodeId: "brain",
        attempt: 1,
        body: .adapterOutput(output(generatedEnvelope, when: ["a": true])),
        transitions: [transitions[0]],
        prePersistenceRoutingDecider: { context in
          WorkflowPrePersistenceRoutingDecision(
            selectedTransitions: transitions,
            routedPayload: context.payload,
            publishesRootOutput: false,
            completesRootWithoutOutput: false
          )
        }
      )
      do {
        _ = try await publisher.publishAcceptedOutput(publicationRequest)
        XCTFail("expected publication to reject simultaneous dynamic transitions")
      } catch let WorkflowPublicationError.unsupportedTransition(message) {
        XCTAssertTrue(message.contains("more than one nested callee"), message)
      }
    }

    let generatedChild = await store.latestSession(workflowId: "generated-multiple")
    XCTAssertNil(generatedChild)
    let messages = try await store.listMessages(for: parent.sessionId, toStepId: "brain")
    XCTAssertTrue(messages.filter { $0.payload["dynamicWorkflowResult"] != nil }.isEmpty)
    if let persistence {
      let records = try persistence.nestedInvocationRecords(parentSessionId: parent.sessionId)
      XCTAssertTrue(records.filter { $0.reservation.branchId == "dynamic-workflow" }.isEmpty)
    }
  }

  private func parentWorkflow(
    onFailure: WorkflowDynamicWorkflowOnFailure = .return,
    transitions: [WorkflowStepTransition]? = nil
  ) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "dynamic-parent",
      defaults: WorkflowDefaults(nodeTimeoutMs: 10_000, maxLoopIterations: 8),
      entryStepId: "brain",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "brain")],
      steps: [WorkflowStepRef(id: "brain", nodeId: "brain", transitions: transitions ?? [
        WorkflowStepTransition(
          toStepId: "brain",
          label: "execute_workflow",
          dynamicWorkflow: WorkflowDynamicWorkflowTransition(maxIterations: 4, onFailure: onFailure)
        )
      ])],
      nodes: [WorkflowNodeRef(id: "brain")]
    )
  }

  private func temporaryRuntimeDirectory(_ name: String) throws -> URL {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let root = repositoryRoot
      .appendingPathComponent("tmp/issue-sweep-2-20261024/isw2-74c/test-runtime-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func parentPayloads() -> [String: AgentNodePayload] {
    ["brain": AgentNodePayload(
      id: "brain",
      nodeType: .agent,
      executionBackend: .codexAgent,
      model: "test-model",
      agentSandbox: .workspaceWrite,
      agentToolPolicy: AgentToolPolicy(mode: .backendDefault),
      output: NodeOutputContract(jsonSchema: [
        "type": .string("object"),
        "properties": .object(["decision": .object(["type": .string("string")])])
      ])
    )]
  }

  private func envelope(workflowId: String, nodeId: String, resultKey: String) throws -> JSONObject {
    let workflow = AuthoredWorkflowJSON(
      workflowId: workflowId,
      defaults: WorkflowDefaults(nodeTimeoutMs: 30_000, maxLoopIterations: 4),
      entryStepId: nodeId,
      nodes: [WorkflowNodeRegistryRef(id: nodeId, nodeFile: "nodes/\(nodeId).json")],
      steps: [WorkflowStepRef(id: nodeId, nodeId: nodeId, timeoutMs: 20_000)]
    )
    let workflowValue = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(workflow))
    return [
      "decision": .string("execute_workflow"),
      "rationale": .string("run \(nodeId)"),
      "workflow": workflowValue,
      "nodePayloads": .object(["nodes/\(nodeId).json": .object([
        "id": .string(nodeId),
        "nodeType": .string("agent"),
        "executionBackend": .string("codex-agent"),
        "model": .string("test-model")
      ])]),
      "input": .object(["resultKey": .string(resultKey)])
    ]
  }

  private func output(_ payload: JSONObject, when: [String: Bool] = ["always": true]) -> AdapterExecutionOutput {
    AdapterExecutionOutput(provider: "test", model: "test-model", promptText: "", completionPassed: true, when: when, payload: payload)
  }

}

private actor DynamicWorkflowScriptedAdapter: NodeAdapter {
  private var responses: [String: [AdapterExecutionOutput]]
  private let failingNodeIds: Set<String>
  private var payloadsByNode: [String: [AgentNodePayload]] = [:]

  init(responses: [String: [AdapterExecutionOutput]], failingNodeIds: Set<String> = []) {
    self.responses = responses
    self.failingNodeIds = failingNodeIds
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    payloadsByNode[input.node.id, default: []].append(input.node)
    if failingNodeIds.contains(input.node.id) {
      throw AdapterExecutionError(.providerError, "scripted child failure")
    }
    guard var outputs = responses[input.node.id], !outputs.isEmpty else {
      return AdapterExecutionOutput(provider: "test", model: input.node.model, promptText: "", completionPassed: true, payload: ["ok": .bool(true)])
    }
    let output = outputs.removeFirst()
    responses[input.node.id] = outputs
    return output
  }

  func payloads(for nodeId: String) -> [AgentNodePayload] {
    payloadsByNode[nodeId] ?? []
  }
}

private actor DynamicWorkflowOneShotCheckpointer: NestedRecoveryCheckpointing {
  private let target: NestedRecoveryCheckpoint
  private var fired = false

  init(target: NestedRecoveryCheckpoint) {
    self.target = target
  }

  func reached(_ checkpoint: NestedRecoveryCheckpoint) async throws {
    guard checkpoint == target, !fired else { return }
    fired = true
    throw NestedRecoveryInterruption()
  }
}

private actor DynamicWorkflowBlockingAdapter: NodeAdapter {
  private let brainOutput: AdapterExecutionOutput
  private var childStarted = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(brainOutput: AdapterExecutionOutput) {
    self.brainOutput = brainOutput
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard input.node.id == "worker" else { return brainOutput }
    childStarted = true
    waiters.forEach { $0.resume() }
    waiters.removeAll()
    try await Task.sleep(nanoseconds: 60_000_000_000)
    return AdapterExecutionOutput(provider: "test", model: input.node.model, promptText: "", completionPassed: true, payload: ["ok": .bool(true)])
  }

  func waitUntilChildStarts() async {
    guard !childStarted else { return }
    await withCheckedContinuation { continuation in waiters.append(continuation) }
  }
}
