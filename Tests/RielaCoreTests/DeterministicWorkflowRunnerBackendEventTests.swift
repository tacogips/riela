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
}
