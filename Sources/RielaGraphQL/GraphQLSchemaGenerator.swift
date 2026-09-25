import RielaCore

/// Declaration kinds the control-plane schema uses.
public enum GraphQLSchemaTypeKind: String, Sendable {
  case object = "type"
  case input
}

/// Renders the control-plane GraphQL schema from the typed contract
/// descriptors plus the `SurfaceCatalog` GraphQL bindings, so the SDL is not a
/// fourth place the contract is maintained by hand (design 2.3, delta D2).
///
/// `GraphQLContractProjector.schemaContract` is the checked-in output of
/// `render()`. `SurfaceParityGraphQLTests` asserts the two are byte-identical;
/// `scripts/surface-parity/generate-sdl.sh` rewrites the checked-in file.
public enum GraphQLSchemaGenerator {
  public struct FieldDescriptor: Sendable, Equatable {
    public var name: String
    public var arguments: String?
    public var type: String

    public init(name: String, arguments: String? = nil, type: String) {
      self.name = name
      self.arguments = arguments
      self.type = type
    }

    /// `name(args): Type`, the one rendering used everywhere in the SDL.
    public var declaration: String {
      arguments.map { "\(name)(\($0)): \(type)" } ?? "\(name): \(type)"
    }
  }

  public struct TypeDescriptor: Sendable, Equatable {
    public var kind: GraphQLSchemaTypeKind
    public var name: String
    public var fields: [FieldDescriptor]

    public init(kind: GraphQLSchemaTypeKind, name: String, fields: [FieldDescriptor]) {
      self.kind = kind
      self.name = name
      self.fields = fields
    }
  }

  public static let scalars: [String] = ["JSON", "JSONObject"]

