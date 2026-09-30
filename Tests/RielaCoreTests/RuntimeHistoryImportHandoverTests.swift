import XCTest
@testable import RielaCore

final class RuntimeHistoryImportHandoverTests: XCTestCase {
  private struct BundleRejectionCase {
    var label: String
    var bundle: HandoverHistoryBundle
    var expectedMessage: String
  }

  func testImportsSuspendedAndFailedSessionsWithAnyFailureKind() async throws {
    let sourceStates: [(WorkflowSessionStatus, WorkflowSessionFailureKind?)] = [
      (.suspended, nil),
      (.failed, .stalled),
      (.failed, .cancelled),
      (.failed, .leaseLost)
    ]

    for (index, state) in sourceStates.enumerated() {
      let store = InMemoryWorkflowRuntimeStore()
      let source = makeSource(status: state.0, failureKind: state.1, sessionId: "source-\(index)")
      await store.seedSession(source.session)
      await store.seedWorkflowMessages(source.messages)
      let target = try await store.createSession(WorkflowSessionCreateInput(workflowId: "history", entryStepId: "resume"))

      let imported = try await store.importAcceptedHistory(WorkflowHistoryImportInput(
        sessionId: target.sessionId, sourceSessionId: source.session.sessionId,
        executions: source.session.executions, messages: source.messages))

      XCTAssertEqual(imported.status, .created)
      XCTAssertEqual(imported.currentStepId, target.entryStepId)
      XCTAssertEqual(imported.entryStepId, target.entryStepId)
      XCTAssertEqual(imported.executions.first?.importedFrom?.handoverId, nil)
      XCTAssertEqual(imported.executions.first?.importedFrom?.sessionId, source.session.sessionId)
      let messages = try await store.listMessages(for: target.sessionId, toStepId: nil)
      XCTAssertEqual(messages.count, 1)
      XCTAssertEqual(messages.first?.workflowExecutionId, target.sessionId)
      XCTAssertEqual(messages.first?.sourceStepExecutionId, imported.executions.first?.executionId)
      XCTAssertEqual(imported.executions.first?.importedFrom?.communicationIds[messages[0].communicationId], source.messages[0].communicationId)
    }
  }

  func testRejectsCompletedSessionSourceWithoutMutatingTarget() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let source = makeSource(status: .completed, sessionId: "completed-source")
    await store.seedSession(source.session)
    await store.seedWorkflowMessages(source.messages)
    let target = try await store.createSession(WorkflowSessionCreateInput(workflowId: "history", entryStepId: "resume"))

    do {
      _ = try await store.importAcceptedHistory(WorkflowHistoryImportInput(
        sessionId: target.sessionId, sourceSessionId: source.session.sessionId,
        executions: source.session.executions, messages: source.messages))
      XCTFail("completed sources must be refused")
    } catch {
      XCTAssertTrue(String(describing: error).contains("failed or suspended source session"))
    }

