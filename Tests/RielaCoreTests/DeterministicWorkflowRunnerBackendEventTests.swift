import Foundation
import XCTest
@testable import RielaCore

// swiftlint:disable:next type_name
final class DeterministicWorkflowRunnerBackendEventTests: XCTestCase {
  func testWorkflowRunEventDecodesLegacyBackendEventJSON() throws {
    let data = Data(
      """
      {
        "type": "backend_event",
        "workflowId": "wf",
        "sessionId": "session",
        "stepId": "step",
        "nodeId": "node",
        "executionId": "exec",
        "backendEventType": "turn.started"
      }
      """.utf8
    )

    let event = try JSONDecoder().decode(WorkflowRunEvent.self, from: data)

    XCTAssertEqual(event.type, .backendEvent)
    guard case .backendEvent(_, _, let payload) = event else {
      return XCTFail("expected backend event payload")
    }
    XCTAssertEqual(event.backendEventType, "turn.started")
    XCTAssertEqual(payload.backendEventType, "turn.started")
    XCTAssertNil(event.backendEventChannel)
    XCTAssertNil(event.backendEventContent)
    XCTAssertNil(event.backendEventSequence)
  }

  func testWorkflowRunEventInitializerDropsIrrelevantFieldsForEventType() throws {
    let event = WorkflowRunEvent(
      type: .sessionStarted,
      workflowId: "wf",
      sessionId: "session",
      stepId: "step",
      backendEventType: "turn.started",
      exitCode: 1,
      nodeExecutions: 2,
      transitions: 3
    )

    guard case .sessionStarted(let session) = event else {
      return XCTFail("expected session started event")
    }
    XCTAssertEqual(session.workflowId, "wf")
    XCTAssertEqual(session.sessionId, "session")
    XCTAssertNil(event.stepId)
    XCTAssertNil(event.backendEventType)
    XCTAssertNil(event.exitCode)
    XCTAssertNil(event.nodeExecutions)
    XCTAssertNil(event.transitions)
  }

  func testWorkflowRunEventEncodesEnrichedBackendEventFields() throws {
    let event = WorkflowRunEvent(
      type: .backendEvent,
      workflowId: "wf",
      sessionId: "session",
      stepId: "step",
      nodeId: "node",
      executionId: "exec",
      backendEventType: "thinking",
      backendEventChannel: "thinking",
      backendEventContent: "stream",
      backendEventIsDelta: true,
      backendEventSequence: 7,
      backendToolName: "shell",
      backendEventUsage: ["output_tokens": .number(3)]
    )

    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
    )
    let usage = try XCTUnwrap(object["backendEventUsage"] as? [String: Any])