  /// Object and input types of the control-plane contract. The DTO-sync test
  /// pins every `GraphQL*DTO` struct to its descriptor here, so a DTO field
  /// added without a schema field fails the build gate.
  public static let types: [TypeDescriptor] = [
    .init(kind: .input, name: "ExecuteWorkflowInput", fields: [
      .init(name: "workflowName", type: "String!"),
      .init(name: "runtimeVariables", type: "JSONObject"),
      .init(name: "instanceIdentity", type: "String"),
      .init(name: "nodePatch", type: "JSONObject"),
      .init(name: "maxSteps", type: "Int"),
      .init(name: "maxConcurrency", type: "Int"),
      .init(name: "maxLoopIterations", type: "Int"),
      .init(name: "disableDefaultLoopGuard", type: "Boolean"),
      .init(name: "defaultTimeoutMs", type: "Int")
    ]),
    .init(kind: .object, name: "ExecuteWorkflowPayload", fields: [
      .init(name: "workflowExecutionId", type: "String!"),
      .init(name: "sessionId", type: "String!"),
      .init(name: "status", type: "String!"),
      .init(name: "exitCode", type: "Int!")
    ]),
    .init(kind: .object, name: "WorkflowExecutionSummary", fields: [
      .init(name: "session", type: "WorkflowExecutionSessionSummary!"),
      .init(name: "nodeExecutions", type: "[WorkflowExecutionNodeSummary!]!")
    ]),
    .init(kind: .object, name: "WorkflowExecutionSessionSummary", fields: [
      .init(name: "sessionId", type: "String!"),
      .init(name: "workflowName", type: "String!"),
      .init(name: "workflowId", type: "String!"),
      .init(name: "transitions", type: "[WorkflowExecutionTransitionSummary!]!")
    ]),
    .init(kind: .object, name: "WorkflowExecutionTransitionSummary", fields: [
      .init(name: "when", type: "String")
    ]),
    .init(kind: .object, name: "WorkflowExecutionNodeSummary", fields: [
      .init(name: "nodeExecId", type: "String!")
    ]),
    .init(kind: .object, name: "ControlPlaneResult", fields: [
      .init(name: "accepted", type: "Boolean!"),
      .init(name: "status", type: "String!"),
      .init(name: "diagnostics", type: "[String!]!")
    ]),
    .init(kind: .object, name: "ManagerIntentSummary", fields: [
      .init(name: "kind", type: "String!"),
      .init(name: "targetId", type: "String"),
      .init(name: "reason", type: "String")
    ]),
    .init(kind: .object, name: "ManagerSessionView", fields: [
      .init(name: "session", type: "JSON!"),
      .init(name: "messages", type: "JSON!")
    ]),
    .init(kind: .object, name: "SendManagerMessagePayload", fields: [
      .init(name: "accepted", type: "Boolean!"),
      .init(name: "managerMessageId", type: "String!"),
      .init(name: "parsedIntent", type: "[ManagerIntentSummary!]!"),
      .init(name: "createdCommunicationIds", type: "[String!]!"),
      .init(name: "queuedNodeIds", type: "[String!]!"),
      .init(name: "rejectionReason", type: "String"),
      .init(name: "workflowId", type: "String!"),
      .init(name: "workflowExecutionId", type: "String!"),
      .init(name: "managerSessionId", type: "String!")
    ]),
    .init(kind: .object, name: "ReplayCommunicationPayload", fields: [
      .init(name: "sourceCommunicationId", type: "String!"),
      .init(name: "workflowExecutionId", type: "String!"),
      .init(name: "replayedCommunicationId", type: "String!"),
      .init(name: "status", type: "String!")
    ]),
    .init(kind: .object, name: "RetryCommunicationDeliveryPayload", fields: [
      .init(name: "communicationId", type: "String!"),
      .init(name: "activeDeliveryAttemptId", type: "String!"),
      .init(name: "status", type: "String!")
    ]),
    .init(kind: .object, name: "LoopEvidenceSummary", fields: [
      .init(name: "manifestId", type: "String!"),
      .init(name: "schemaVersion", type: "Int!"),
      .init(name: "workflowId", type: "String!"),
      .init(name: "sessionId", type: "String!"),
      .init(name: "gateCount", type: "Int!"),
      .init(name: "acceptedGateCount", type: "Int!"),
      .init(name: "rejectedGateCount", type: "Int!"),
      .init(name: "needsWorkGateCount", type: "Int!"),
      .init(name: "skippedGateCount", type: "Int!"),
      .init(name: "blockingFindingCount", type: "Int!"),
      .init(name: "stepCount", type: "Int!"),
      .init(name: "artifactCount", type: "Int!"),
      .init(name: "changedFileCount", type: "Int!"),
      .init(name: "commandCount", type: "Int!"),
      .init(name: "verificationCount", type: "Int!"),
      .init(name: "implementationPlanCount", type: "Int!"),
      .init(name: "residualRiskCount", type: "Int!"),
      .init(name: "redactionStatus", type: "String!"),
      .init(name: "updatedAt", type: "String!")
    ]),
    .init(kind: .object, name: "LoopFindingSeverityCounts", fields: [
      .init(name: "high", type: "Int!"),
      .init(name: "medium", type: "Int!"),
      .init(name: "low", type: "Int!"),
      .init(name: "informational", type: "Int!")
    ]),
    .init(kind: .object, name: "LoopBlockingFinding", fields: [
      .init(name: "id", type: "String!"),
      .init(name: "severity", type: "String!"),
      .init(name: "filePath", type: "String"),
      .init(name: "line", type: "Int"),
      .init(name: "message", type: "String!"),
      .init(name: "evidenceRefs", type: "[String!]!")
    ]),
    .init(kind: .object, name: "LoopResidualRisk", fields: [
      .init(name: "severity", type: "String!"),
      .init(name: "message", type: "String!"),
      .init(name: "evidenceRefs", type: "[String!]!"),
      .init(name: "owner", type: "String"),
      .init(name: "accepted", type: "Boolean!")
    ]),
    .init(kind: .object, name: "LoopGateResult", fields: [
      .init(name: "gateId", type: "String!"),
      .init(name: "stepId", type: "String!"),
      .init(name: "stepExecutionId", type: "String!"),
      .init(name: "decision", type: "String!"),
      .init(name: "severityCounts", type: "LoopFindingSeverityCounts!"),
      .init(name: "blockingFindings", type: "[LoopBlockingFinding!]!"),
      .init(name: "evidenceRefs", type: "[String!]!"),
      .init(name: "rerunPolicy", type: "String"),
      .init(name: "residualRisks", type: "[LoopResidualRisk!]!"),
      .init(name: "acceptedAt", type: "String"),
      .init(name: "diagnostics", type: "[String!]!")
    ]),
    .init(kind: .object, name: "LoopRecoveryLineage", fields: [
      .init(name: "entryMode", type: "String!"),
      .init(name: "sourceSessionId", type: "String"),
      .init(name: "sourceStepId", type: "String"),
      .init(name: "sourceStepExecutionId", type: "String"),
      .init(name: "parentSessionId", type: "String"),
      .init(name: "childSessionIds", type: "[String!]!"),
      .init(name: "reason", type: "String"),
      .init(name: "inputReusePolicy", type: "String!"),
      .init(name: "preservedFailureEvidenceRefs", type: "[String!]!")
    ]),
    .init(kind: .object, name: "WorkflowSession", fields: [
      .init(name: "workflowId", type: "String!"),
      .init(name: "sessionId", type: "String!"),
      .init(name: "parentSessionId", type: "String"),
      .init(name: "rootSessionId", type: "String"),
      .init(name: "workflowExecutionId", type: "String!"),
      .init(name: "status", type: "String!"),
      .init(name: "currentStepId", type: "String"),
      .init(name: "lastCompletedStepId", type: "String"),
      .init(name: "failureReason", type: "String"),
      .init(name: "failureKind", type: "String"),
      .init(name: "stepBudgetDiagnostic", type: "StepBudgetDiagnostic"),
      .init(name: "instanceIdentity", type: "String"),
      .init(name: "instanceKind", type: "String"),
      .init(name: "instanceBaseIdentity", type: "String"),
      .init(name: "instanceConfiguration", type: "JSONObject"),
      .init(name: "stepExecutions", type: "[StepExecution!]!"),
      .init(name: "communications", type: "[Communication!]!"),
      .init(name: "hookEvents", type: "[HookEvent!]!"),
      .init(name: "eventReceipts", type: "[EventReceipt!]!"),
      .init(name: "replyDispatches", type: "[ReplyDispatch!]!"),
      .init(name: "logs", type: "[LogEntry!]!"),
      .init(name: "llmSessionMessages", type: "[LLMSessionMessage!]!"),
      .init(name: "loopEvidence", type: "LoopEvidenceSummary"),
      .init(name: "loopGates", type: "[LoopGateResult!]!"),
      .init(name: "loopRecovery", type: "LoopRecoveryLineage")
    ]),
    .init(kind: .object, name: "StepBudgetDiagnostic", fields: [
      .init(name: "stepBudget", type: "Int!"),
      .init(name: "executionCount", type: "Int!"),
      .init(name: "maxLoopIterations", type: "Int!"),
      .init(name: "budgetSource", type: "String!"),
      .init(name: "perStepExecutionCounts", type: "JSON!"),
      .init(name: "dominantCycleStepIds", type: "[String!]"),
      .init(name: "dominantCycleRepeatCount", type: "Int"),
      .init(name: "perStepRevisitCap", type: "Int"),
      .init(name: "projectedCapExceededStepIds", type: "[String!]"),
      .init(name: "openReviewFindingCount", type: "Int!"),
      .init(name: "unscheduledStepId", type: "String"),
      .init(name: "suggestedMaxSteps", type: "Int"),
      .init(name: "suggestedRemediation", type: "String")
    ]),
    .init(kind: .object, name: "WorkflowSessionSummary", fields: [
      .init(name: "sessionId", type: "String!"),
      .init(name: "parentSessionId", type: "String"),
      .init(name: "rootSessionId", type: "String"),
      .init(name: "workflowName", type: "String!"),
      .init(name: "status", type: "String!"),
      .init(name: "failureKind", type: "String"),
      .init(name: "currentStepId", type: "String"),
      .init(name: "instanceIdentity", type: "String"),
      .init(name: "instanceKind", type: "String"),
      .init(name: "executionCount", type: "Int!"),
      .init(name: "updatedAt", type: "String!"),
      .init(name: "sessionStore", type: "String")
    ]),
    .init(kind: .object, name: "SessionProgressDigest", fields: [
      .init(name: "observedAt", type: "String!"),
      .init(name: "sessionId", type: "String!"),
      .init(name: "workflowId", type: "String!"),
      .init(name: "parentSessionId", type: "String"),
      .init(name: "rootSessionId", type: "String!"),
      .init(name: "status", type: "String!"),
      .init(name: "failureKind", type: "String"),
      .init(name: "previousStatus", type: "String"),
      .init(name: "currentStepId", type: "String"),
      .init(name: "currentStage", type: "String"),
      .init(name: "executionCount", type: "Int!"),
      .init(name: "effectiveStepBudget", type: "Int"),
      .init(name: "gateVisitCounts", type: "JSON!"),
      .init(name: "lastBackendEventType", type: "String"),
      .init(name: "lastBackendEventAt", type: "String"),
      .init(name: "lastBackendEventAgeMs", type: "Int"),
      .init(name: "activeBackend", type: "String")
    ]),
    .init(kind: .object, name: "SessionRollupNode", fields: [
      .init(name: "digest", type: "SessionProgressDigest!"),
      .init(name: "children", type: "[SessionRollupNode!]!")
    ]),
    .init(kind: .object, name: "SessionBackendActivityEvidence", fields: [
      .init(name: "kind", type: "String!"),
      .init(name: "detail", type: "String!"),
      .init(name: "path", type: "String"),
      .init(name: "observedAt", type: "String"),
      .init(name: "ageMs", type: "Int")
    ]),
    .init(kind: .object, name: "SessionBackendActivity", fields: [
      .init(name: "backend", type: "String"),
      .init(name: "verdict", type: "String!"),
      .init(name: "evidence", type: "[SessionBackendActivityEvidence!]!"),
      .init(name: "activeThresholdMs", type: "Int!"),
      .init(name: "stalledThresholdMs", type: "Int!"),
      .init(name: "lastActivityAt", type: "String"),
      .init(name: "ageMs", type: "Int"),
      .init(name: "observedAt", type: "String!")
    ]),
    .init(kind: .object, name: "SessionObservabilityView", fields: [
      .init(name: "root", type: "SessionRollupNode!"),
      .init(name: "backendActivity", type: "SessionBackendActivity"),
      .init(name: "rollupTruncated", type: "Boolean"),
      .init(name: "rollupSnapshotLimit", type: "Int")
    ]),
    .init(kind: .object, name: "SessionObservabilityPayload", fields: [
      .init(name: "result", type: "ControlPlaneResult!"),
      .init(name: "view", type: "SessionObservabilityView")
    ]),
    .init(kind: .object, name: "WorkflowInstance", fields: [
      .init(name: "identity", type: "String!"),
      .init(name: "workflowId", type: "String!"),
      .init(name: "sourceIdentity", type: "String"),
      .init(name: "displayName", type: "String"),
      .init(name: "configuration", type: "JSONObject!")
    ]),
    .init(kind: .object, name: "WorkflowInstanceQueryPayload", fields: [
      .init(name: "result", type: "ControlPlaneResult!"),
      .init(name: "value", type: "WorkflowInstance")
    ]),
    .init(kind: .object, name: "WorkflowInstancesQueryPayload", fields: [
      .init(name: "result", type: "ControlPlaneResult!"),
      .init(name: "value", type: "[WorkflowInstance!]")
    ]),
    .init(kind: .object, name: "WorkflowInstanceMutationPayload", fields: [
      .init(name: "result", type: "ControlPlaneResult!"),
      .init(name: "instance", type: "WorkflowInstance")
    ]),
    .init(kind: .object, name: "StepExecution", fields: [
      .init(name: "executionId", type: "String!"),
      .init(name: "stepId", type: "String!"),
      .init(name: "nodeId", type: "String!"),
      .init(name: "attempt", type: "Int!"),
      .init(name: "backend", type: "String"),
      .init(name: "status", type: "String!"),
      .init(name: "failureReason", type: "String")
    ]),
    .init(kind: .object, name: "Communication", fields: [
      .init(name: "communicationId", type: "String!"),
      .init(name: "fromStepId", type: "String"),
      .init(name: "toStepId", type: "String"),
      .init(name: "lifecycleStatus", type: "String!"),
      .init(name: "deliveryKind", type: "String!"),
      .init(name: "createdOrder", type: "Int!")
    ]),
    .init(kind: .object, name: "HookEvent", fields: [
      .init(name: "vendor", type: "String!"),
      .init(name: "eventName", type: "String!"),
      .init(name: "agentSessionId", type: "String!"),
      .init(name: "payloadHash", type: "String")
    ]),
    .init(kind: .object, name: "EventReceipt", fields: [
      .init(name: "sourceId", type: "String!"),
      .init(name: "eventId", type: "String!"),
      .init(name: "status", type: "String!")
    ]),
    .init(kind: .object, name: "ReplyDispatch", fields: [
      .init(name: "sourceId", type: "String!"),
      .init(name: "provider", type: "String!"),
      .init(name: "payload", type: "JSONObject!")
    ]),
    .init(kind: .object, name: "LogEntry", fields: [
      .init(name: "level", type: "String!"),
      .init(name: "message", type: "String!")
    ]),
    .init(kind: .object, name: "LLMSessionMessage", fields: [
      .init(name: "role", type: "String!"),
      .init(name: "content", type: "String!")
    ]),
    .init(kind: .input, name: "ContinueSessionInput", fields: [
      .init(name: "workflowId", type: "String!"),
      .init(name: "sessionId", type: "String!"),
      .init(name: "input", type: "JSONObject!")
    ]),
    .init(kind: .input, name: "SendManagerMessageInput", fields: [
      .init(name: "workflowId", type: "String!"),
      .init(name: "workflowExecutionId", type: "String!"),
      .init(name: "message", type: "String"),
      .init(name: "actions", type: "JSON"),
      .init(name: "attachments", type: "JSON"),
      .init(name: "idempotencyKey", type: "String"),
      .init(name: "managerSessionId", type: "String"),
      .init(name: "managerNodeExecId", type: "String")
    ]),
    .init(kind: .input, name: "ReplayCommunicationInput", fields: [
      .init(name: "workflowId", type: "String!"),
      .init(name: "workflowExecutionId", type: "String!"),
      .init(name: "communicationId", type: "String!"),
      .init(name: "reason", type: "String"),
      .init(name: "idempotencyKey", type: "String"),
      .init(name: "managerSessionId", type: "String")
    ]),
    .init(kind: .input, name: "RetryCommunicationDeliveryInput", fields: [
      .init(name: "workflowId", type: "String!"),
      .init(name: "workflowExecutionId", type: "String!"),
      .init(name: "communicationId", type: "String!"),
      .init(name: "reason", type: "String"),
      .init(name: "idempotencyKey", type: "String"),
      .init(name: "managerSessionId", type: "String")
    ]),
    .init(kind: .input, name: "WorkflowInstanceInput", fields: [
      .init(name: "identity", type: "String!"),
      .init(name: "workflowId", type: "String!"),
      .init(name: "sourceIdentity", type: "String"),
      .init(name: "displayName", type: "String"),
      .init(name: "configuration", type: "JSONObject")
    ]),
    .init(kind: .object, name: "LoopCostSummary", fields: [
      .init(name: "totalInputTokens", type: "Int"),
      .init(name: "totalOutputTokens", type: "Int"),
      .init(name: "totalTokens", type: "Int"),
      .init(name: "totalDurationMs", type: "Int"),
      .init(name: "stepsWithUsage", type: "Int!"),
      .init(name: "stepsWithoutUsage", type: "Int!"),
      .init(name: "partial", type: "Boolean!")
    ]),
    .init(kind: .object, name: "LoopCostSummaryDelta", fields: [
      .init(name: "totalInputTokensDelta", type: "Int"),
      .init(name: "totalOutputTokensDelta", type: "Int"),
      .init(name: "totalTokensDelta", type: "Int"),
      .init(name: "totalDurationMsDelta", type: "Int")
    ]),
    .init(kind: .object, name: "LoopGateOutcome", fields: [
      .init(name: "gateId", type: "String!"),
      .init(name: "stepId", type: "String!"),
      .init(name: "decision", type: "String!"),
      .init(name: "required", type: "Boolean"),
      .init(name: "blockingFindingCount", type: "Int!")
    ]),
    .init(kind: .object, name: "LoopGateFailureCount", fields: [
      .init(name: "gateId", type: "String!"),
      .init(name: "count", type: "Int!")
    ]),
    .init(kind: .object, name: "LoopGateChange", fields: [
      .init(name: "gateId", type: "String!"),
      .init(name: "baseDecision", type: "String"),
      .init(name: "targetDecision", type: "String"),
      .init(name: "severityCountsDelta", type: "LoopFindingSeverityCounts!")
    ]),
    .init(kind: .object, name: "LoopVerificationChange", fields: [
      .init(name: "commandSummary", type: "String!"),
      .init(name: "baseOutcome", type: "String"),
      .init(name: "targetOutcome", type: "String")
    ]),
    .init(kind: .object, name: "LoopSessionOverview", fields: [
      .init(name: "workflowId", type: "String!"),
      .init(name: "sessionId", type: "String!"),
      .init(name: "sessionStatus", type: "String!"),
      .init(name: "loopKind", type: "String"),
      .init(name: "loopRequired", type: "Boolean"),
      .init(name: "loopEvidenceRecorded", type: "Boolean!"),
      .init(name: "blockingFindingCount", type: "Int"),
      .init(name: "lastGateDecision", type: "String"),
      .init(name: "entryMode", type: "String"),
      .init(name: "sourceSessionId", type: "String"),
      .init(name: "cost", type: "LoopCostSummary"),
      .init(name: "gateOutcomes", type: "[LoopGateOutcome!]!"),
      .init(name: "possiblyStale", type: "Boolean!"),
      .init(name: "createdAt", type: "String!"),
      .init(name: "updatedAt", type: "String!")
    ]),
    .init(kind: .object, name: "LoopWorkflowStats", fields: [
      .init(name: "workflowId", type: "String!"),
      .init(name: "windowRuns", type: "Int!"),
      .init(name: "completedRuns", type: "Int!"),
      .init(name: "failedRuns", type: "Int!"),
      .init(name: "acceptedRuns", type: "Int!"),
      .init(name: "gateFailureCounts", type: "[LoopGateFailureCount!]!"),
      .init(name: "rerunCount", type: "Int!"),
      .init(name: "meanDurationMs", type: "Int"),
      .init(name: "meanTotalTokens", type: "Int"),
      .init(name: "lastAcceptedSessionId", type: "String"),
      .init(name: "diagnostics", type: "[String!]!")
    ]),
    .init(kind: .object, name: "LoopEvidenceDiff", fields: [
      .init(name: "baseSessionId", type: "String!"),
      .init(name: "targetSessionId", type: "String!"),
      .init(name: "sameWorkflow", type: "Boolean!"),
      .init(name: "workflowDefinitionDigestChanged", type: "Boolean"),
      .init(name: "gateChanges", type: "[LoopGateChange!]!"),
      .init(name: "blockingFindingsAdded", type: "[LoopBlockingFinding!]!"),
      .init(name: "blockingFindingsResolved", type: "[LoopBlockingFinding!]!"),
      .init(name: "changedFilesAdded", type: "[String!]!"),
      .init(name: "changedFilesRemoved", type: "[String!]!"),
      .init(name: "verificationChanges", type: "[LoopVerificationChange!]!"),
      .init(name: "residualRisksAdded", type: "[LoopResidualRisk!]!"),
      .init(name: "residualRisksResolved", type: "[LoopResidualRisk!]!"),
      .init(name: "costDelta", type: "LoopCostSummaryDelta"),
      .init(name: "diagnostics", type: "[String!]!")
    ]),
    .init(kind: .input, name: "RerunSessionInput", fields: [
      .init(name: "workflowId", type: "String!"),
      .init(name: "sessionId", type: "String!"),
      .init(name: "stepId", type: "String!"),
      .init(name: "managerSessionId", type: "String")
    ]),
    .init(kind: .input, name: "ResumeSessionInput", fields: [
      .init(name: "workflowId", type: "String!"),
      .init(name: "sessionId", type: "String!"),
      .init(name: "managerSessionId", type: "String")
    ]),
    .init(kind: .input, name: "StopSessionInput", fields: [
      .init(name: "workflowId", type: "String!"),
      .init(name: "sessionId", type: "String!"),
      .init(name: "reason", type: "String"),
      .init(name: "managerSessionId", type: "String")
    ]),
    .init(kind: .object, name: "SessionLineage", fields: [
      .init(name: "sessionId", type: "String!"),
      .init(name: "parentSessionId", type: "String"),
      .init(name: "rootSessionId", type: "String!"),
      .init(name: "entryMode", type: "String!"),
      .init(name: "sourceStepId", type: "String")
    ]),
    .init(kind: .object, name: "SessionMutationPayload", fields: [
      .init(name: "result", type: "ControlPlaneResult!"),
      .init(name: "sessionId", type: "String"),
      .init(name: "status", type: "String"),
      .init(name: "lineage", type: "SessionLineage")
    ]),
    .init(kind: .object, name: "ConsoleInstanceEnvironmentVariable", fields: [
      .init(name: "name", type: "String!"),
      .init(name: "isSet", type: "Boolean!"),
      .init(name: "masked", type: "String!")
    ]),
    .init(kind: .object, name: "ConsoleInstanceRequiredEnvironment", fields: [
      .init(name: "name", type: "String!"),
      .init(name: "description", type: "String"),
      .init(name: "required", type: "Boolean!"),
      .init(name: "secret", type: "Boolean!"),
      .init(name: "source", type: "String!"),
      .init(name: "present", type: "Boolean!")
    ]),
    .init(kind: .object, name: "ConsoleInstanceEventSource", fields: [
      .init(name: "id", type: "String!"),
      .init(name: "kind", type: "String!")
    ]),
    .init(kind: .object, name: "ConsoleInstance", fields: [
      .init(name: "id", type: "String!"),
      .init(name: "sourceId", type: "String!"),
      .init(name: "isDefault", type: "Boolean!"),
      .init(name: "name", type: "String!"),
      .init(name: "workflowId", type: "String!"),
      .init(name: "source", type: "String!"),
      .init(name: "sourceKind", type: "String!"),
      .init(name: "status", type: "String!"),
      .init(name: "statusDetail", type: "String!"),
      .init(name: "active", type: "Boolean!"),
      .init(name: "enabledAtLaunch", type: "Boolean!"),
      .init(name: "workingDirectory", type: "String"),
      .init(name: "environmentFilePath", type: "String"),
      .init(name: "environmentVariables", type: "[ConsoleInstanceEnvironmentVariable!]!"),
      .init(name: "requiredEnvironment", type: "[ConsoleInstanceRequiredEnvironment!]!"),
      .init(name: "workflowVariables", type: "JSONObject!"),
      .init(name: "nodePatchCount", type: "Int!"),
      .init(name: "nodePatches", type: "JSONObject!"),
      .init(name: "eventSources", type: "[ConsoleInstanceEventSource!]!")
    ]),
    .init(kind: .object, name: "ConsoleInstanceListPayload", fields: [
      .init(name: "profile", type: "String!"),
      .init(name: "revision", type: "Int!"),
      .init(name: "items", type: "[ConsoleInstance!]!")
    ]),
    .init(kind: .object, name: "ConsoleInstancePayload", fields: [
      .init(name: "profile", type: "String!"),
      .init(name: "revision", type: "Int!"),
      .init(name: "item", type: "ConsoleInstance")
    ]),
    .init(kind: .object, name: "OpsOverviewTransition", fields: [
      .init(name: "toStepId", type: "String!"),
      .init(name: "label", type: "String"),
      .init(name: "fanoutJoinStepId", type: "String")
    ]),
    .init(kind: .object, name: "OpsOverviewStep", fields: [
      .init(name: "id", type: "String!"),
      .init(name: "nodeId", type: "String!"),
      .init(name: "role", type: "String"),
      .init(name: "description", type: "String"),
      .init(name: "transitions", type: "[OpsOverviewTransition!]!")
    ]),
    .init(kind: .object, name: "OpsOverviewNode", fields: [
      .init(name: "id", type: "String!"),
      .init(name: "kind", type: "String"),
      .init(name: "role", type: "String"),
      .init(name: "addon", type: "String")
    ]),
    .init(kind: .object, name: "OpsOverviewWorkflow", fields: [
      .init(name: "sourceId", type: "String!"),
      .init(name: "name", type: "String!"),
      .init(name: "workflowId", type: "String!"),
      .init(name: "scope", type: "String!"),
      .init(name: "sourceKind", type: "String!"),
      .init(name: "description", type: "String!"),
      .init(name: "entryStepId", type: "String!"),
      .init(name: "managerStepId", type: "String"),
      .init(name: "steps", type: "[OpsOverviewStep!]!"),
      .init(name: "nodes", type: "[OpsOverviewNode!]!"),
      .init(name: "stepsTruncated", type: "Boolean!")
    ]),
    .init(kind: .object, name: "OpsOverviewInstance", fields: [
      .init(name: "id", type: "String!"),
      .init(name: "sourceId", type: "String!"),
      .init(name: "isDefault", type: "Boolean!"),
      .init(name: "name", type: "String!"),
      .init(name: "workflowId", type: "String!"),
      .init(name: "status", type: "String!"),
      .init(name: "active", type: "Boolean!")
    ]),
    .init(kind: .object, name: "OpsOverviewRun", fields: [
      .init(name: "instanceId", type: "String!"),
      .init(name: "sessionId", type: "String!"),
      .init(name: "workflowId", type: "String!"),
      .init(name: "status", type: "String!"),
      .init(name: "currentStepId", type: "String"),
      .init(name: "activeStepIds", type: "[String!]!"),
      .init(name: "updatedAt", type: "String!")
    ]),
    .init(kind: .object, name: "OpsOverviewPayload", fields: [
      .init(name: "profile", type: "String!"),
      .init(name: "revision", type: "Int!"),
      .init(name: "workflows", type: "[OpsOverviewWorkflow!]!"),
      .init(name: "workflowsTruncated", type: "Boolean!"),
      .init(name: "instances", type: "[OpsOverviewInstance!]!"),
      .init(name: "runs", type: "[OpsOverviewRun!]!"),
      .init(name: "runsTruncated", type: "Boolean!"),
      .init(name: "diagnostics", type: "[String!]!")
    ])
  ]

