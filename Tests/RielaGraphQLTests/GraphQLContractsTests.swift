import Foundation
import XCTest
@testable import RielaCore
@testable import RielaGraphQL

final class GraphQLContractsTests: XCTestCase {
  func testProjectsRuntimeSessionAndMessagesIntoStableDTOs() {
    let date = Date(timeIntervalSince1970: 1)
    let session = WorkflowSession(
      workflowId: "workflow-a",
      sessionId: "session-a",
      status: .running,
      entryStepId: "step-1",
      currentStepId: "step-2",
      createdAt: date,
      updatedAt: date,
      executions: [
        .init(executionId: "exec-1", stepId: "step-1", nodeId: "node-1", attempt: 1, backend: .codexAgent, status: .completed, createdAt: date, updatedAt: date)
      ]
    )
    let message = WorkflowMessageRecord(
      communicationId: "comm-1",
      workflowExecutionId: "session-a",
      fromStepId: "step-1",
      toStepId: "step-2",
      sourceStepExecutionId: "exec-1",
      payload: ["ok": .bool(true)],
      lifecycleStatus: .delivered,
      createdOrder: 1,
      createdAt: date
    )

    let dto = GraphQLContractProjector.project(
      session: session,
      communications: [message],
      hookEvents: [.init(vendor: "codex", eventName: "PostToolUse", agentSessionId: "agent-session")],
      eventReceipts: [.init(sourceId: "web-a", eventId: "evt-1", status: "dry-run")],
      replyDispatches: [.init(sourceId: "web-a", provider: "web", payload: ["text": .string("hi")])],
      logs: [.init(level: "info", message: "ready")],
      llmSessionMessages: [.init(role: "assistant", content: "done")]
    )

    XCTAssertEqual(dto.workflowId, "workflow-a")
    XCTAssertEqual(dto.stepExecutions.first?.backend, "codex-agent")
    XCTAssertEqual(dto.communications.first?.lifecycleStatus, "delivered")
    XCTAssertEqual(dto.hookEvents.first?.eventName, "PostToolUse")
    XCTAssertNil(dto.loopEvidence)
    XCTAssertTrue(dto.loopGates.isEmpty)
    XCTAssertNil(dto.loopRecovery)
    XCTAssertTrue(GraphQLContractProjector.schemaContract.contains("continueSession"))
  }

  func testProjectsPersistedLoopEvidenceFromRuntimeSnapshot() {
    let date = Date(timeIntervalSince1970: 1_000)
    let session = WorkflowSession(
      workflowId: "workflow-loop",
      sessionId: "session-loop",
      status: .completed,
      entryStepId: "step-1",
      currentStepId: nil,
      createdAt: date,
      updatedAt: date
    )
    let message = WorkflowMessageRecord(
      communicationId: "comm-loop",
      workflowExecutionId: "session-loop",
      fromStepId: "step-1",
      toStepId: nil,
      sourceStepExecutionId: "exec-loop",
      payload: ["ok": .bool(true)],
      lifecycleStatus: .delivered,
      createdOrder: 1,
      createdAt: date
    )
    let evidence = LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "manifest-loop",
      workflowId: "workflow-loop",
      sessionId: "session-loop",
      workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow-directory", mutable: true),
      policy: LoopPolicyEvidence(),
      recovery: LoopRecoveryLineage(
        entryMode: .rerun,
        sourceSessionId: "source-session",
        sourceStepId: "step-1",
        inputReusePolicy: "accepted-output",
        preservedFailureEvidenceRefs: ["failure.json"]
      ),
      gates: [
        LoopGateResult(
          gateId: "implementation-review",
          stepId: "step-1",
          stepExecutionId: "exec-loop",
          decision: .accepted,
          severityCounts: LoopFindingSeverityCounts(high: 0, medium: 1),
          blockingFindings: [
            LoopBlockingFinding(
              id: "finding-1",
              severity: "medium",
              filePath: "Sources/File.swift",
              line: 12,
              message: "review note",
              evidenceRefs: ["review.json"]
            )
          ],
          evidenceRefs: ["review.json"],
          residualRisks: [
            LoopResidualRisk(severity: "low", message: "follow-up", evidenceRefs: ["risk.json"], accepted: true)
          ],
          acceptedAt: date,
          diagnostics: ["ok"]
        )
      ],
      redaction: LoopRedactionSummary(policyName: "default", status: "clean"),
      createdAt: date,
      updatedAt: date
    )
    let snapshot = WorkflowRuntimePersistenceSnapshot(
      session: session,
      workflowMessages: [message],
      loopEvidence: evidence
    )

