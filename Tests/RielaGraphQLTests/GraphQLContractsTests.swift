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
    XCTAssertEqual(dto.sessionId, "session-a")
    XCTAssertEqual(dto.workflowExecutionId, "session-a")
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

  func testRuntimeSnapshotQueryServiceListsFilteredSessionSummaries() async {
    let snapshots = [
      WorkflowRuntimePersistenceSnapshot(
        session: workflowSession(
          workflowId: "workflow-a",
          sessionId: "session-old",
          status: .failed,
          date: Date(timeIntervalSince1970: 10),
          failureKind: .adapterFailure
        )
      ),
      WorkflowRuntimePersistenceSnapshot(
        session: workflowSession(
          workflowId: "workflow-b",
          sessionId: "session-other",
          status: .failed,
          date: Date(timeIntervalSince1970: 30),
          failureKind: .maxStepsExceeded
        )
      ),
      WorkflowRuntimePersistenceSnapshot(
        session: workflowSession(
          workflowId: "workflow-a",
          sessionId: "session-new",
          status: .failed,
          date: Date(timeIntervalSince1970: 50),
          failureKind: .maxStepsExceeded
        )
      )
    ]
    let service = GraphQLRuntimeSnapshotQueryService(
      loadSnapshot: { _ in snapshots[0] },
      loadSnapshots: { snapshots },
      sessionStore: "/tmp/session-store"
    )

    let result = await service.workflowSessions(.init(workflowName: "workflow-a", status: "failed", limit: 1))

    XCTAssertTrue(result.result.accepted)
    XCTAssertEqual(result.result.status, GraphQLLoopEvidenceQueryStatus.found.rawValue)
    XCTAssertEqual(result.sessions.map(\.sessionId), ["session-new"])
    XCTAssertEqual(result.sessions.first?.workflowName, "workflow-a")
    XCTAssertEqual(result.sessions.first?.failureKind, "maxStepsExceeded")
    XCTAssertEqual(result.sessions.first?.sessionStore, "/tmp/session-store")
  }

  func testWorkflowInstanceGraphQLServiceListsSavesAndDeletesInstances() async throws {
    let store = TestWorkflowInstanceStore()
    let service = GraphQLWorkflowInstanceService(store: store)
    let input = GraphQLWorkflowInstanceInput(
      identity: "prod",
      workflowId: "workflow-a",
      displayName: "Production",
      configuration: WorkflowInstanceConfiguration(defaultVariables: ["request": .string("go")])
    )

    let created = await service.createWorkflowInstance(input)
    XCTAssertTrue(created.result.accepted, created.result.diagnostics.joined(separator: "\n"))
    XCTAssertEqual(created.instance?.identity, "prod")

    let listed = await service.workflowInstances(workflowId: "workflow-a")
    XCTAssertEqual(listed.value?.map(\.identity), ["prod"])
    XCTAssertEqual(listed.value?.first?.configuration["defaultVariables"], .object(["request": .string("go")]))

    let found = await service.workflowInstance(identity: "prod", workflowId: "workflow-a")
    XCTAssertEqual(found.value?.displayName, "Production")

    let deleted = await service.deleteWorkflowInstance(identity: "prod", workflowId: "workflow-a")
    XCTAssertTrue(deleted.result.accepted, deleted.result.diagnostics.joined(separator: "\n"))
    let missing = await service.workflowInstance(identity: "prod", workflowId: "workflow-a")
    XCTAssertEqual(missing.result.status, GraphQLLoopEvidenceQueryStatus.notFound.rawValue)
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
      "workflowExecutionId: String!",
      "type WorkflowInstance",
      "type WorkflowInstanceQueryPayload",
      "type WorkflowInstancesQueryPayload",
      "type WorkflowInstanceMutationPayload",
      "input WorkflowInstanceInput { identity: String!, workflowId: String!, sourceIdentity: String, displayName: String, configuration: JSONObject }",
      "workflowInstances(workflowId: String): WorkflowInstancesQueryPayload!",
      "workflowInstance(identity: String!, workflowId: String): WorkflowInstanceQueryPayload!",
      "createWorkflowInstance(input: WorkflowInstanceInput!): WorkflowInstanceMutationPayload!",
      "updateWorkflowInstance(input: WorkflowInstanceInput!): WorkflowInstanceMutationPayload!",
      "deleteWorkflowInstance(identity: String!, workflowId: String): WorkflowInstanceMutationPayload!",
      "loopEvidence(workflowId: String!, sessionId: String!): LoopEvidenceSummary",
      "workflowSessions(workflowName: String, status: String, limit: Int): [WorkflowSessionSummary!]!",
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

  func testNoteGraphQLProjectionFieldsMatchSchemaContract() throws {
    for (typeName, projectionFields) in noteGraphQLSelectionFields {
      let schemaFields = try schemaFieldNames(typeName)

      XCTAssertEqual(
        Set(projectionFields.keys),
        schemaFields,
        "\(typeName) projection fields must match the GraphQL schema contract"
      )
    }
  }

  func testSchemaContractFieldSetsMatchEncodedDTOs() throws {
    let date = Date(timeIntervalSince1970: 2_000)
    let severityCounts = LoopFindingSeverityCounts(high: 1, medium: 2, low: 3, informational: 4)
    let finding = LoopBlockingFinding(
      id: "finding-a",
      severity: "high",
      filePath: "Sources/File.swift",
      line: 12,
      message: "fix",
      evidenceRefs: ["finding.json"]
    )
    let risk = LoopResidualRisk(
      severity: "medium",
      message: "watch",
      evidenceRefs: ["risk.json"],
      owner: "runtime",
      accepted: true
    )
    let gate = LoopGateResult(
      gateId: "gate-a",
      stepId: "step-a",
      stepExecutionId: "exec-a",
      decision: .needsWork,
      severityCounts: severityCounts,
      blockingFindings: [finding],
      evidenceRefs: ["gate.json"],
      rerunPolicy: "always",
      residualRisks: [risk],
      acceptedAt: date,
      diagnostics: ["diag"]
    )
    let recovery = LoopRecoveryLineage(
      entryMode: .retry,
      sourceSessionId: "source-session",
      sourceStepId: "source-step",
      sourceStepExecutionId: "source-exec",
      parentSessionId: "parent-session",
      childSessionIds: ["child-session"],
      reason: "operator",
      inputReusePolicy: "accepted-output",
      preservedFailureEvidenceRefs: ["failure.json"]
    )
    let loopEvidence = GraphQLLoopEvidenceSummaryDTO(
      summary: LoopEvidenceSummary(manifest: loopEvidenceManifest(workflowId: "workflow-a", sessionId: "session-a", date: date))
    )
    let loopGate = GraphQLLoopGateResultDTO(gate: gate)
    let loopRecovery = GraphQLLoopRecoveryLineageDTO(lineage: recovery)
    let expectedFieldsBySchemaType: [String: Set<String>] = [
      "ControlPlaneResult": try encodedFieldNames(GraphQLControlPlaneResult(accepted: true, status: "ok", diagnostics: ["ready"])),
      "ManagerIntentSummary": try encodedFieldNames(GraphQLManagerIntentSummaryDTO(kind: "retry-step", targetId: "step-a", reason: "operator")),
      "ManagerSessionView": try encodedFieldNames(GraphQLManagerSessionViewDTO(session: .object(["id": .string("s")]), messages: .array([]))),
      "SendManagerMessagePayload": try encodedFieldNames(GraphQLSendManagerMessagePayload(
        accepted: true,
        managerMessageId: "message-a",
        parsedIntent: [.init(kind: "retry-step", targetId: "step-a", reason: "operator")],
        createdCommunicationIds: ["comm-a"],
        queuedNodeIds: ["step-a"],
        rejectionReason: "none",
        workflowId: "workflow-a",
        workflowExecutionId: "session-a",
        managerSessionId: "manager-session"
      )),
      "ReplayCommunicationPayload": try encodedFieldNames(GraphQLReplayCommunicationPayload(
        sourceCommunicationId: "comm-a",
        workflowExecutionId: "session-a",
        replayedCommunicationId: "comm-b",
        status: "queued"
      )),
      "RetryCommunicationDeliveryPayload": try encodedFieldNames(GraphQLRetryCommunicationDeliveryPayload(
        communicationId: "comm-a",
        activeDeliveryAttemptId: "attempt-a",
        status: "queued"
      )),
      "LoopEvidenceSummary": try encodedFieldNames(loopEvidence),
      "LoopFindingSeverityCounts": try encodedFieldNames(GraphQLLoopFindingSeverityCountsDTO(counts: severityCounts)),
      "LoopBlockingFinding": try encodedFieldNames(GraphQLLoopBlockingFindingDTO(finding: finding)),
      "LoopResidualRisk": try encodedFieldNames(GraphQLLoopResidualRiskDTO(risk: risk)),
      "LoopGateResult": try encodedFieldNames(loopGate),
      "LoopRecoveryLineage": try encodedFieldNames(loopRecovery),
      "WorkflowSession": try encodedFieldNames(GraphQLWorkflowSessionDTO(
        workflowId: "workflow-a",
        sessionId: "session-a",
        status: "running",
        currentStepId: "step-a",
        lastCompletedStepId: "step-a",
        failureReason: "maxStepsExceeded(2)",
        failureKind: "maxStepsExceeded",
        stepBudgetDiagnostic: WorkflowStepBudgetDiagnostic(
          stepBudget: 2,
          executionCount: 2,
          maxLoopIterations: 1,
          budgetSource: .computedDefault,
          dominantCycleStepIds: ["step-a", "step-b"],
          dominantCycleRepeatCount: 2,
          perStepRevisitCap: 2,
          projectedCapExceededStepIds: ["step-a"],
          openReviewFindingCount: 0,
          unscheduledStepId: "step-b",
          suggestedMaxSteps: 4,
          suggestedRemediation: "session resume session-a --max-steps 4"
        ),
        instanceIdentity: "prod",
        instanceKind: "named",
        instanceBaseIdentity: "default",
        instanceConfiguration: ["defaultVariables": .object(["request": .string("ok")])],
        stepExecutions: [.init(executionId: "exec-a", stepId: "step-a", nodeId: "node-a", attempt: 1, backend: "codex-agent", status: "completed", failureReason: "none")],
        communications: [.init(communicationId: "comm-a", fromStepId: "step-a", toStepId: "step-b", lifecycleStatus: "delivered", deliveryKind: "direct", createdOrder: 1)],
        hookEvents: [.init(vendor: "codex", eventName: "PostToolUse", agentSessionId: "agent-session", payloadHash: "hash")],
        eventReceipts: [.init(sourceId: "source-a", eventId: "event-a", status: "received")],
        replyDispatches: [.init(sourceId: "source-a", provider: "telegram", payload: ["text": .string("ok")])],
        logs: [.init(level: "info", message: "ready")],
        llmSessionMessages: [.init(role: "assistant", content: "done")],
        loopEvidence: loopEvidence,
        loopGates: [loopGate],
        loopRecovery: loopRecovery
      )),
      "StepBudgetDiagnostic": try encodedFieldNames(WorkflowStepBudgetDiagnostic(
        stepBudget: 2,
        executionCount: 2,
        maxLoopIterations: 1,
        budgetSource: .computedDefault,
        dominantCycleStepIds: ["step-a", "step-b"],
        dominantCycleRepeatCount: 2,
        perStepRevisitCap: 2,
        projectedCapExceededStepIds: ["step-a"],
        openReviewFindingCount: 0,
        unscheduledStepId: "step-b",
        suggestedMaxSteps: 4,
        suggestedRemediation: "session resume session-a --max-steps 4"
      )),
      "WorkflowSessionSummary": try encodedFieldNames(GraphQLWorkflowSessionSummaryDTO(
        sessionId: "session-a",
        workflowName: "workflow-a",
        status: "failed",
        failureKind: "maxStepsExceeded",
        currentStepId: "step-b",
        instanceIdentity: "prod",
        instanceKind: "named",
        executionCount: 2,
        updatedAt: Date(timeIntervalSince1970: 1),
        sessionStore: "/tmp/sessions"
      )),
      "StepExecution": try encodedFieldNames(GraphQLStepExecutionDTO(executionId: "exec-a", stepId: "step-a", nodeId: "node-a", attempt: 1, backend: "codex-agent", status: "completed", failureReason: "none")),
      "Communication": try encodedFieldNames(GraphQLCommunicationDTO(communicationId: "comm-a", fromStepId: "step-a", toStepId: "step-b", lifecycleStatus: "delivered", deliveryKind: "direct", createdOrder: 1)),
      "HookEvent": try encodedFieldNames(GraphQLHookEventDTO(vendor: "codex", eventName: "PostToolUse", agentSessionId: "agent-session", payloadHash: "hash")),
      "EventReceipt": try encodedFieldNames(GraphQLEventReceiptDTO(sourceId: "source-a", eventId: "event-a", status: "received")),
      "ReplyDispatch": try encodedFieldNames(GraphQLReplyDispatchDTO(sourceId: "source-a", provider: "telegram", payload: ["text": .string("ok")])),
      "LogEntry": try encodedFieldNames(GraphQLLogEntryDTO(level: "info", message: "ready")),
      "LLMSessionMessage": try encodedFieldNames(GraphQLLLMSessionMessageDTO(role: "assistant", content: "done")),
      "ContinueSessionInput": try encodedFieldNames(GraphQLContinueSessionRequest(workflowId: "workflow-a", sessionId: "session-a", input: ["ok": .bool(true)])),
      "SendManagerMessageInput": try encodedFieldNames(GraphQLSendManagerMessageRequest(
        workflowId: "workflow-a",
        workflowExecutionId: "session-a",
        message: "retry",
        actions: .object(["retryStepIds": .array([.string("step-a")])]),
        attachments: .array([.object(["path": .string("artifact.txt")])]),
        idempotencyKey: "idem-a",
        managerSessionId: "manager-session",
        managerNodeExecId: "manager-node-exec"
      )),
      "ReplayCommunicationInput": try encodedFieldNames(GraphQLReplayCommunicationRequest(
        workflowId: "workflow-a",
        workflowExecutionId: "session-a",
        communicationId: "comm-a",
        reason: "retry",
        idempotencyKey: "idem-b",
        managerSessionId: "manager-session"
      )),
      "RetryCommunicationDeliveryInput": try encodedFieldNames(GraphQLRetryCommunicationDeliveryRequest(
        workflowId: "workflow-a",
        workflowExecutionId: "session-a",
        communicationId: "comm-a",
        reason: "retry",
        idempotencyKey: "idem-c",
        managerSessionId: "manager-session"
      ))
    ]

    for (schemaType, encodedFields) in expectedFieldsBySchemaType {
      XCTAssertEqual(try schemaFieldNames(schemaType), encodedFields, "schema drift for \(schemaType)")
    }
  }

  func testWorkflowInstanceSchemaFieldSetsMatchEncodedDTOs() throws {
    let expectedFieldsBySchemaType: [String: Set<String>] = [
      "WorkflowInstance": try encodedFieldNames(GraphQLWorkflowInstanceDTO(instance: WorkflowInstanceDefinition(
        identity: "prod",
        workflowId: "workflow-a",
        sourceIdentity: "worker-only-single-step",
        displayName: "Production",
        configuration: WorkflowInstanceConfiguration(defaultVariables: ["request": .string("ok")])
      ))),
      "WorkflowInstanceInput": try encodedFieldNames(GraphQLWorkflowInstanceInput(
        identity: "prod",
        workflowId: "workflow-a",
        sourceIdentity: "worker-only-single-step",
        displayName: "Production",
        configuration: WorkflowInstanceConfiguration(defaultVariables: ["request": .string("ok")])
      )),
      "WorkflowInstanceQueryPayload": try encodedFieldNames(GraphQLWorkflowInstanceQueryResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "found"),
        value: GraphQLWorkflowInstanceDTO(instance: WorkflowInstanceDefinition(identity: "prod", workflowId: "workflow-a"))
      )),
      "WorkflowInstancesQueryPayload": try encodedFieldNames(GraphQLWorkflowInstanceQueryResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "found"),
        value: [GraphQLWorkflowInstanceDTO(instance: WorkflowInstanceDefinition(identity: "prod", workflowId: "workflow-a"))]
      )),
      "WorkflowInstanceMutationPayload": try encodedFieldNames(GraphQLWorkflowInstanceMutationResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "found"),
        instance: GraphQLWorkflowInstanceDTO(instance: WorkflowInstanceDefinition(identity: "prod", workflowId: "workflow-a"))
      ))
    ]

    for (schemaType, encodedFields) in expectedFieldsBySchemaType {
      XCTAssertEqual(try schemaFieldNames(schemaType), encodedFields, "schema drift for \(schemaType)")
    }
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

  func testLegacyGraphQLSessionRequestsExposeWorkflowExecutionIdAliasWithoutWireDrift() throws {
    var inspect = GraphQLInspectSessionRequest(workflowId: "workflow-a", sessionId: "session-a")
    var continuing = GraphQLContinueSessionRequest(
      workflowId: "workflow-a",
      sessionId: "session-a",
      input: ["ok": .bool(true)]
    )

    XCTAssertEqual(inspect.workflowExecutionId, "session-a")
    XCTAssertEqual(continuing.workflowExecutionId, "session-a")

    inspect.workflowExecutionId = "session-b"
    continuing.workflowExecutionId = "session-b"

    XCTAssertEqual(inspect.sessionId, "session-b")
    XCTAssertEqual(continuing.sessionId, "session-b")
    XCTAssertEqual(try encodedFieldNames(inspect), ["workflowId", "sessionId"])
    XCTAssertEqual(try encodedFieldNames(continuing), ["workflowId", "sessionId", "input"])
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

  private func encodedFieldNames<T: Encodable>(_ value: T) throws -> Set<String> {
    Set(try encodedObject(value).keys)
  }

  private func schemaFieldNames(_ typeName: String) throws -> Set<String> {
    let schema = GraphQLContractProjector.schemaContract
    let pattern = #"(?:type|input)\s+\#(typeName)\s*\{([^}]*)\}"#
    let expression = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    let range = NSRange(schema.startIndex..<schema.endIndex, in: schema)
    guard let match = expression.firstMatch(in: schema, range: range),
      let bodyRange = Range(match.range(at: 1), in: schema) else {
      XCTFail("missing schema type \(typeName)")
      return []
    }
    let body = String(schema[bodyRange])
    return try parseSchemaFieldNames(body)
  }

  private func parseSchemaFieldNames(_ body: String) throws -> Set<String> {
    let expression = try NSRegularExpression(
      pattern: #"\b([A-Za-z_][A-Za-z0-9_]*)\s*(?:\([^)]*\))?\s*:"#,
      options: []
    )
    let range = NSRange(body.startIndex..<body.endIndex, in: body)
    return Set(expression.matches(in: body, range: range).compactMap { match in
      guard let fieldRange = Range(match.range(at: 1), in: body) else {
        return nil
      }
      return String(body[fieldRange])
    })
  }

  private func workflowSession(
    workflowId: String,
    sessionId: String,
    status: WorkflowSessionStatus = .completed,
    date: Date,
    failureKind: WorkflowSessionFailureKind? = nil
  ) -> WorkflowSession {
    WorkflowSession(
      workflowId: workflowId,
      sessionId: sessionId,
      status: status,
      entryStepId: "step-1",
      currentStepId: nil,
      createdAt: date,
      updatedAt: date,
      failureKind: failureKind
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

private final class TestWorkflowInstanceStore: WorkflowInstanceStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var instances: [WorkflowInstanceDefinition] = []

  func list(workflowId: String?) throws -> [WorkflowInstanceDefinition] {
    lock.withLock {
      instances
        .filter { workflowId == nil || $0.workflowId == workflowId }
        .sorted { lhs, rhs in
          if lhs.workflowId == rhs.workflowId {
            return lhs.identity < rhs.identity
          }
          return lhs.workflowId < rhs.workflowId
        }
    }
  }

  func find(identity: String, workflowId: String?) throws -> WorkflowInstanceDefinition? {
    try list(workflowId: workflowId).first { $0.identity == identity }
  }

  func save(_ instance: WorkflowInstanceDefinition) throws {
    lock.withLock {
      if let index = instances.firstIndex(where: {
        $0.identity == instance.identity && $0.workflowId == instance.workflowId
      }) {
        instances[index] = instance
      } else {
        instances.append(instance)
      }
    }
  }

  func remove(identity: String, workflowId: String?) throws {
    try lock.withLock {
      let matches = instances.filter { $0.identity == identity && (workflowId == nil || $0.workflowId == workflowId) }
      guard matches.count == 1 else {
        throw WorkflowInstanceStoreError.notFound(identity)
      }
      instances.removeAll { $0.identity == matches[0].identity && $0.workflowId == matches[0].workflowId }
    }
  }
}
