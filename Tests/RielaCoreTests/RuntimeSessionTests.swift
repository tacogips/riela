import XCTest
@testable import RielaCore

final class RuntimeSessionTests: XCTestCase {
  func testRuntimeSessionAndMessageRecordsEncodeDeterministically() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let acceptedOutput = WorkflowAcceptedOutputMetadata(
      payload: ["ok": .bool(true)],
      when: ["always": true],
      isRootOutput: true,
      acceptedAt: date
    )
    let adapterOutput = WorkflowAdapterOutputMetadata(
      provider: "codex-agent",
      model: "gpt-5",
      completionPassed: true,
      when: ["always": true]
    )
    let execution = WorkflowStepExecution(
      executionId: "exec-step-1",
      stepId: "step-1",
      nodeId: "node-1",
      attempt: 1,
      backend: .codexAgent,
      status: .completed,
      acceptedOutput: acceptedOutput,
      adapterOutput: adapterOutput,
      lastBackendEventAt: date,
      lastBackendEventType: "turn.started",
      createdAt: date,
      updatedAt: date
    )
    let session = WorkflowSession(
      workflowId: "workflow-a",
      sessionId: "session-a",
      status: .running,
      entryStepId: "step-1",
      currentStepId: "step-2",
      createdAt: date,
      updatedAt: date,
      executions: [execution]
    )
    let message = WorkflowMessageRecord(
      communicationId: "comm-000001",
      workflowExecutionId: "session-a",
      fromStepId: "step-1",
      toStepId: "step-2",
      sourceStepExecutionId: "exec-step-1",
      transitionCondition: "always",
      payload: ["ok": .bool(true)],
      createdOrder: 1,
      createdAt: date
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let decodedSession = try JSONDecoder().decode(WorkflowSession.self, from: encoder.encode(session))
    let decodedMessage = try JSONDecoder().decode(WorkflowMessageRecord.self, from: encoder.encode(message))

    XCTAssertEqual(decodedSession, session)
    XCTAssertEqual(decodedMessage, message)
    XCTAssertEqual(decodedSession.workflowExecutionId, "session-a")
    XCTAssertEqual(decodedSession.executions.first?.adapterOutput?.provider, "codex-agent")
    XCTAssertEqual(decodedSession.executions.first?.lastBackendEventAt, date)
    XCTAssertEqual(decodedSession.executions.first?.lastBackendEventType, "turn.started")
    XCTAssertEqual(decodedMessage.communicationId, "comm-000001")
  }

  func testRuntimeSessionDecodesSkippedStepExecutionStatus() throws {
    let data = Data(
      """
      {
        "workflowId": "workflow-a",
        "sessionId": "session-a",
        "status": "completed",
        "entryStepId": "filtered",
        "currentStepId": "filtered",
        "createdAt": 700000000,
        "updatedAt": 700000001,
        "executions": [
          {
            "executionId": "filtered-attempt-1-exec-1",
            "stepId": "filtered",
            "nodeId": "filtered-node",
            "attempt": 1,
            "status": "skipped",
            "acceptedOutput": {
              "payload": {
                "inputFilterSkipped": true
              },
              "when": {
                "input_filter_skipped": true
              },
              "isRootOutput": false,
              "acceptedAt": 700000001
            },
            "createdAt": 700000000,
            "updatedAt": 700000001
          }
        ]
      }
      """.utf8
    )

    let session = try JSONDecoder().decode(WorkflowSession.self, from: data)

    XCTAssertEqual(session.status, .completed)
    XCTAssertEqual(session.executions.first?.status, .skipped)
    XCTAssertEqual(session.executions.first?.acceptedOutput?.payload["inputFilterSkipped"], .bool(true))
    XCTAssertEqual(session.executions.first?.acceptedOutput?.when["input_filter_skipped"], true)
    XCTAssertEqual(session.executions.first?.acceptedOutput?.routingDiagnostics, [])
    XCTAssertNil(session.executions.first?.lastBackendEventAt)
    XCTAssertNil(session.executions.first?.lastBackendEventType)
  }

  func testWorkflowStepExecutionDecodesLegacyJSONWithoutUsage() throws {
    let data = Data(
      """
      {
        "executionId": "exec-legacy",
        "stepId": "step-1",
        "nodeId": "node-1",
        "attempt": 1,
        "status": "completed",
        "createdAt": 700000000,
        "updatedAt": 700000001
      }
      """.utf8
    )

    let execution = try JSONDecoder().decode(WorkflowStepExecution.self, from: data)

    XCTAssertEqual(execution.executionId, "exec-legacy")
    XCTAssertNil(execution.usage)
  }

  func testWorkflowSessionWorkflowExecutionIdAliasesSessionId() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    var session = WorkflowSession(
      workflowId: "workflow-a",
      sessionId: "session-a",
      entryStepId: "step-1",
      createdAt: date,
      updatedAt: date
    )

    XCTAssertEqual(session.workflowExecutionId, "session-a")

    session.workflowExecutionId = "session-b"

    XCTAssertEqual(session.sessionId, "session-b")
    XCTAssertEqual(session.workflowExecutionId, "session-b")
  }

  func testWorkflowSessionDecodesLegacyJSONWithoutInstanceFields() throws {
    let data = Data(
      """
      {
        "workflowId": "workflow-a",
        "sessionId": "session-a",
        "status": "completed",
        "entryStepId": "step-1",
        "createdAt": 700000000,
        "updatedAt": 700000001,
        "executions": []
      }
      """.utf8
    )

    let session = try JSONDecoder().decode(WorkflowSession.self, from: data)

    XCTAssertNil(session.instanceIdentity)
    XCTAssertNil(session.instanceKind)
    XCTAssertNil(session.instanceBaseIdentity)
    XCTAssertNil(session.instanceConfiguration)
  }
}