  /// Root field signatures keyed by `SurfaceGraphQLBinding.qualifiedField`.
  /// The catalog decides which fields the schema publishes and in what order;
  /// this table supplies each one's arguments and return type.
  public static let rootFields: [String: FieldDescriptor] = [
    "Mutation.executeWorkflow": .init(name: "executeWorkflow", arguments: "input: ExecuteWorkflowInput!", type: "ExecuteWorkflowPayload!"),
    "Query.workflowExecution": .init(name: "workflowExecution", arguments: "workflowExecutionId: String!", type: "WorkflowExecutionSummary"),
    "Mutation.activateWorkflow": .init(name: "activateWorkflow", arguments: "input: SetWorkflowActivationInput!", type: "WorkflowMutationPayload!"),
    "Mutation.addWorkflowDirectoryConfiguration": .init(name: "addWorkflowDirectoryConfiguration", arguments: "input: WorkflowDirectoryConfigurationInput!", type: "ConfigurationRevision!"),
    "Mutation.completeRoutine": .init(name: "completeRoutine", arguments: "input: CompleteRoutineInput!", type: "RoutineMutationPayload!"),
    "Mutation.consolidateWorkflows": .init(name: "consolidateWorkflows", arguments: "input: ConsolidateWorkflowsInput!", type: "WorkflowMutationPayload!"),
    "Mutation.continueSession": .init(name: "continueSession", arguments: "input: ContinueSessionInput!", type: "ControlPlaneResult!"),
    "Mutation.createProfileConfiguration": .init(name: "createProfileConfiguration", arguments: "input: ProfileConfigurationInput!", type: "RielaConfiguration!"),
    "Mutation.createRoutine": .init(name: "createRoutine", arguments: "input: CreateRoutineInput!", type: "RoutineMutationPayload!"),
    "Mutation.createWorkflowInstance": .init(name: "createWorkflowInstance", arguments: "input: WorkflowInstanceInput!", type: "WorkflowInstanceMutationPayload!"),
    "Mutation.deactivateWorkflow": .init(name: "deactivateWorkflow", arguments: "input: SetWorkflowActivationInput!", type: "WorkflowMutationPayload!"),
    "Mutation.deleteMutableWorkflow": .init(name: "deleteMutableWorkflow", arguments: "input: DeleteMutableWorkflowInput!", type: "WorkflowMutationPayload!"),
    "Mutation.deleteRoutine": .init(name: "deleteRoutine", arguments: "input: DeleteRoutineInput!", type: "RoutineMutationPayload!"),
    "Mutation.deleteWorkflowInstance": .init(name: "deleteWorkflowInstance", arguments: "identity: String!, workflowId: String", type: "WorkflowInstanceMutationPayload!"),
    "Mutation.registerEventSourceConfiguration": .init(name: "registerEventSourceConfiguration", arguments: "input: EventSourceConfigurationInput!", type: "ConfigurationRevision!"),
    "Mutation.registerMutableWorkflow": .init(name: "registerMutableWorkflow", arguments: "input: RegisterMutableWorkflowInput!", type: "WorkflowMutationPayload!"),
    "Mutation.removeProfileConfiguration": .init(name: "removeProfileConfiguration", arguments: "input: ProfileConfigurationInput!", type: "RielaConfiguration!"),
    "Mutation.replayCommunication": .init(name: "replayCommunication", arguments: "input: ReplayCommunicationInput!", type: "ReplayCommunicationPayload!"),
    "Mutation.rerunSession": .init(name: "rerunSession", arguments: "input: RerunSessionInput!", type: "SessionMutationPayload!"),
    "Mutation.resumeSession": .init(name: "resumeSession", arguments: "input: ResumeSessionInput!", type: "SessionMutationPayload!"),
    "Mutation.retryCommunicationDelivery": .init(name: "retryCommunicationDelivery", arguments: "input: RetryCommunicationDeliveryInput!", type: "RetryCommunicationDeliveryPayload!"),
    "Mutation.sendManagerMessage": .init(name: "sendManagerMessage", arguments: "input: SendManagerMessageInput!", type: "SendManagerMessagePayload!"),
    "Mutation.setRoutineStatus": .init(name: "setRoutineStatus", arguments: "input: SetRoutineStatusInput!", type: "RoutineMutationPayload!"),
    "Mutation.stopSession": .init(name: "stopSession", arguments: "input: StopSessionInput!", type: "SessionMutationPayload!"),
    "Mutation.switchProfileConfiguration": .init(name: "switchProfileConfiguration", arguments: "input: ProfileConfigurationInput!", type: "RielaConfiguration!"),
    "Mutation.updateAppearanceConfiguration": .init(name: "updateAppearanceConfiguration", arguments: "input: UpdateAppearanceConfigurationInput!", type: "RielaConfiguration!"),
    "Mutation.updateAssistantConfiguration": .init(name: "updateAssistantConfiguration", arguments: "input: UpdateAssistantConfigurationInput!", type: "RielaConfiguration!"),
    "Mutation.updateHTTPServerConfiguration": .init(name: "updateHTTPServerConfiguration", arguments: "input: UpdateHTTPServerConfigurationInput!", type: "RielaConfiguration!"),
    "Mutation.updateMutableWorkflow": .init(name: "updateMutableWorkflow", arguments: "input: UpdateMutableWorkflowInput!", type: "WorkflowMutationPayload!"),
    "Mutation.updateWorkflowInstance": .init(name: "updateWorkflowInstance", arguments: "input: WorkflowInstanceInput!", type: "WorkflowInstanceMutationPayload!"),
    "Mutation.updateWorkflowInstanceConfiguration": .init(name: "updateWorkflowInstanceConfiguration", arguments: "input: WorkflowInstanceConfigurationInput!", type: "ConfigurationRevision!"),
    "Query.configuration": .init(name: "configuration", type: "RielaConfiguration!"),
    "Query.consoleInstance": .init(name: "consoleInstance", arguments: "identity: String!", type: "ConsoleInstancePayload!"),
    "Query.consoleInstances": .init(name: "consoleInstances", type: "ConsoleInstanceListPayload!"),
    "Query.loopEvidence": .init(name: "loopEvidence", arguments: "workflowId: String!, sessionId: String!", type: "LoopEvidenceSummary"),
    "Query.loopEvidenceDiff": .init(name: "loopEvidenceDiff", arguments: "baseSessionId: String!, targetSessionId: String!", type: "LoopEvidenceDiff"),
    "Query.loopSessions": .init(name: "loopSessions", arguments: "workflowId: String, status: String, limit: Int", type: "[LoopSessionOverview!]!"),
    "Query.loopWorkflowStats": .init(name: "loopWorkflowStats", arguments: "workflowId: String!, limit: Int", type: "LoopWorkflowStats"),
    "Query.managerSession": .init(name: "managerSession", arguments: "managerSessionId: String", type: "ManagerSessionView"),
    "Query.opsOverview": .init(name: "opsOverview", type: "OpsOverviewPayload!"),
    "Query.routine": .init(name: "routine", arguments: "routineId: String!, routineStoreRoot: String", type: "RoutineQueryPayload!"),
    "Query.routines": .init(name: "routines", arguments: "filter: RoutineFilter", type: "RoutineListPayload!"),
    "Query.sessionHealth": .init(name: "sessionHealth", arguments: "sessionId: String!", type: "SessionObservabilityPayload!"),
    "Query.sessionProgress": .init(name: "sessionProgress", arguments: "sessionId: String!, includeChildren: Boolean = false", type: "SessionObservabilityPayload!"),
    "Query.workflow": .init(name: "workflow", arguments: "target: WorkflowTargetInput!", type: "WorkflowQueryPayload!"),
    "Query.workflowInstance": .init(name: "workflowInstance", arguments: "identity: String!, workflowId: String", type: "WorkflowInstanceQueryPayload!"),
    "Query.workflowInstances": .init(name: "workflowInstances", arguments: "workflowId: String", type: "WorkflowInstancesQueryPayload!"),
    "Query.workflowSession": .init(name: "workflowSession", arguments: "workflowId: String!, sessionId: String!", type: "WorkflowSession"),
    "Query.workflowSessions": .init(name: "workflowSessions", arguments: "workflowName: String, status: String, limit: Int", type: "[WorkflowSessionSummary!]!"),
    "Query.workflows": .init(name: "workflows", arguments: "filter: WorkflowFilter", type: "WorkflowListPayload!")
  ]