    XCTAssertEqual(object["type"] as? String, "backend_event")
    XCTAssertEqual(object["backendEventType"] as? String, "thinking")
    XCTAssertEqual(object["backendEventChannel"] as? String, "thinking")
    XCTAssertEqual(object["backendEventContent"] as? String, "stream")
    XCTAssertEqual(object["backendEventIsDelta"] as? Bool, true)
    XCTAssertEqual(object["backendEventSequence"] as? Int, 7)
    XCTAssertEqual(object["backendToolName"] as? String, "shell")
    XCTAssertEqual(usage["output_tokens"] as? Int, 3)
  }

  func testWorkflowRunEventEncodesSilenceWarningFields() throws {
    let event = WorkflowRunEvent(
      type: .silenceWarning,
      workflowId: "wf",
      sessionId: "session",
      stepId: "step",
      nodeId: "node",
      executionId: "exec",
      silentForMs: 12_345,
      silenceThresholdMs: 10_000,
      nodeExecutions: 1
    )

    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
    )

    XCTAssertEqual(object["type"] as? String, "silence_warning")
    XCTAssertEqual(object["silentForMs"] as? Int, 12_345)
    XCTAssertEqual(object["silenceThresholdMs"] as? Int, 10_000)
    XCTAssertEqual(object["nodeExecutions"] as? Int, 1)
    XCTAssertNil(object["backendEventType"])
  }

  func testBackendEventHandlerUpdatesRunningExecutionHeartbeatAndEmitsRunEvent() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let recorder = WorkflowRunEventRecorder()
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: BackendEventEmittingAdapter(
        event: AdapterBackendEvent(
          provider: "codex-agent",
          eventType: "item.completed",
          channel: .assistant,
          contentSnapshot: "streamed text",
          usage: ["output_tokens": .number(3)],
          sequence: 99
        )
      )
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: backendEventWorkflow(),
      nodePayloads: ["node": backendEventPayload()],
      eventHandler: { event in
        await recorder.append(event)
      }
    ))

    let execution = try XCTUnwrap(result.session.executions.first)
    XCTAssertEqual(execution.lastBackendEventType, "item.completed")
    XCTAssertNotNil(execution.lastBackendEventAt)
    XCTAssertEqual(execution.backendEventCount, 1)
    XCTAssertEqual(execution.streamedResponseText, "streamed text")
    XCTAssertEqual(execution.recentBackendEvents?.first?.content, "streamed text")
    let events = await recorder.events()
    XCTAssertTrue(events.contains { event in
      event.type == .backendEvent &&
        event.executionId == execution.executionId &&
        event.backendEventType == "item.completed" &&
        event.backendEventChannel == "assistant" &&
        event.backendEventContent == "streamed text" &&
        event.backendEventSequence == 1 &&
        event.nodeExecutions == 1 &&
        event.backendEventUsage?["output_tokens"] == .number(3)
    })
  }

  func testAgentSilenceMonitorEmitsWarningEvent() async throws {
    let recorder = WorkflowRunEventRecorder()
    let runner = DeterministicWorkflowRunner(
      adapter: HeartbeatThenSleepingAdapter(delayNanoseconds: 60_000_000)
    )

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: backendEventWorkflow(),
      nodePayloads: ["node": backendEventPayload()],
      agentSilenceWarningMs: 10,
      agentSilenceMonitorIntervalMs: 5,
      eventHandler: { event in
        await recorder.append(event)
      }
    ))

    let events = await recorder.events()
    let warning = try XCTUnwrap(events.first { $0.type == .silenceWarning })
    XCTAssertEqual(warning.stepId, "step")
    XCTAssertEqual(warning.nodeId, "node")
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(warning.silentForMs), 10)
    XCTAssertEqual(warning.silenceThresholdMs, 10)
  }

  func testAgentSilenceMonitorRepeatsWarningEventAcrossSustainedSilence() async throws {
    let recorder = WorkflowRunEventRecorder()
    let runner = DeterministicWorkflowRunner(
      adapter: HeartbeatThenSleepingAdapter(delayNanoseconds: 80_000_000)
    )

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: backendEventWorkflow(),
      nodePayloads: ["node": backendEventPayload()],
      agentSilenceWarningMs: 10,
      agentSilenceMonitorIntervalMs: 5,
      eventHandler: { event in
        await recorder.append(event)
      }
    ))

    let events = await recorder.events()
    let warnings = events.filter { $0.type == .silenceWarning }
    XCTAssertGreaterThanOrEqual(warnings.count, 2)
    XCTAssertTrue(warnings.allSatisfy { $0.stepId == "step" && $0.nodeId == "node" })
    let silentDurations = warnings.compactMap(\.silentForMs)
    XCTAssertEqual(silentDurations.count, warnings.count)
    XCTAssertGreaterThanOrEqual(silentDurations.last ?? 0, silentDurations.first ?? 0)
  }

  func testAgentSilenceMonitorDoesNotWarnBeforeFirstBackendEvent() async throws {
    let recorder = WorkflowRunEventRecorder()
    let runner = DeterministicWorkflowRunner(
      adapter: SleepingAdapter(delayNanoseconds: 60_000_000)
    )

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: backendEventWorkflow(),
      nodePayloads: ["node": backendEventPayload()],
      agentSilenceWarningMs: 10,
      agentSilenceMonitorIntervalMs: 5,
      eventHandler: { event in
        await recorder.append(event)
      }
    ))

    let events = await recorder.events()
    XCTAssertFalse(events.contains { $0.type == .silenceWarning })
  }

  func testOutputProjectionPublishesLatestInputPayloadWithoutAdapterCall() async throws {
    let adapter = StepCountingAdapter(outputsByStep: [
      "producer": AdapterExecutionOutput(
        provider: "test",
        model: "gpt-5.5",
        promptText: "producer",
        completionPassed: true,
        payload: ["status": .string("accepted"), "summary": .string("done")]
      )
    ])
    let runner = DeterministicWorkflowRunner(adapter: adapter)

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: outputProjectionWorkflow(),
      nodePayloads: outputProjectionPayloads()
    ))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.rootOutput?["status"], .string("accepted"))
    XCTAssertEqual(result.rootOutput?["summary"], .string("done"))
    let executedStepIds = await adapter.executedStepIds()
    XCTAssertEqual(executedStepIds, ["producer"])
  }

  private func backendEventWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "step", nodeId: "node")],
      nodes: [WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json")]
    )
  }

  private func backendEventPayload() -> AgentNodePayload {
    AgentNodePayload(id: "node", executionBackend: .codexAgent, model: "gpt-5.5")
  }

  private func outputProjectionWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "projection",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "producer",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "producer-node", nodeFile: "nodes/producer.json"),
        WorkflowNodeRegistryRef(id: "output-node", nodeFile: "nodes/output.json", kind: .output)
      ],
      steps: [
        WorkflowStepRef(
          id: "producer",
          nodeId: "producer-node",
          transitions: [WorkflowStepTransition(toStepId: "workflow-output")]
        ),
        WorkflowStepRef(id: "workflow-output", nodeId: "output-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "producer-node", nodeFile: "nodes/producer.json"),
        WorkflowNodeRef(id: "output-node", nodeFile: "nodes/output.json", kind: .output)
      ]
    )
  }

  private func outputProjectionPayloads() -> [String: AgentNodePayload] {
    [
      "producer-node": AgentNodePayload(id: "producer-node", executionBackend: .codexAgent, model: "gpt-5.5"),
      "output-node": AgentNodePayload(
        id: "output-node",
        model: "",
        output: NodeOutputContract(projection: WorkflowOutputProjection(kind: .latestInputPayload))
      )
    ]
  }
}

