extension GraphQLContractProjector {
  public static let schemaContract = """
  scalar JSON
  scalar JSONObject
  \(graphQLNoteSchemaContract)
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
  type Query {
    note(noteId: String!): NoteQueryPayload!
    notebook(notebookId: String!): NotebookQueryPayload!
    notebooks(
      limit: Int,
      offset: Int,
      tagFilter: [String!],
      tagFilterGroups: [[String!]!],
      tagFilterIdGroups: [[String!]!],
      sort: NoteListSort,
      createdAfter: String,
      createdBefore: String
    ): NotebooksQueryPayload!
    notes(limit: Int, offset: Int, notebookId: String, tagFilter: [String!]): NotesQueryPayload!
    # Direct full-text hits are ranked first; sort orders filter-only results.
    # Linked neighbors are appended after direct hits ordered by descending
    # graph relevance weight; the sort argument does not reorder them.
    searchNotes(
      query: String!, tagFilter: [String!], classFilter: [String!],
      sort: NoteListSort, createdAfter: String, createdBefore: String,
      includeLinked: Boolean, depth: Int, limit: Int, offset: Int
    ): NoteSearchQueryPayload!
    noteGraphNeighbors(noteIds: [String!]!, depth: Int, limit: Int): NoteGraphNeighborsQueryPayload!
    proposeNoteLinks(noteId: String!, limit: Int): NoteLinkProposalQueryPayload!
    tags: NoteTagsQueryPayload!
    tagClasses: NoteTagClassesQueryPayload!
    kanbanStatusSets: KanbanStatusSetsQueryPayload!
    effectiveKanbanStatuses(tagName: String): KanbanStatusSetQueryPayload!
    effectiveKanbanStatusesByTagId(tagId: String!): KanbanStatusSetQueryPayload!
    noteFile(fileId: String!): NoteFileQueryPayload!
    autoActions: NoteAutoActionsQueryPayload!
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
  }
  type Mutation {
    createNote(input: CreateNoteInput!): NoteMutationPayload!
    createNotebook(input: CreateNotebookInput!): NoteMutationPayload!
    defineNoteTagClass(input: DefineNoteTagClassInput!): NoteMutationPayload!
    defineNoteTag(input: DefineNoteTagInput!): NoteMutationPayload!
    scaffoldNoteIngestionWorkflow(input: ScaffoldNoteIngestionWorkflowInput!): NoteMutationPayload!
    updateNote(input: UpdateNoteInput!): NoteMutationPayload!
    deleteNote(noteId: String!): ControlPlaneResult!
    deleteNotebook(notebookId: String!): ControlPlaneResult!
    applyNotebookTags(input: ApplyNotebookTagsInput!): NoteMutationPayload!
    applyNotebookTagIds(input: ApplyNotebookTagIdsInput!): NoteMutationPayload!
    removeNotebookTag(notebookId: String!, tagName: String!, provenance: String): NoteMutationPayload!
    removeNotebookTagById(notebookId: String!, tagId: String!, provenance: String): NoteMutationPayload!
    setNotebookProgress(notebookId: String!, progress: String!, expectedProgress: String): NoteMutationPayload!
    setNotebookReadOnly(notebookId: String!, readOnly: Boolean!): NoteMutationPayload!
    createKanbanStatusSet(name: String!, statuses: [KanbanStatusInput!]!): KanbanStatusSetQueryPayload!
    updateKanbanStatusSet(setId: String!, statuses: [KanbanStatusInput!]!, reassignments: [KanbanStatusReassignmentInput!]): KanbanStatusSetQueryPayload!
    deleteKanbanStatusSet(setId: String!): ControlPlaneResult!
    assignKanbanStatusSet(tagName: String!, setId: String): NoteMutationPayload!
    assignKanbanStatusSetByTagId(tagId: String!, setId: String): NoteMutationPayload!
    setNoteReadOnly(noteId: String!, readOnly: Boolean!): NoteMutationPayload!
    applyNoteTags(input: ApplyNoteTagsInput!): NoteMutationPayload!
    removeNoteTag(noteId: String!, tagName: String!, provenance: String): NoteMutationPayload!
    addNoteComment(input: AddNoteCommentInput!): NoteMutationPayload!
    linkNotes(input: LinkNotesInput!): NoteMutationPayload!
    attachNoteFile(input: AttachNoteFileInput!): NoteMutationPayload!
    configureNoteAutoAction(input: ConfigureNoteAutoActionInput!): NoteMutationPayload!
    deleteNoteAutoAction(actionId: String!): ControlPlaneResult!
    saveNoteConversation(input: SaveNoteConversationInput!): NoteMutationPayload!
    migrateNoteFileStorage(input: MigrateNoteFileStorageInput!): NoteFileMigrationPayload!
    migrateAllNoteFiles(input: MigrateAllNoteFilesInput!): NoteFileMigrationPayload!
    reclaimNoteFileStorage(input: ReclaimNoteFileStorageInput!): NoteFileReclamationPayload!
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
  }
  """
}