    let unchangedTarget = try await store.loadSession(id: target.sessionId)
    let unchangedMessages = try await store.listMessages(for: target.sessionId, toStepId: nil)
    XCTAssertEqual(unchangedTarget, target)
    XCTAssertTrue(unchangedMessages.isEmpty)
  }

  func testImportsBundleWithoutStoredSourceAndRecordsHandoverProvenance() async throws {
    let source = makeSource(status: .completed, sessionId: "remote-source")
    let store = InMemoryWorkflowRuntimeStore()
    let target = try await store.createSession(WorkflowSessionCreateInput(workflowId: "history", entryStepId: "resume"))
    let bundle = HandoverHistoryBundle(
      executions: source.session.executions, messages: source.messages, compatibilityDigests: [:], truncated: false)

    let imported = try await store.importAcceptedHistory(WorkflowHistoryImportInput(
      sessionId: target.sessionId, sourceSessionId: source.session.sessionId,
      bundle: bundle, handoverId: "handover-17"))

    XCTAssertEqual(imported.status, .created)
    XCTAssertEqual(imported.currentStepId, target.entryStepId)
    XCTAssertEqual(imported.entryStepId, target.entryStepId)
    XCTAssertEqual(imported.executions.first?.importedFrom?.handoverId, "handover-17")
    XCTAssertEqual(imported.executions.first?.importedFrom?.sessionId, source.session.sessionId)
    let messages = try await store.listMessages(for: target.sessionId, toStepId: nil)
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?.workflowExecutionId, target.sessionId)
    XCTAssertEqual(messages.first?.sourceStepExecutionId, imported.executions.first?.executionId)
    XCTAssertEqual(imported.executions.first?.importedFrom?.communicationIds[messages[0].communicationId], source.messages[0].communicationId)
  }

  func testRejectsInvalidBundleEvidenceWithoutMutatingTarget() async throws {
    let source = makeSource(status: .completed, sessionId: "remote-source")
    var duplicateStepExecutions = source.session.executions
    var duplicateStepExecution = try XCTUnwrap(source.session.executions.first)
    duplicateStepExecution.executionId = "remote-source-execution-2"
    duplicateStepExecutions.append(duplicateStepExecution)
    let cases = [
      BundleRejectionCase(label: "unknown execution", bundle: HandoverHistoryBundle(
        executions: source.session.executions,
        messages: [makeMessage(sessionId: "remote-source", executionId: "missing-execution")],
        compatibilityDigests: [:], truncated: false), expectedMessage: "lacks an accepted source execution"),
      BundleRejectionCase(label: "missing accepted output", bundle: HandoverHistoryBundle(
        executions: source.session.executions.map { execution in
          var changed = execution
          changed.acceptedOutput = nil
          return changed
        }, messages: source.messages, compatibilityDigests: [:], truncated: false),
        expectedMessage: "unique accepted completed executions"),
      BundleRejectionCase(label: "duplicate step", bundle: HandoverHistoryBundle(
        executions: duplicateStepExecutions, messages: source.messages, compatibilityDigests: [:], truncated: false),
        expectedMessage: "unique accepted completed executions")
    ]

    for rejection in cases {
      let store = InMemoryWorkflowRuntimeStore()
      let target = try await store.createSession(WorkflowSessionCreateInput(workflowId: "history", entryStepId: "resume"))
      do {
        _ = try await store.importAcceptedHistory(WorkflowHistoryImportInput(
          sessionId: target.sessionId, sourceSessionId: "remote-source", bundle: rejection.bundle, handoverId: "handover-invalid"))
        XCTFail("must reject bundle case: \(rejection.label)")
      } catch {
        XCTAssertTrue(String(describing: error).contains(rejection.expectedMessage), String(describing: error))
      }
      let unchangedTarget = try await store.loadSession(id: target.sessionId)
      let unchangedMessages = try await store.listMessages(for: target.sessionId, toStepId: nil)
      XCTAssertEqual(unchangedTarget, target)
      XCTAssertTrue(unchangedMessages.isEmpty)
    }
  }

  func testRejectsTruncatedBundleWithHandoverDiagnostic() async throws {
    let source = makeSource(status: .completed, sessionId: "remote-source")
    let store = InMemoryWorkflowRuntimeStore()
    let target = try await store.createSession(WorkflowSessionCreateInput(workflowId: "history", entryStepId: "resume"))
    let bundle = HandoverHistoryBundle(
      executions: source.session.executions, messages: source.messages, compatibilityDigests: [:], truncated: true)

    do {
      _ = try await store.importAcceptedHistory(WorkflowHistoryImportInput(
        sessionId: target.sessionId, sourceSessionId: source.session.sessionId,
        bundle: bundle, handoverId: "handover-truncated"))
      XCTFail("truncated history must be refused")
    } catch {
      XCTAssertTrue(String(describing: error).contains(
        "history bundle for handover handover-truncated is truncated; read the packet from the controller store"))
    }
    let unchangedTarget = try await store.loadSession(id: target.sessionId)
    XCTAssertEqual(unchangedTarget, target)
  }

  private func makeSource(
    status: WorkflowSessionStatus,
    failureKind: WorkflowSessionFailureKind? = nil,
    sessionId: String
  ) -> (session: WorkflowSession, messages: [WorkflowMessageRecord]) {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let execution = WorkflowStepExecution(
      executionId: "\(sessionId)-execution-1", stepId: "first", nodeId: "first-node", attempt: 1,
      status: .completed,
      acceptedOutput: WorkflowAcceptedOutputMetadata(payload: ["answer": .string("ready")], when: [:], acceptedAt: date),
      createdAt: date, updatedAt: date)
    let session = WorkflowSession(
      workflowId: "history", sessionId: sessionId, status: status, entryStepId: "first", currentStepId: "resume",
      createdAt: date, updatedAt: date, executions: [execution], failureKind: failureKind)
    return (session, [makeMessage(sessionId: sessionId, executionId: execution.executionId)])
  }

  private func makeMessage(sessionId: String, executionId: String) -> WorkflowMessageRecord {
    WorkflowMessageRecord(
      communicationId: "\(sessionId)-communication-1", workflowExecutionId: sessionId,
      fromStepId: "first", toStepId: "resume", sourceStepExecutionId: executionId,
      payload: ["answer": .string("ready")], lifecycleStatus: .delivered, createdOrder: 1,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
  }
}