  /// SDL blocks that stay hand-written (delta D2). They are interpolated by
  /// both the generator and the checked-in literal, so both see one source.
  static var handWrittenSchemaBlocks: [String] {
    [workflowRegistryGraphQLSchemaTypes, configurationGraphQLSchemaTypes, routineGraphQLSchemaTypes]
  }

  static let handWrittenSchemaBlockNames: [String] = [
    "workflowRegistryGraphQLSchemaTypes",
    "configurationGraphQLSchemaTypes",
    "routineGraphQLSchemaTypes"
  ]

  /// Catalog-ordered root fields for one root.
  public static func catalogFields(root: SurfaceGraphQLRoot) -> [FieldDescriptor] {
    SurfaceCatalog.all
      .compactMap(\.graphql)
      .filter { $0.root == root }
      .compactMap { rootFields[$0.qualifiedField] }
  }

  public static func render() -> String {
    renderTemplate(handWrittenBlocks: handWrittenSchemaBlocks)
  }

  /// The schema text with the hand-written blocks supplied by the caller, so
  /// the regeneration entry point can substitute Swift interpolation markers.
  static func renderTemplate(handWrittenBlocks: [String]) -> String {
    var out: [String] = scalars.map { "scalar \($0)" }
    for type in types {
      out.append("\(type.kind.rawValue) \(type.name) {")
      out.append(contentsOf: type.fields.map { "  \($0.declaration)" })
      out.append("}")
    }
    out.append(contentsOf: handWrittenBlocks)
    for root in SurfaceGraphQLRoot.allCases {
      out.append("type \(root.rawValue) {")
      out.append(contentsOf: catalogFields(root: root).map { "  \($0.declaration)" })
      out.append("}")
    }
    return out.joined(separator: "\n")
  }

