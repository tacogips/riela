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
    XCTAssertEqual(decodedSession.executions.first?.adapterOutput?.provider, "codex-agent")
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
  }
}
