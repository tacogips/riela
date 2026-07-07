import XCTest
import RielaMemory
@testable import RielaCore

final class DeterministicWorkflowRunnerCrossWorkflowDispatchTests: XCTestCase {
  func testLiveDispatchRunsCalleeAndDeliversCalleeRootOutputToResumeStep() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = VariableRecordingAdapter(outputsByStep: [
      "dispatch": output(payload: ["handoff": .string("outbound-request")]),
      "callee-entry": output(payload: ["calleeResult": .string("done")]),
      "resume": output(payload: ["status": .string("applied")])
    ])
    let recorder = WorkflowRunEventRecorder()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: adapter,
      calleeResolver: StaticCalleeResolver(callees: [calleeFixture()])
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: callerWorkflow(),
      nodePayloads: callerNodePayloads(),
      eventHandler: { await recorder.append($0) }
    ))

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.session.executions.map(\.stepId), ["dispatch", "resume"])
    XCTAssertEqual(result.transitions, 1)

    let calleeSessionLoaded = await store.latestSession(workflowId: "callee")
    let calleeSession = try XCTUnwrap(calleeSessionLoaded)
    XCTAssertEqual(calleeSession.status, .completed)
    XCTAssertEqual(calleeSession.executions.map(\.stepId), ["callee-entry"])

    let resumeMessages = try await store.listMessages(for: result.session.sessionId, toStepId: "resume")
    XCTAssertEqual(resumeMessages.count, 1)
    let resumeMessage = try XCTUnwrap(resumeMessages.first)
    XCTAssertEqual(resumeMessage.fromStepId, "dispatch")
    XCTAssertEqual(resumeMessage.payload["calleeResult"], .string("done"))
    XCTAssertNil(resumeMessage.payload["handoff"], "outbound handoff must not be echoed to the resume step")
    XCTAssertEqual(
      resumeMessage.payload["_rielaCrossWorkflow"],
      .object([
        "workflowId": .string("callee"),
        "sessionId": .string(calleeSession.sessionId),
        "status": .string("completed")
      ])
    )

    let calleeVariablesRecorded = await adapter.mergedVariables(forStep: "callee-entry")
    let calleeVariables = try XCTUnwrap(calleeVariablesRecorded)
    XCTAssertEqual(calleeVariables["handoff"], .string("outbound-request"))
    let resumeVariablesRecorded = await adapter.mergedVariables(forStep: "resume")
    let resumeVariables = try XCTUnwrap(resumeVariablesRecorded)
    XCTAssertEqual(resumeVariables["calleeResult"], .string("done"))
    XCTAssertNil(resumeVariables["handoff"])

    let events = await recorder.events()
    let calleeSessionEvents = events.filter { $0.workflowId == "callee" }
    XCTAssertEqual(calleeSessionEvents.first?.type, .sessionStarted)
    XCTAssertEqual(calleeSessionEvents.first?.sessionId, calleeSession.sessionId)
    XCTAssertTrue(calleeSessionEvents.contains { $0.type == .sessionCompleted })
  }

  func testLiveDispatchCalleeFailurePropagatesToParent() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = VariableRecordingAdapter(
      outputsByStep: ["dispatch": output(payload: ["handoff": .string("outbound-request")])],
      failingSteps: ["callee-entry"]
    )
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: adapter,
      calleeResolver: StaticCalleeResolver(callees: [calleeFixture()])
    )

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: callerWorkflow(),
        nodePayloads: callerNodePayloads()
      ))
      XCTFail("expected callee failure to propagate")
    } catch let DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(workflowId, reason) {
      XCTAssertEqual(workflowId, "callee")
      XCTAssertTrue(reason.contains("callee workflow run failed"), reason)
    }

    let parentSessionLoaded = await store.latestSession(workflowId: "caller")
    let parentSession = try XCTUnwrap(parentSessionLoaded)
    XCTAssertEqual(parentSession.status, .failed)
    XCTAssertEqual(parentSession.executions.map(\.stepId), ["dispatch"], "resume step must not run")
    let calleeSessionLoaded = await store.latestSession(workflowId: "callee")
    let calleeSession = try XCTUnwrap(calleeSessionLoaded)
    XCTAssertEqual(calleeSession.status, .failed)
    let resumeMessages = try await store.listMessages(for: parentSession.sessionId, toStepId: "resume")
    XCTAssertTrue(resumeMessages.isEmpty, "no handoff echo and no callee result may reach the resume step")
  }

  func testLiveRunWithoutCalleeResolverFailsPreflightLoudly() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: VariableRecordingAdapter(outputsByStep: [:])
    )

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: callerWorkflow(),
        nodePayloads: callerNodePayloads()
      ))
      XCTFail("expected preflight failure without a callee resolver")
    } catch DeterministicWorkflowRunnerError.invalidWorkflow(let message) {
      XCTAssertTrue(message.contains("no callee workflow resolver"), message)
    }
    let latestSession = await store.latestSession(workflowId: "caller")
    XCTAssertNil(latestSession, "preflight failure must not create a session")
  }

  func testLiveDispatchWithUnresolvableCalleeFailsLoudly() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: VariableRecordingAdapter(outputsByStep: [
        "dispatch": output(payload: ["handoff": .string("outbound-request")])
      ]),
      calleeResolver: StaticCalleeResolver(callees: [])
    )

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: callerWorkflow(),
        nodePayloads: callerNodePayloads()
      ))
      XCTFail("expected unresolvable callee failure")
    } catch DeterministicWorkflowRunnerError.invalidWorkflow(let message) {
      XCTAssertTrue(message.contains("workflow.steps.dispatch.transitions.toWorkflowId"), message)
      XCTAssertTrue(message.contains("could not be resolved before running"), message)
    }

    let parentSession = await store.latestSession(workflowId: "caller")
    XCTAssertNil(parentSession, "callee resolution preflight failure must not create a parent session")
  }

  func testLiveDispatchRejectsCalleeEntryStepMissingFromCallee() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    var callee = calleeFixture()
    callee.workflow.steps[0].id = "different-entry"
    callee.workflow.entryStepId = "different-entry"
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: VariableRecordingAdapter(outputsByStep: [
        "dispatch": output(payload: ["handoff": .string("outbound-request")])
      ]),
      calleeResolver: StaticCalleeResolver(callees: [callee])
    )

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: callerWorkflow(),
        nodePayloads: callerNodePayloads()
      ))
      XCTFail("expected missing callee entry step failure")
    } catch DeterministicWorkflowRunnerError.invalidWorkflow(let message) {
      XCTAssertTrue(message.contains("workflow.steps.dispatch.transitions.toWorkflowId"), message)
      XCTAssertTrue(message.contains("callee-entry"), message)
      XCTAssertTrue(message.contains("callee step does not exist"), message)
    }
    let parentSession = await store.latestSession(workflowId: "caller")
    XCTAssertNil(parentSession, "callee entry preflight failure must not create a parent session")
  }

  func testLiveDispatchRejectsMissingCallerResumeStepBeforeSessionCreation() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    var workflow = callerWorkflow()
    workflow.steps.removeAll { $0.id == "resume" }
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: VariableRecordingAdapter(outputsByStep: [
        "dispatch": output(payload: ["handoff": .string("outbound-request")])
      ]),
      calleeResolver: StaticCalleeResolver(callees: [calleeFixture()])
    )

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: workflow,
        nodePayloads: callerNodePayloads()
      ))
      XCTFail("expected missing caller resume step failure")
    } catch DeterministicWorkflowRunnerError.invalidWorkflow(let message) {
      XCTAssertTrue(message.contains("workflow.steps.dispatch.transitions.resumeStepId"), message)
      XCTAssertTrue(message.contains("resume"), message)
      XCTAssertTrue(message.contains("caller resume step does not exist"), message)
    }

    let parentSession = await store.latestSession(workflowId: "caller")
    XCTAssertNil(parentSession, "caller resume preflight failure must not create a parent session")
    let calleeSession = await store.latestSession(workflowId: "callee")
    XCTAssertNil(calleeSession, "caller resume preflight failure must not create a callee session")
  }

  func testLiveDispatchPreflightsDispatchTargetsReachableOnlyThroughResumeStep() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: VariableRecordingAdapter(outputsByStep: [
        "dispatch": output(payload: ["handoff": .string("outbound-request")]),
        "callee-entry": output(payload: ["calleeResult": .string("done")]),
        "resume": output(payload: ["status": .string("applied")])
      ]),
      calleeResolver: StaticCalleeResolver(callees: [calleeFixture()])
    )

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: callerWorkflowWithSecondDispatchFromResume(),
        nodePayloads: callerNodePayloadsWithFinalStep()
      ))
      XCTFail("expected second dispatch preflight failure")
    } catch DeterministicWorkflowRunnerError.invalidWorkflow(let message) {
      XCTAssertTrue(message.contains("workflow.steps.resume.transitions.toWorkflowId"), message)
      XCTAssertTrue(message.contains("second-callee"), message)
      XCTAssertTrue(message.contains("could not be resolved before running"), message)
    }

    let parentSession = await store.latestSession(workflowId: "caller")
    XCTAssertNil(parentSession, "resume-step dispatch preflight failure must not create a parent session")
    let calleeSession = await store.latestSession(workflowId: "callee")
    XCTAssertNil(calleeSession, "resume-step dispatch preflight failure must not create a callee session")
  }

  func testLiveDispatchDepthGuardStopsWorkflowCallCycles() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    // The callee dispatches back into itself, forming a cycle.
    var cyclicCallee = calleeFixture()
    cyclicCallee.workflow.steps[0].transitions = [
      WorkflowStepTransition(
        toStepId: "callee-entry",
        toWorkflowId: "callee",
        resumeStepId: "callee-resume"
      )
    ]
    cyclicCallee.workflow.steps.append(WorkflowStepRef(id: "callee-resume", nodeId: "callee-node"))
    cyclicCallee.workflow.nodes.append(WorkflowNodeRef(id: "callee-resume", nodeFile: "nodes/callee.json"))
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: VariableRecordingAdapter(outputsByStep: [
        "dispatch": output(payload: ["handoff": .string("outbound-request")]),
        "callee-entry": output(payload: ["calleeResult": .string("looping")])
      ]),
      calleeResolver: StaticCalleeResolver(callees: [cyclicCallee])
    )

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: callerWorkflow(),
        nodePayloads: callerNodePayloads()
      ))
      XCTFail("expected dispatch depth guard failure")
    } catch let DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed(_, reason) {
      XCTAssertTrue(reason.contains("dispatch depth exceeded"), reason)
    }
  }

  func testMockSimulationStillSkipsCalleeAndEchoesHandoffToResumeStep() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = VariableRecordingAdapter(outputsByStep: [
      "dispatch": output(payload: ["handoff": .string("outbound-request")]),
      "resume": output(payload: ["status": .string("applied")])
    ])
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: adapter,
      simulatesCrossWorkflowDispatch: true
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: callerWorkflow(),
      nodePayloads: callerNodePayloads()
    ))

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.session.executions.map(\.stepId), ["dispatch", "resume"])
    let calleeSession = await store.latestSession(workflowId: "callee")
    XCTAssertNil(calleeSession, "mock simulation must not create a callee session")
    let resumeMessages = try await store.listMessages(for: result.session.sessionId, toStepId: "resume")
    XCTAssertEqual(resumeMessages.count, 1)
    XCTAssertEqual(resumeMessages.first?.payload["handoff"], .string("outbound-request"))
    XCTAssertNil(resumeMessages.first?.payload["_rielaCrossWorkflow"])
  }

  func testMockSimulationTakesPrecedenceOverLiveDispatchWhenBothAreConfigured() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: VariableRecordingAdapter(outputsByStep: [
        "dispatch": output(payload: ["handoff": .string("outbound-request")]),
        "resume": output(payload: ["status": .string("applied")])
      ]),
      simulatesCrossWorkflowDispatch: true,
      calleeResolver: StaticCalleeResolver(callees: [calleeFixture()])
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: callerWorkflow(),
      nodePayloads: callerNodePayloads()
    ))

    XCTAssertEqual(result.exitCode, 0)
    let calleeSession = await store.latestSession(workflowId: "callee")
    XCTAssertNil(calleeSession, "mock-scenario runs keep simulating the callee")
  }

  func testMissingLiveCalleeFailsBeforeParentSessionCreation() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: VariableRecordingAdapter(outputsByStep: [
        "dispatch": output(payload: ["handoff": .string("outbound-request")])
      ]),
      calleeResolver: FailingCalleeResolver()
    )

    do {
      _ = try await runner.run(DeterministicWorkflowRunRequest(
        workflow: callerWorkflow(),
        nodePayloads: callerNodePayloads()
      ))
      XCTFail("expected missing callee preflight failure")
    } catch DeterministicWorkflowRunnerError.invalidWorkflow(let message) {
      XCTAssertTrue(message.contains("workflow.steps.dispatch.transitions.toWorkflowId"), message)
      XCTAssertTrue(message.contains("callee"), message)
      XCTAssertTrue(message.contains("could not be resolved before running"), message)
    }

    let parentSession = await store.latestSession(workflowId: "caller")
    XCTAssertNil(parentSession)
  }

  func testCapabilityGapDroppedForDispatchShapeWhenResolverIsSupported() {
    let gaps = DeterministicWorkflowRunner.unsupportedFeatures(
      in: callerWorkflow(),
      supportsCrossWorkflowDispatch: true
    )
    XCTAssertTrue(gaps.isEmpty, "\(gaps)")

    let unsupportedGaps = DeterministicWorkflowRunner.unsupportedFeatures(in: callerWorkflow())
    XCTAssertEqual(unsupportedGaps.count, 1)
    XCTAssertEqual(unsupportedGaps.first?.severity, .warning)
    XCTAssertEqual(unsupportedGaps.first?.path, "workflow.steps.dispatch.transitions.toWorkflowId")
  }

  // MARK: - Fixtures

  private func callerWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "caller",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "dispatch",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "dispatch-node", nodeFile: "nodes/dispatch.json"),
        WorkflowNodeRegistryRef(id: "resume-node", nodeFile: "nodes/resume.json")
      ],
      steps: [
        WorkflowStepRef(
          id: "dispatch",
          nodeId: "dispatch-node",
          transitions: [
            WorkflowStepTransition(
              toStepId: "callee-entry",
              toWorkflowId: "callee",
              resumeStepId: "resume"
            )
          ]
        ),
        WorkflowStepRef(id: "resume", nodeId: "resume-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "dispatch", nodeFile: "nodes/dispatch.json"),
        WorkflowNodeRef(id: "resume", nodeFile: "nodes/resume.json")
      ]
    )
  }

  private func callerNodePayloads() -> [String: AgentNodePayload] {
    [
      "dispatch-node": AgentNodePayload(id: "dispatch-node", executionBackend: .codexAgent, model: "gpt-5.5"),
      "resume-node": AgentNodePayload(id: "resume-node", executionBackend: .codexAgent, model: "gpt-5.5")
    ]
  }

  private func callerWorkflowWithSecondDispatchFromResume() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "caller",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "dispatch",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "dispatch-node", nodeFile: "nodes/dispatch.json"),
        WorkflowNodeRegistryRef(id: "resume-node", nodeFile: "nodes/resume.json"),
        WorkflowNodeRegistryRef(id: "final-node", nodeFile: "nodes/final.json")
      ],
      steps: [
        WorkflowStepRef(
          id: "dispatch",
          nodeId: "dispatch-node",
          transitions: [
            WorkflowStepTransition(
              toStepId: "callee-entry",
              toWorkflowId: "callee",
              resumeStepId: "resume"
            )
          ]
        ),
        WorkflowStepRef(
          id: "resume",
          nodeId: "resume-node",
          transitions: [
            WorkflowStepTransition(
              toStepId: "second-entry",
              toWorkflowId: "second-callee",
              resumeStepId: "final"
            )
          ]
        ),
        WorkflowStepRef(id: "final", nodeId: "final-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "dispatch", nodeFile: "nodes/dispatch.json"),
        WorkflowNodeRef(id: "resume", nodeFile: "nodes/resume.json"),
        WorkflowNodeRef(id: "final", nodeFile: "nodes/final.json")
      ]
    )
  }

  private func callerNodePayloadsWithFinalStep() -> [String: AgentNodePayload] {
    var payloads = callerNodePayloads()
    payloads["final-node"] = AgentNodePayload(
      id: "final-node",
      executionBackend: .codexAgent,
      model: "gpt-5.5"
    )
    return payloads
  }

  private func calleeFixture() -> ResolvedWorkflowCallee {
    ResolvedWorkflowCallee(
      workflow: WorkflowDefinition(
        workflowId: "callee",
        defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
        entryStepId: "callee-entry",
        nodeRegistry: [WorkflowNodeRegistryRef(id: "callee-node", nodeFile: "nodes/callee.json")],
        steps: [WorkflowStepRef(id: "callee-entry", nodeId: "callee-node")],
        nodes: [WorkflowNodeRef(id: "callee-entry", nodeFile: "nodes/callee.json")]
      ),
      nodePayloads: [
        "callee-node": AgentNodePayload(id: "callee-node", executionBackend: .codexAgent, model: "gpt-5.5")
      ]
    )
  }

  private struct FailingCalleeResolver: WorkflowCalleeResolving {
    func resolveCallee(workflowId: String) async throws -> ResolvedWorkflowCallee {
      throw WorkflowResolutionFailure()
    }
  }

  private struct WorkflowResolutionFailure: Error {}

  private func output(payload: JSONObject) -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: "test",
      model: "gpt-5.5",
      promptText: "prompt",
      completionPassed: true,
      payload: payload
    )
  }
}

