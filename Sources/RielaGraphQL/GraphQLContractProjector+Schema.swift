extension GraphQLContractProjector {
  public static let schemaContract = """
  scalar JSON
  scalar JSONObject
  type ControlPlaneResult { accepted: Boolean!, status: String!, diagnostics: [String!]! }
  type ManagerIntentSummary { kind: String!, targetId: String, reason: String }
  type ManagerSessionView { session: JSON!, messages: JSON! }
  type SendManagerMessagePayload {
    accepted: Boolean!
    managerMessageId: String!
    parsedIntent: [ManagerIntentSummary!]!
    createdCommunicationIds: [String!]!
    queuedNodeIds: [String!]!
    rejectionReason: String
    workflowId: String!
    workflowExecutionId: String!
    managerSessionId: String!
  }
  type ReplayCommunicationPayload { sourceCommunicationId: String!, workflowExecutionId: String!, replayedCommunicationId: String!, status: String! }
  type RetryCommunicationDeliveryPayload { communicationId: String!, activeDeliveryAttemptId: String!, status: String! }
  type LoopEvidenceSummary {
    manifestId: String!
    schemaVersion: Int!
    workflowId: String!
    sessionId: String!
    gateCount: Int!
    acceptedGateCount: Int!
    rejectedGateCount: Int!
    needsWorkGateCount: Int!
    skippedGateCount: Int!
    blockingFindingCount: Int!
    stepCount: Int!
    artifactCount: Int!
    changedFileCount: Int!
    commandCount: Int!
    verificationCount: Int!
    implementationPlanCount: Int!
    residualRiskCount: Int!
    redactionStatus: String!
    updatedAt: String!
  }
  type LoopFindingSeverityCounts { high: Int!, medium: Int!, low: Int!, informational: Int! }
  type LoopBlockingFinding {
    id: String!
    severity: String!
    filePath: String
    line: Int
    message: String!
    evidenceRefs: [String!]!
  }
  type LoopResidualRisk {
    severity: String!
    message: String!
    evidenceRefs: [String!]!
    owner: String
    accepted: Boolean!
  }
  type LoopGateResult {
    gateId: String!
    stepId: String!
    stepExecutionId: String!
    decision: String!
    severityCounts: LoopFindingSeverityCounts!
    blockingFindings: [LoopBlockingFinding!]!
    evidenceRefs: [String!]!
    rerunPolicy: String
    residualRisks: [LoopResidualRisk!]!
    acceptedAt: String
    diagnostics: [String!]!
  }
  type LoopRecoveryLineage {
    entryMode: String!
    sourceSessionId: String
    sourceStepId: String
    sourceStepExecutionId: String
    parentSessionId: String
    childSessionIds: [String!]!
    reason: String
    inputReusePolicy: String!
    preservedFailureEvidenceRefs: [String!]!
  }
  type WorkflowSession {
    workflowId: String!
    sessionId: String!
    parentSessionId: String
    rootSessionId: String
    workflowExecutionId: String!
    status: String!
    currentStepId: String
    lastCompletedStepId: String
    failureReason: String
    failureKind: String
    stepBudgetDiagnostic: StepBudgetDiagnostic
    instanceIdentity: String
    instanceKind: String
    instanceBaseIdentity: String
    instanceConfiguration: JSONObject
    stepExecutions: [StepExecution!]!
    communications: [Communication!]!
    hookEvents: [HookEvent!]!
    eventReceipts: [EventReceipt!]!
    replyDispatches: [ReplyDispatch!]!
    logs: [LogEntry!]!
    llmSessionMessages: [LLMSessionMessage!]!
    loopEvidence: LoopEvidenceSummary
    loopGates: [LoopGateResult!]!
    loopRecovery: LoopRecoveryLineage
  }
  type StepBudgetDiagnostic {
    stepBudget: Int!
    executionCount: Int!
    maxLoopIterations: Int!
    budgetSource: String!
    perStepExecutionCounts: JSON!
    dominantCycleStepIds: [String!]
    dominantCycleRepeatCount: Int
    perStepRevisitCap: Int
    projectedCapExceededStepIds: [String!]
    openReviewFindingCount: Int!
    unscheduledStepId: String
    suggestedMaxSteps: Int
    suggestedRemediation: String
  }
  type WorkflowSessionSummary {
    sessionId: String!
    parentSessionId: String
    rootSessionId: String
    workflowName: String!
    status: String!
    failureKind: String
    currentStepId: String
    instanceIdentity: String
    instanceKind: String
    executionCount: Int!
    updatedAt: String!
    sessionStore: String
  }
  type SessionProgressDigest {
    observedAt: String!
    sessionId: String!
    workflowId: String!
    parentSessionId: String
    rootSessionId: String!
    status: String!
    failureKind: String
    previousStatus: String
    currentStepId: String
    currentStage: String
    executionCount: Int!
    effectiveStepBudget: Int
    gateVisitCounts: JSON!
    lastBackendEventType: String
    lastBackendEventAt: String
    lastBackendEventAgeMs: Int
    activeBackend: String
  }
  type SessionRollupNode {
    digest: SessionProgressDigest!
    children: [SessionRollupNode!]!
  }
  type SessionBackendActivityEvidence {
    kind: String!
    detail: String!
    path: String
    observedAt: String
    ageMs: Int
  }
  type SessionBackendActivity {
    backend: String
    verdict: String!
    evidence: [SessionBackendActivityEvidence!]!
    activeThresholdMs: Int!
    stalledThresholdMs: Int!
    lastActivityAt: String
    ageMs: Int
    observedAt: String!
  }
  type SessionObservabilityView {
    root: SessionRollupNode!
    backendActivity: SessionBackendActivity
    rollupTruncated: Boolean
    rollupSnapshotLimit: Int
  }
  type SessionObservabilityPayload {
    result: ControlPlaneResult!
    view: SessionObservabilityView
  }
  type WorkflowInstance {
    identity: String!
    workflowId: String!
    sourceIdentity: String
    displayName: String
    configuration: JSONObject!
  }
  type WorkflowInstanceQueryPayload {
    result: ControlPlaneResult!
    value: WorkflowInstance
  }
  type WorkflowInstancesQueryPayload {
    result: ControlPlaneResult!
    value: [WorkflowInstance!]
  }
  type WorkflowInstanceMutationPayload {
    result: ControlPlaneResult!
    instance: WorkflowInstance
  }
  type StepExecution { executionId: String!, stepId: String!, nodeId: String!, attempt: Int!, backend: String, status: String!, failureReason: String }
  type Communication { communicationId: String!, fromStepId: String, toStepId: String, lifecycleStatus: String!, deliveryKind: String!, createdOrder: Int! }
  type HookEvent { vendor: String!, eventName: String!, agentSessionId: String!, payloadHash: String }
  type EventReceipt { sourceId: String!, eventId: String!, status: String! }
  type ReplyDispatch { sourceId: String!, provider: String!, payload: JSONObject! }
  type LogEntry { level: String!, message: String! }
  type LLMSessionMessage { role: String!, content: String! }
  input ContinueSessionInput { workflowId: String!, sessionId: String!, input: JSONObject! }
  input SendManagerMessageInput { workflowId: String!, workflowExecutionId: String!, message: String, actions: JSON, attachments: JSON, idempotencyKey: String, managerSessionId: String, managerNodeExecId: String }
  input ReplayCommunicationInput { workflowId: String!, workflowExecutionId: String!, communicationId: String!, reason: String, idempotencyKey: String, managerSessionId: String }
  input RetryCommunicationDeliveryInput { workflowId: String!, workflowExecutionId: String!, communicationId: String!, reason: String, idempotencyKey: String, managerSessionId: String }
  input WorkflowInstanceInput { identity: String!, workflowId: String!, sourceIdentity: String, displayName: String, configuration: JSONObject }
  type LoopCostSummary {
    totalInputTokens: Int
    totalOutputTokens: Int
    totalTokens: Int
    totalDurationMs: Int
    stepsWithUsage: Int!
    stepsWithoutUsage: Int!
    partial: Boolean!
  }
  type LoopCostSummaryDelta {
    totalInputTokensDelta: Int
    totalOutputTokensDelta: Int
    totalTokensDelta: Int
    totalDurationMsDelta: Int
  }
  type LoopGateOutcome {
    gateId: String!
    stepId: String!
    decision: String!
    required: Boolean
    blockingFindingCount: Int!
  }
  type LoopGateFailureCount { gateId: String!, count: Int! }
  type LoopGateChange {
    gateId: String!
    baseDecision: String
    targetDecision: String
    severityCountsDelta: LoopFindingSeverityCounts!
  }
  type LoopVerificationChange {
    commandSummary: String!
    baseOutcome: String
    targetOutcome: String
  }
  type LoopSessionOverview {
    workflowId: String!
    sessionId: String!
    sessionStatus: String!
    loopKind: String
    loopRequired: Boolean
    loopEvidenceRecorded: Boolean!
    blockingFindingCount: Int
    lastGateDecision: String
    entryMode: String
    sourceSessionId: String
    cost: LoopCostSummary
    gateOutcomes: [LoopGateOutcome!]!
    possiblyStale: Boolean!
    createdAt: String!
    updatedAt: String!
  }
  type LoopWorkflowStats {
    workflowId: String!
    windowRuns: Int!
    completedRuns: Int!
    failedRuns: Int!
    acceptedRuns: Int!
    gateFailureCounts: [LoopGateFailureCount!]!
    rerunCount: Int!
    meanDurationMs: Int
    meanTotalTokens: Int
    lastAcceptedSessionId: String
    diagnostics: [String!]!
  }
  type LoopEvidenceDiff {
    baseSessionId: String!
    targetSessionId: String!
    sameWorkflow: Boolean!
    workflowDefinitionDigestChanged: Boolean
    gateChanges: [LoopGateChange!]!
    blockingFindingsAdded: [LoopBlockingFinding!]!
    blockingFindingsResolved: [LoopBlockingFinding!]!
    changedFilesAdded: [String!]!
    changedFilesRemoved: [String!]!
    verificationChanges: [LoopVerificationChange!]!
    residualRisksAdded: [LoopResidualRisk!]!
    residualRisksResolved: [LoopResidualRisk!]!
    costDelta: LoopCostSummaryDelta
    diagnostics: [String!]!
  }
  \(workflowRegistryGraphQLSchemaTypes)
  \(configurationGraphQLSchemaTypes)
  \(routineGraphQLSchemaTypes)
  type Query {
    workflowInstances(workflowId: String): WorkflowInstancesQueryPayload!
    workflowInstance(identity: String!, workflowId: String): WorkflowInstanceQueryPayload!
    workflowSession(workflowId: String!, sessionId: String!): WorkflowSession
    workflowSessions(workflowName: String, status: String, limit: Int): [WorkflowSessionSummary!]!
    sessionProgress(sessionId: String!, includeChildren: Boolean = false): SessionObservabilityPayload!
    sessionHealth(sessionId: String!): SessionObservabilityPayload!
    loopEvidence(workflowId: String!, sessionId: String!): LoopEvidenceSummary
    loopSessions(workflowId: String, status: String, limit: Int): [LoopSessionOverview!]!
    loopWorkflowStats(workflowId: String!, limit: Int): LoopWorkflowStats
    loopEvidenceDiff(baseSessionId: String!, targetSessionId: String!): LoopEvidenceDiff
    managerSession(managerSessionId: String): ManagerSessionView
    workflows(filter: WorkflowFilter): WorkflowListPayload!
    workflow(target: WorkflowTargetInput!): WorkflowQueryPayload!
    routines(filter: RoutineFilter): RoutineListPayload!
    routine(routineId: String!, routineStoreRoot: String): RoutineQueryPayload!
    configuration: RielaConfiguration!
  }
  type Mutation {
    createWorkflowInstance(input: WorkflowInstanceInput!): WorkflowInstanceMutationPayload!
    updateWorkflowInstance(input: WorkflowInstanceInput!): WorkflowInstanceMutationPayload!
    deleteWorkflowInstance(identity: String!, workflowId: String): WorkflowInstanceMutationPayload!
    continueSession(input: ContinueSessionInput!): ControlPlaneResult!
    sendManagerMessage(input: SendManagerMessageInput!): SendManagerMessagePayload!
    replayCommunication(input: ReplayCommunicationInput!): ReplayCommunicationPayload!
    retryCommunicationDelivery(input: RetryCommunicationDeliveryInput!): RetryCommunicationDeliveryPayload!
    registerMutableWorkflow(input: RegisterMutableWorkflowInput!): WorkflowMutationPayload!
    updateMutableWorkflow(input: UpdateMutableWorkflowInput!): WorkflowMutationPayload!
    deleteMutableWorkflow(input: DeleteMutableWorkflowInput!): WorkflowMutationPayload!
    activateWorkflow(input: SetWorkflowActivationInput!): WorkflowMutationPayload!
    deactivateWorkflow(input: SetWorkflowActivationInput!): WorkflowMutationPayload!
    consolidateWorkflows(input: ConsolidateWorkflowsInput!): WorkflowMutationPayload!
    createRoutine(input: CreateRoutineInput!): RoutineMutationPayload!
    completeRoutine(input: CompleteRoutineInput!): RoutineMutationPayload!
    setRoutineStatus(input: SetRoutineStatusInput!): RoutineMutationPayload!
    deleteRoutine(input: DeleteRoutineInput!): RoutineMutationPayload!
    updateAssistantConfiguration(input: UpdateAssistantConfigurationInput!): RielaConfiguration!
    updateAppearanceConfiguration(input: UpdateAppearanceConfigurationInput!): RielaConfiguration!
    updateHTTPServerConfiguration(input: UpdateHTTPServerConfigurationInput!): RielaConfiguration!
    createProfileConfiguration(input: ProfileConfigurationInput!): RielaConfiguration!
    removeProfileConfiguration(input: ProfileConfigurationInput!): RielaConfiguration!
    switchProfileConfiguration(input: ProfileConfigurationInput!): RielaConfiguration!
    addWorkflowDirectoryConfiguration(input: WorkflowDirectoryConfigurationInput!): ConfigurationRevision!
    updateWorkflowInstanceConfiguration(input: WorkflowInstanceConfigurationInput!): ConfigurationRevision!
    registerEventSourceConfiguration(input: EventSourceConfigurationInput!): ConfigurationRevision!
  }
  """
}