  /// Both directions of the catalog/schema contract for root fields.
  public static func rootFieldCoverageViolations() -> [SurfaceParityViolation] {
    SurfaceCatalog.bijectionViolations(
      surface: .graphql,
      actual: Set(rootFields.keys),
      declared: Set(SurfaceCatalog.all.compactMap { $0.graphql?.qualifiedField })
    )
  }

  /// The complete text of the checked-in `GraphQLContractProjector+Schema.swift`.
  /// The hand-written blocks are emitted as Swift interpolations so the checked-in
  /// literal and `render()` keep reading one source for them.
  static func swiftSourceTemplate() -> String {
    let body = renderTemplate(handWrittenBlocks: handWrittenSchemaBlockNames.map { "\\(\($0))" })
    let indented = body
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { "  " + $0 }
      .joined(separator: "\n")
    return """
    // GENERATED FILE - do not edit by hand.
    //
    // Rendered by `GraphQLSchemaGenerator.render()` from the control-plane
    // contract descriptors in `GraphQLSchemaGenerator.swift` plus the GraphQL
    // bindings in `SurfaceCatalog`. Regenerate with
    // `scripts/surface-parity/generate-sdl.sh`; `SurfaceParityGraphQLTests`
    // fails if this file and the generator disagree by a single byte.
    extension GraphQLContractProjector {
      public static let schemaContract = \"\"\"
    \(indented)
      \"\"\"
    }

    """
  }
}