private actor SleepingAdapter: NodeAdapter {
  var delayNanoseconds: UInt64

  init(delayNanoseconds: UInt64) {
    self.delayNanoseconds = delayNanoseconds
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    try await Task.sleep(nanoseconds: delayNanoseconds)
    return AdapterExecutionOutput(
      provider: "test",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["status": .string("ok")]
    )
  }
}

private actor HeartbeatThenSleepingAdapter: NodeAdapter {
  var delayNanoseconds: UInt64

  init(delayNanoseconds: UInt64) {
    self.delayNanoseconds = delayNanoseconds
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    await context.backendEventHandler?(AdapterBackendEvent(
      provider: input.node.executionBackend?.rawValue ?? "test",
      eventType: "turn.started",
      channel: .lifecycle
    ))
    try await Task.sleep(nanoseconds: delayNanoseconds)
    return AdapterExecutionOutput(
      provider: "test",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["status": .string("ok")]
    )
  }
}

private actor StepCountingAdapter: NodeAdapter {
  private var stepIds: [String] = []
  private var outputsByStep: [String: AdapterExecutionOutput]

  init(outputsByStep: [String: AdapterExecutionOutput]) {
    self.outputsByStep = outputsByStep
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    stepIds.append(input.node.id)
    return outputsByStep[input.node.id] ?? AdapterExecutionOutput(
      provider: "test",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["status": .string("ok")]
    )
  }

  func executedStepIds() -> [String] {
    stepIds
  }
}