    let dto = GraphQLContractProjector.project(snapshot: snapshot)

    XCTAssertEqual(dto.workflowId, "workflow-loop")
    XCTAssertEqual(dto.communications.map(\.communicationId), ["comm-loop"])
    XCTAssertEqual(dto.loopEvidence?.manifestId, "manifest-loop")
    XCTAssertEqual(dto.loopEvidence?.gateCount, 1)
    XCTAssertEqual(dto.loopEvidence?.acceptedGateCount, 1)
    XCTAssertEqual(dto.loopEvidence?.blockingFindingCount, 1)
    XCTAssertEqual(dto.loopEvidence?.redactionStatus, "clean")
    XCTAssertEqual(dto.loopGates.first?.gateId, "implementation-review")
    XCTAssertEqual(dto.loopGates.first?.decision, "accepted")
    XCTAssertEqual(dto.loopGates.first?.severityCounts.medium, 1)
    XCTAssertEqual(dto.loopGates.first?.blockingFindings.first?.filePath, "Sources/File.swift")
    XCTAssertEqual(dto.loopGates.first?.residualRisks.first?.message, "follow-up")
    XCTAssertEqual(dto.loopRecovery?.entryMode, "rerun")
    XCTAssertEqual(dto.loopRecovery?.sourceSessionId, "source-session")
    XCTAssertEqual(dto.loopRecovery?.preservedFailureEvidenceRefs, ["failure.json"])
  }

  func testRuntimeSnapshotQueryServiceReturnsLoopEvidenceSummary() async {
    let date = Date(timeIntervalSince1970: 1_000)
    let snapshot = WorkflowRuntimePersistenceSnapshot(
      session: workflowSession(workflowId: "workflow-loop", sessionId: "session-loop", date: date),
      loopEvidence: loopEvidenceManifest(workflowId: "workflow-loop", sessionId: "session-loop", date: date)
    )
    let service = GraphQLRuntimeSnapshotQueryService { sessionId in
      guard sessionId == "session-loop" else {
        throw WorkflowRuntimePersistenceStoreError.notFound(sessionId)
      }
      return snapshot
    }

    let result = await service.loopEvidence(.init(workflowId: "workflow-loop", sessionId: "session-loop"))

    XCTAssertTrue(result.result.accepted)
    XCTAssertEqual(result.result.status, GraphQLLoopEvidenceQueryStatus.found.rawValue)
    XCTAssertEqual(result.evidence?.manifestId, "manifest-loop")
    XCTAssertEqual(result.evidence?.gateCount, 1)
    XCTAssertEqual(result.gates.first?.gateId, "implementation-review")
    XCTAssertEqual(result.recovery?.entryMode, "rerun")
  }

  func testRuntimeSnapshotQueryServiceDistinguishesMissingSession() async {
    let service = GraphQLRuntimeSnapshotQueryService { sessionId in
      throw WorkflowRuntimePersistenceStoreError.notFound(sessionId)
    }

    let result = await service.loopEvidence(.init(workflowId: "workflow-loop", sessionId: "missing-session"))

    XCTAssertFalse(result.result.accepted)
    XCTAssertEqual(result.result.status, GraphQLLoopEvidenceQueryStatus.notFound.rawValue)
    XCTAssertNil(result.evidence)
  }

  func testRuntimeSnapshotQueryServiceDistinguishesMissingLoopEvidence() async {
    let date = Date(timeIntervalSince1970: 1_000)
    let snapshot = WorkflowRuntimePersistenceSnapshot(
      session: workflowSession(workflowId: "workflow-loop", sessionId: "session-loop", date: date)
    )
    let service = GraphQLRuntimeSnapshotQueryService { _ in snapshot }

    let result = await service.loopEvidence(.init(workflowId: "workflow-loop", sessionId: "session-loop"))

    XCTAssertFalse(result.result.accepted)
    XCTAssertEqual(result.result.status, GraphQLLoopEvidenceQueryStatus.noEvidence.rawValue)
    XCTAssertNil(result.evidence)
  }

  func testSchemaContractExposesStableInspectionDTOFields() {
    let schema = GraphQLContractProjector.schemaContract

    for field in [
      "type ControlPlaneResult",
      "type ManagerIntentSummary",
      "type SendManagerMessagePayload",
      "type ReplayCommunicationPayload",
      "type RetryCommunicationDeliveryPayload",
      "hookEvents: [HookEvent!]!",
      "eventReceipts: [EventReceipt!]!",
      "replyDispatches: [ReplyDispatch!]!",
      "logs: [LogEntry!]!",
      "llmSessionMessages: [LLMSessionMessage!]!",
      "type LoopEvidenceSummary",
      "type LoopGateResult",
      "type LoopRecoveryLineage",
      "loopEvidence: LoopEvidenceSummary",
      "loopGates: [LoopGateResult!]!",
      "loopRecovery: LoopRecoveryLineage",
      "loopEvidence(workflowId: String!, sessionId: String!): LoopEvidenceSummary",
      "createdOrder: Int!",
      "failureReason: String",
      "input ContinueSessionInput { workflowId: String!, sessionId: String!, input: JSONObject! }",
      "input SendManagerMessageInput { workflowId: String!, workflowExecutionId: String!, message: String, actions: JSON, attachments: JSON, idempotencyKey: String, managerSessionId: String, managerNodeExecId: String }",
      "input ReplayCommunicationInput { workflowId: String!, workflowExecutionId: String!, communicationId: String!, reason: String, idempotencyKey: String, managerSessionId: String }",
      "input RetryCommunicationDeliveryInput { workflowId: String!, workflowExecutionId: String!, communicationId: String!, reason: String, idempotencyKey: String, managerSessionId: String }",
      "managerSession(managerSessionId: String): ManagerSessionView",
      "continueSession(input: ContinueSessionInput!): ControlPlaneResult!",
      "sendManagerMessage(input: SendManagerMessageInput!): SendManagerMessagePayload!",
      "replayCommunication(input: ReplayCommunicationInput!): ReplayCommunicationPayload!",
      "retryCommunicationDelivery(input: RetryCommunicationDeliveryInput!): RetryCommunicationDeliveryPayload!"
    ] {
      XCTAssertTrue(schema.contains(field), "missing schema field: \(field)")
    }
    XCTAssertFalse(schema.contains("continueSession(workflowId: String!, sessionId: String!)"))
    XCTAssertFalse(schema.contains("managerRuntimeId"))
  }

  func testManagerControlRequestsPreserveInputShapeAndIdempotency() throws {
    let send = GraphQLSendManagerMessageRequest(
      workflowId: "workflow-a",
      workflowExecutionId: "exec-a",
      message: "resume",
      actions: .object(["retryStepIds": .array([.string("worker-step")])]),
      attachments: .array([.object(["path": .string("files/workflow-a/exec-a/a.png")])]),
      idempotencyKey: "idem-send",
      managerSessionId: "mgrsess-1",
      managerNodeExecId: "node-exec-1"
    )
    let replay = GraphQLReplayCommunicationRequest(
      workflowId: "workflow-a",
      workflowExecutionId: "exec-a",
      communicationId: "comm-1",
      reason: "retry downstream",
      idempotencyKey: "idem-replay",
      managerSessionId: "mgrsess-1"
    )
    let sendObject = try encodedObject(send)
    let replayObject = try encodedObject(replay)

    XCTAssertEqual(sendObject["idempotencyKey"], .string("idem-send"))
    XCTAssertEqual(sendObject["managerSessionId"], .string("mgrsess-1"))
    XCTAssertEqual(sendObject["managerNodeExecId"], .string("node-exec-1"))
    XCTAssertEqual(sendObject["workflowExecutionId"], .string("exec-a"))
    XCTAssertEqual(sendObject["actions"], .object(["retryStepIds": .array([.string("worker-step")])]))
    XCTAssertEqual(sendObject["attachments"], .array([.object(["path": .string("files/workflow-a/exec-a/a.png")])]))
    XCTAssertEqual(replayObject["communicationId"], .string("comm-1"))
    XCTAssertEqual(replayObject["idempotencyKey"], .string("idem-replay"))
    XCTAssertNil(sendObject["communicationId"])
  }

  func testManagerControlPayloadsExposeResultFields() {
    let sendPayload = GraphQLSendManagerMessagePayload(
      accepted: true,
      managerMessageId: "mgrmsg-1",
      parsedIntent: [.init(kind: "retry-step", targetId: "worker-step", reason: "operator")],
      createdCommunicationIds: ["comm-2"],
      queuedNodeIds: ["worker-step"],
      workflowId: "workflow-a",
      workflowExecutionId: "exec-a",
      managerSessionId: "mgrsess-1"
    )
    let replayPayload = GraphQLReplayCommunicationPayload(
      sourceCommunicationId: "comm-1",
      workflowExecutionId: "exec-a",
      replayedCommunicationId: "comm-2",
      status: "queued"
    )
    let retryPayload = GraphQLRetryCommunicationDeliveryPayload(
      communicationId: "comm-2",
      activeDeliveryAttemptId: "attempt-1",
      status: "queued"
    )

    XCTAssertTrue(sendPayload.accepted)
    XCTAssertEqual(sendPayload.createdCommunicationIds, ["comm-2"])
    XCTAssertEqual(sendPayload.parsedIntent.first?.kind, "retry-step")
    XCTAssertEqual(replayPayload.replayedCommunicationId, "comm-2")
    XCTAssertEqual(retryPayload.activeDeliveryAttemptId, "attempt-1")
  }

  private func encodedObject<T: Encodable>(_ value: T) throws -> JSONObject {
    let data = try JSONEncoder().encode(value)
    guard case let .object(object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
      return [:]
    }
    return object
  }

  private func workflowSession(workflowId: String, sessionId: String, date: Date) -> WorkflowSession {
    WorkflowSession(
      workflowId: workflowId,
      sessionId: sessionId,
      status: .completed,
      entryStepId: "step-1",
      currentStepId: nil,
      createdAt: date,
      updatedAt: date
    )
  }

  private func loopEvidenceManifest(workflowId: String, sessionId: String, date: Date) -> LoopEvidenceManifest {
    LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "manifest-loop",
      workflowId: workflowId,
      sessionId: sessionId,
      workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow-directory", mutable: true),
      policy: LoopPolicyEvidence(),
      recovery: LoopRecoveryLineage(
        entryMode: .rerun,
        sourceSessionId: "source-session",
        sourceStepId: "step-1",
        inputReusePolicy: "accepted-output",
        preservedFailureEvidenceRefs: ["failure.json"]
      ),
      gates: [
        LoopGateResult(
          gateId: "implementation-review",
          stepId: "step-1",
          stepExecutionId: "exec-loop",
          decision: .accepted,
          severityCounts: LoopFindingSeverityCounts(high: 0, medium: 1),
          blockingFindings: [],
          evidenceRefs: ["review.json"],
          acceptedAt: date,
          diagnostics: ["ok"]
        )
      ],
      redaction: LoopRedactionSummary(policyName: "default", status: "clean"),
      createdAt: date,
      updatedAt: date
    )
  }
}