private struct StaticCalleeResolver: WorkflowCalleeResolving {
  var callees: [ResolvedWorkflowCallee]

  func resolveCallee(workflowId: String) async throws -> ResolvedWorkflowCallee {
    guard let callee = callees.first(where: { $0.workflow.workflowId == workflowId }) else {
      throw AdapterExecutionError(.invalidInput, "unknown callee workflow '\(workflowId)'")
    }
    return callee
  }
}

private actor VariableRecordingAdapter: NodeAdapter {
  private let outputsByStep: [String: AdapterExecutionOutput]
  private let failingSteps: Set<String>
  private var recordedVariables: [String: JSONObject] = [:]

  init(outputsByStep: [String: AdapterExecutionOutput], failingSteps: Set<String> = []) {
    self.outputsByStep = outputsByStep
    self.failingSteps = failingSteps
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    recordedVariables[input.node.id] = input.mergedVariables
    if failingSteps.contains(input.node.id) {
      throw AdapterExecutionError(.providerError, "forced callee failure at '\(input.node.id)'")
    }
    return outputsByStep[input.node.id] ?? AdapterExecutionOutput(
      provider: "test",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["status": .string("ok")]
    )
  }

  func mergedVariables(forStep stepId: String) -> JSONObject? {
    recordedVariables[stepId]
  }
}
