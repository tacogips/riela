// GENERATED FILE - do not edit by hand.
//
// Rendered by `GraphQLSchemaGenerator.render()` from the control-plane
// contract descriptors in `GraphQLSchemaGenerator.swift` plus the GraphQL
// bindings in `SurfaceCatalog`. Regenerate with
// `scripts/surface-parity/generate-sdl.sh`; `SurfaceParityGraphQLTests`
// fails if this file and the generator disagree by a single byte.
extension GraphQLContractProjector {
  public static let schemaContract = """
  scalar JSON
  scalar JSONObject
  type Routine {
    routineId: String!
    name: String!
    instruction: String
    task: String!
    schedule: String!
    timezone: String
    workflowName: String!
    completionCriteria: String
    status: RoutineStatus!
    createdAt: String!
    updatedAt: String!
    completedAt: String
    completionNote: String
    lastRunAt: String
    runCount: Int!
    eventRoot: String!
    sourceId: String!
    bindingId: String!
    deactivateWorkflowOnCompletion: Boolean!
    origin: JSONObject
    overlapPolicy: EventOverlapPolicy
    maxQueuedRuns: Int
    maxConcurrentRuns: Int
    botId: String
  }
  input CreateRoutineInput {
    name: String!
    instruction: String
    task: String!
    schedule: String
    every: String
    timezone: String
    workflowName: String!
    completionCriteria: String
    eventRoot: String
    routineStoreRoot: String
    deactivateWorkflowOnCompletion: Boolean
    origin: JSONObject
    overlapPolicy: EventOverlapPolicy
    maxQueuedRuns: Int
    maxConcurrentRuns: Int
    botId: String
  }
  type Bot {
    botId: String!
    name: String!
    purpose: String
    personaId: String
    defaultBackend: String
    defaultModel: String
    providerInstanceId: String
    workspace: String
    paused: Boolean!
    memoryUpkeep: String!
    lookAround: String!
    permissionWaitMs: Int!
    createdAt: String!
    updatedAt: String!
  }
  type BotCounts {
    needsYou: Int!
    working: Int!
    waiting: Int!
    planned: Int!
  }
  type BotOrigin {
    remote: String!
    serverId: String
    serverName: String
    verified: Boolean!
    connection: String!
    observedAt: String!
  }
  type BotListState {
    pinned: Boolean!
    manualOrder: Int
    snoozedUntil: String
    snoozedAt: String
    settledAt: String
    settledBy: String
  }
  type BotBoardItem {
    itemKind: String!
    itemId: String!
    group: String!
    title: String!
    workflowId: String
    stepId: String
    nodeId: String
    backend: String
    model: String
    startedAt: String
    elapsedMs: Int
    lastActivityAt: String
    status: String!
    waitingReason: String
    limitedResetAt: String
    activitySource: String!
    doingNow: String
    checklist: [BotActivityPlan!]!
    pendingRequests: [BotPendingRequest!]!
    answerPath: String
    question: BotBoardQuestion
    lastResult: String
    sessionId: String
    bumpedAt: String
    listState: BotListState!
    origin: BotOrigin!
  }
  type BotActivityPlan {\n  planId: String!\n  entries: [BotActivityPlanEntry!]!\n}
  type BotActivityPlanEntry {
    content: String!
    status: String!
    priority: String!
  }
  type BotPendingRequest {
    requestId: String!
    title: String
    options: [BotPermissionOption!]!
    createdAt: String!
    expiresAt: String!
  }
  type BotPermissionOption {
    optionId: String!
    name: String!
    kind: String!
  }
  type BotBoardQuestion {
    questionId: String!
    text: String!
    optionIds: [String!]!
  }
  type BotBoard {
    needsYou: [BotBoardItem!]!
    inProgress: [BotBoardItem!]!
    waiting: [BotBoardItem!]!
    planned: [BotBoardItem!]!
    closed: [BotBoardItem!]!
    closedTotal: Int!
  }
  type BotOverviewRow {
    bot: Bot!
    counts: BotCounts!
    inProgress: [BotBoardItem!]!
    lastActivityAt: String
    lastResult: String
    listState: BotListState!
    section: String!
    workspaceGroup: String!
    origin: BotOrigin!
  }
  type BotWorkspaceGroup {
    key: String!
    needsYou: Boolean!
    botIds: [String!]!
  }
  type BotRoutine {
    routineId: String!
    name: String!
    workflowName: String!
    status: String!
    nextRunAt: String
  }
  type BotListPayload {
    bots: [BotOverviewRow!]!
    groups: [BotWorkspaceGroup!]!
    origin: BotOrigin
  }
  type BotDetailPayload {
    bot: Bot!
    board: BotBoard!
    routines: [BotRoutine!]!
    origin: BotOrigin!
    suggestions: [BotSuggestion!]!
    jobs: [BotJobSummary!]!
    memory: BotMemorySummary!
  }
  type BotMutationPayload {
    bot: Bot!
    warnings: [String!]!
    origin: BotOrigin!
  }
  input BotFilter {\n  groupBy: String\n  remote: String\n}
  input CreateBotInput {
    id: String
    name: String!
    purpose: String
    personaId: String
    defaultBackend: String
    defaultModel: String
    providerInstanceId: String
    workspace: String
    memoryUpkeep: String
    lookAround: String
    permissionWaitMs: Int
    remote: String
  }
  input UpdateBotInput {
    botId: String!
    name: String
    purpose: String
    personaId: String
    defaultBackend: String
    defaultModel: String
    providerInstanceId: String
    workspace: String
    memoryUpkeep: String
    lookAround: String
    permissionWaitMs: Int
    remote: String
  }
  input SetBotPausedInput {
    botId: String!
    paused: Boolean!
    remote: String
  }
  input RemoveBotInput {\n  botId: String!\n  remote: String\n}
  input SetBotListStateInput {
    botId: String!
    itemKind: String
    itemId: String
    pinned: Boolean
    manualOrder: Int
    snoozedUntil: String
    clearSnooze: Boolean
    settled: Boolean
    remote: String
  }
  type BotActivityEvent {
    sessionId: String!
    seq: Int!
    executionId: String
    at: String!
    kind: String!
    payload: JSONObject!
  }
  type BotActivityToolCall {
    toolCallId: String!
    title: String
    toolKind: String
    status: String
    locations: [BotActivityLocation!]
    updatedAt: String!
  }
  type BotActivityLocation {\n  path: String!\n  line: Int\n}
  type BotActivitySubagent {
    subSessionId: String!
    title: String
    state: String
  }
  type BotActivityStop {
    stopReason: String!
    limited: Boolean!
    limitedResetAt: String
  }
  type BotActivityState {
    source: String!
    currentExecutionId: String
    currentStepId: String
    currentNodeId: String
    backend: String
    requestedModel: String
    reportedModel: String
    toolCalls: [BotActivityToolCall!]!
    plans: [BotActivityPlan!]!
    mode: String
    commands: [String!]!
    configOptions: JSON!
    usage: JSON
    subagents: [BotActivitySubagent!]!
    pendingRequestIds: [String!]!
    lastStop: BotActivityStop
    lastMessageLine: String
    lastEventAt: String
  }
  type BotActivityPage {
    events: [BotActivityEvent!]!
    state: BotActivityState
    lastSequence: Int!
    firstRetainedSequence: Int!
    truncated: Boolean!
    activitySource: String!
    sessionStatus: String!
    origin: BotOrigin!
  }
  input AnswerBotRequestInput {
    requestId: String!
    optionId: String
    decline: Boolean
    remote: String
  }
  type BotRequestPayload {
    requestId: String!
    status: String!
    outcomeOptionId: String
    resolvedBy: String
    origin: BotOrigin!
  }
  type BotMemorySummary {
    instructionCount: Int!
    noteCount: Int!
    lastChangedAt: String
  }
  type BotMemoryPayload {
    botId: String!
    markdown: String!
    instructionCount: Int!
    noteCount: Int!
    changes: [BotMemoryChange!]!
    origin: BotOrigin!
  }
  type BotMemoryHistoryPayload {\n  changes: [BotMemoryChange!]!\n  origin: BotOrigin!\n}
  type BotMemoryDiffPayload {\n  diffs: [BotMemoryEntryDiff!]!\n  origin: BotOrigin!\n}
  type BotMemoryEntryDiff {\n  entry: BotMemoryChangeEntry!\n  changes: [BotMemoryDiffField!]!\n}
  type BotMemoryDiffField {
    path: String!
    op: String!
    beforeJSON: String
    afterJSON: String
    encoding: String
    beforeSHA256: String
    afterSHA256: String
    beforeByteCount: Int
    afterByteCount: Int
    prefixByteCount: Int
    suffixByteCount: Int
  }
  type BotMemoryChangePayload {\n  change: BotMemoryChange!\n  origin: BotOrigin!\n}
  type BotMemoryChange {
    changeId: String!
    botId: String!
    actor: String!
    reason: String!
    evidenceRefs: [String!]!
    createdAt: String!
    entries: [BotMemoryChangeEntry!]!
    redacted: Boolean!
    downgraded: Boolean!
    ignoredInstructionChanges: Int!
  }
  type BotMemoryChangeEntry {
    recordId: Int!
    op: String!
    fromVersion: Int
    toVersion: Int!
  }
  input UpdateBotMemoryInput {
    botId: String!
    markdown: String!
    reason: String
    remote: String
  }
  input UndoBotMemoryChangeInput {
    botId: String!
    changeId: String
    remote: String
  }
  input CaptureBotFeedbackInput {
    botId: String!
    sessionId: String
    taskId: String
    text: String
    topic: String
    fromFindings: Boolean
    remote: String
  }
  type BotSuggestion {
    suggestionId: String!
    botId: String!
    title: String!
    detail: String
    action: BotSuggestionAction
    status: String!
    createdAt: String!
    sourceSessionId: String
    acceptedAt: String
    acceptedBy: String
    dismissedAt: String
    dismissedBy: String
    dismissReason: String
    startedSessionId: String
    origin: BotOrigin
  }
  type BotSuggestionAction {\n  workflowName: String!\n  input: JSON!\n}
  type BotSuggestionListPayload {
    botId: String!
    suggestions: [BotSuggestion!]!
    origin: BotOrigin!
  }
  type BotSuggestionPayload {\n  suggestion: BotSuggestion!\n  origin: BotOrigin!\n}
  type BotJobSummary {
    job: String!
    schedule: String!
    lastRun: BotJobRun
  }
  type BotJobHistoryPayload {\n  runs: [BotJobRun!]!\n  origin: BotOrigin!\n}
  type BotJobRun {
    botId: String!
    job: String!
    periodKey: String!
    status: String!
    sessionId: String
    detail: String
    startedAt: String!
    finishedAt: String
  }
  type BotJobPayload {
    botId: String!
    job: String!
    periodKey: String
    status: String!
    sessionId: String
    detail: String
    origin: BotOrigin!
    changeSet: BotMemoryChange
    suggestions: [BotSuggestion!]
  }
  input DecideBotSuggestionInput {
    suggestionId: String!
    decision: String!
    run: Boolean
    reason: String
    remote: String
  }
  input RunBotJobInput {
    botId: String!
    job: String!
    force: Boolean
    remote: String
  }
  type CatalogModel {
    id: String!
    label: String
    sources: [String!]!
    reasoningEfforts: [String!]!
    serviceTiers: [String!]!
    modes: [String!]!
    observedAt: String
    origin: BotOrigin
  }
  type ProviderInstance {
    instanceId: String!
    driver: String!
    label: String
    account: String
    builtIn: Boolean!
    availability: String
    authentication: String
    version: String
    failures: [String!]!
    probedAt: String
    models: [CatalogModel!]!
    origin: BotOrigin!
  }
  type ModelCatalogPayload {\n  providers: [ProviderInstance!]!\n}
  type ProviderListPayload {\n  providers: [ProviderInstance!]!\n}
  type ProviderPayload {\n  provider: ProviderInstance!\n}
  input SaveProviderInstanceInput {
    instanceId: String!
    driver: String
    label: String
    account: String
    providerName: String
    providerProxy: String
    apiKeyEnvironment: String
    customModels: [String!]
    remote: String
  }
  input RefreshProvidersInput {\n  instanceId: String\n  remote: String\n}
  input RemoveProviderInstanceInput {\n  instanceId: String!\n  remote: String\n}
  type PairingGrant {
    grantId: String!
    clientName: String!
    scope: String!
    createdAt: String!
    lastUsedAt: String
    revokedAt: String
  }
  type PairingGrantListPayload {\n  grants: [PairingGrant!]!\n}
  type PairingCodePayload {
    code: String!
    expiresAt: String!
    address: String!
    scope: String!
  }
  input MintPairingCodeInput {\n  address: String!\n  scope: String\n}
  input RevokePairingGrantInput {\n  grantId: String!\n}
  type RemoteSummary {
    name: String!
    address: String!
    serverName: String!
    scope: String!
    lastSeenAt: String
    connection: String!
  }
  type RemoteListPayload {\n  active: String!\n  remotes: [RemoteSummary!]!\n}
  input AddRemoteInput {
    name: String!
    code: String!
    clientName: String
  }
  input RemoveRemoteInput {\n  name: String!\n}
  input UseRemoteInput {\n  name: String!\n}
  input ExecuteWorkflowInput {
    workflowName: String!
    runtimeVariables: JSONObject
    instanceIdentity: String
    nodePatch: JSONObject
    maxSteps: Int
    maxConcurrency: Int
    maxLoopIterations: Int
    disableDefaultLoopGuard: Boolean
    defaultTimeoutMs: Int
    botId: String
  }
  type ExecuteWorkflowPayload {
    workflowExecutionId: String!
    sessionId: String!
    status: String!
    exitCode: Int!
  }
  type WorkflowExecutionSummary {\n  session: WorkflowExecutionSessionSummary!\n  nodeExecutions: [WorkflowExecutionNodeSummary!]!\n}
  type WorkflowExecutionSessionSummary {
    sessionId: String!
    workflowName: String!
    workflowId: String!
    transitions: [WorkflowExecutionTransitionSummary!]!
  }
  type WorkflowExecutionTransitionSummary {\n  when: String\n}
  type WorkflowExecutionNodeSummary {\n  nodeExecId: String!\n}
  type ControlPlaneResult {
    accepted: Boolean!
    status: String!
    diagnostics: [String!]!
  }
  type ManagerIntentSummary {
    kind: String!
    targetId: String
    reason: String
  }
  type ManagerSessionView {\n  session: JSON!\n  messages: JSON!\n}
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
  type ReplayCommunicationPayload {
    sourceCommunicationId: String!
    workflowExecutionId: String!
    replayedCommunicationId: String!
    status: String!
  }
  type RetryCommunicationDeliveryPayload {
    communicationId: String!
    activeDeliveryAttemptId: String!
    status: String!
  }
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
  type LoopFindingSeverityCounts {
    high: Int!
    medium: Int!
    low: Int!
    informational: Int!
  }
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
  type SessionRollupNode {\n  digest: SessionProgressDigest!\n  children: [SessionRollupNode!]!\n}
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
  type SessionObservabilityPayload {\n  result: ControlPlaneResult!\n  view: SessionObservabilityView\n}
  type WorkflowInstance {
    identity: String!
    workflowId: String!
    sourceIdentity: String
    displayName: String
    configuration: JSONObject!
  }
  type WorkflowInstanceQueryPayload {\n  result: ControlPlaneResult!\n  value: WorkflowInstance\n}
  type WorkflowInstancesQueryPayload {\n  result: ControlPlaneResult!\n  value: [WorkflowInstance!]\n}
  type WorkflowInstanceMutationPayload {\n  result: ControlPlaneResult!\n  instance: WorkflowInstance\n}
  type StepExecution {
    executionId: String!
    stepId: String!
    nodeId: String!
    attempt: Int!
    backend: String
    status: String!
    failureReason: String
  }
  type Communication {
    communicationId: String!
    fromStepId: String
    toStepId: String
    lifecycleStatus: String!
    deliveryKind: String!
    createdOrder: Int!
  }
  type HookEvent {
    vendor: String!
    eventName: String!
    agentSessionId: String!
    payloadHash: String
  }
  type EventReceipt {
    sourceId: String!
    eventId: String!
    status: String!
  }
  type ReplyDispatch {
    sourceId: String!
    provider: String!
    payload: JSONObject!
  }
  type LogEntry {\n  level: String!\n  message: String!\n}
  type LLMSessionMessage {\n  role: String!\n  content: String!\n}
  input ContinueSessionInput {
    workflowId: String!
    sessionId: String!
    input: JSONObject!
  }
  input SendManagerMessageInput {
    workflowId: String!
    workflowExecutionId: String!
    message: String
    actions: JSON
    attachments: JSON
    idempotencyKey: String
    managerSessionId: String
    managerNodeExecId: String
  }
  input ReplayCommunicationInput {
    workflowId: String!
    workflowExecutionId: String!
    communicationId: String!
    reason: String
    idempotencyKey: String
    managerSessionId: String
  }
  input RetryCommunicationDeliveryInput {
    workflowId: String!
    workflowExecutionId: String!
    communicationId: String!
    reason: String
    idempotencyKey: String
    managerSessionId: String
  }
  input WorkflowInstanceInput {
    identity: String!
    workflowId: String!
    sourceIdentity: String
    displayName: String
    configuration: JSONObject
  }
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
  type LoopGateFailureCount {\n  gateId: String!\n  count: Int!\n}
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
  input RerunSessionInput {
    workflowId: String!
    sessionId: String!
    stepId: String!
    managerSessionId: String
  }
  input ResumeSessionInput {
    workflowId: String!
    sessionId: String!
    managerSessionId: String
  }
  input StopSessionInput {
    workflowId: String!
    sessionId: String!
    reason: String
    managerSessionId: String
  }
  type SessionLineage {
    sessionId: String!
    parentSessionId: String
    rootSessionId: String!
    entryMode: String!
    sourceStepId: String
  }
  type SessionMutationPayload {
    result: ControlPlaneResult!
    sessionId: String
    status: String
    lineage: SessionLineage
  }
  type ConsoleInstanceEnvironmentVariable {
    name: String!
    isSet: Boolean!
    masked: String!
  }
  type ConsoleInstanceRequiredEnvironment {
    name: String!
    description: String
    required: Boolean!
    secret: Boolean!
    source: String!
    present: Boolean!
  }
  type ConsoleInstanceEventSource {\n  id: String!\n  kind: String!\n}
  type ConsoleInstance {
    id: String!
    sourceId: String!
    isDefault: Boolean!
    name: String!
    workflowId: String!
    source: String!
    sourceKind: String!
    status: String!
    statusDetail: String!
    active: Boolean!
    enabledAtLaunch: Boolean!
    workingDirectory: String
    environmentFilePath: String
    environmentResolution: JSONObject
    environmentStatus: JSONObject
    environmentVariables: [ConsoleInstanceEnvironmentVariable!]!
    requiredEnvironment: [ConsoleInstanceRequiredEnvironment!]!
    workflowVariables: JSONObject!
    nodePatchCount: Int!
    nodePatches: JSONObject!
    eventSources: [ConsoleInstanceEventSource!]!
  }
  type ConsoleInstanceListPayload {
    profile: String!
    revision: Int!
    items: [ConsoleInstance!]!
  }
  type ConsoleInstancePayload {
    profile: String!
    revision: Int!
    item: ConsoleInstance
  }
  type OpsOverviewTransition {
    toStepId: String!
    label: String
    fanoutJoinStepId: String
  }
  type OpsOverviewStep {
    id: String!
    nodeId: String!
    role: String
    description: String
    transitions: [OpsOverviewTransition!]!
  }
  type OpsOverviewNode {
    id: String!
    kind: String
    role: String
    addon: String
  }
  type OpsOverviewWorkflow {
    sourceId: String!
    name: String!
    workflowId: String!
    scope: String!
    sourceKind: String!
    description: String!
    entryStepId: String!
    managerStepId: String
    steps: [OpsOverviewStep!]!
    nodes: [OpsOverviewNode!]!
    stepsTruncated: Boolean!
  }
  type OpsOverviewInstance {
    id: String!
    sourceId: String!
    isDefault: Boolean!
    name: String!
    workflowId: String!
    status: String!
    active: Boolean!
  }
  type OpsOverviewRun {
    instanceId: String!
    sessionId: String!
    workflowId: String!
    status: String!
    currentStepId: String
    activeStepIds: [String!]!
    updatedAt: String!
  }
  type OpsOverviewPayload {
    profile: String!
    revision: Int!
    workflows: [OpsOverviewWorkflow!]!
    workflowsTruncated: Boolean!
    instances: [OpsOverviewInstance!]!
    runs: [OpsOverviewRun!]!
    runsTruncated: Boolean!
    diagnostics: [String!]!
  }
  \(workflowRegistryGraphQLSchemaTypes)
  \(configurationGraphQLSchemaTypes)
  \(routineGraphQLSupplementalSchemaTypes)
  \(taskHandoverGraphQLSchemaTypes)
  \(workflowDefinitionGraphQLSchemaTypes)
  type Query {
    workflow(target: WorkflowTargetInput!): WorkflowQueryPayload!
    workflowExecution(workflowExecutionId: String!): WorkflowExecutionSummary
    workflows(filter: WorkflowFilter): WorkflowListPayload!
    workflowDefinitionHistory(workflowName: String!, nodeId: String, limit: Int, storeScope: String): [WorkflowDefinitionAuditRecord!]!
    workflowDefinition(workflowName: String!, versionId: String, storeScope: String): WorkflowDefinitionVersion
    workflowDefinitionDiff(workflowName: String!, fromVersionId: String, toVersionId: String, againstFile: Boolean, storeScope: String): [WorkflowDefinitionDiffEntry!]!
    workflowSessions(workflowName: String, status: String, limit: Int): [WorkflowSessionSummary!]!
    workflowSession(workflowId: String!, sessionId: String!): WorkflowSession
    sessionProgress(sessionId: String!, includeChildren: Boolean = false): SessionObservabilityPayload!
    sessionHealth(sessionId: String!): SessionObservabilityPayload!
    loopEvidence(workflowId: String!, sessionId: String!): LoopEvidenceSummary
    loopSessions(workflowId: String, status: String, limit: Int): [LoopSessionOverview!]!
    loopWorkflowStats(workflowId: String!, limit: Int): LoopWorkflowStats
    loopEvidenceDiff(baseSessionId: String!, targetSessionId: String!): LoopEvidenceDiff
    workflowInstances(workflowId: String): WorkflowInstancesQueryPayload!
    workflowInstance(identity: String!, workflowId: String): WorkflowInstanceQueryPayload!
    routines(filter: RoutineFilter): RoutineListPayload!
    routine(routineId: String!, routineStoreRoot: String): RoutineQueryPayload!
    pairingGrants: PairingGrantListPayload!
    managerSession(managerSessionId: String): ManagerSessionView
    taskHandover(taskId: String!, handoverId: String): TaskHandoverPayload!
    tasksAwaitingHandover(traits: [String!]): TasksAwaitingHandoverPayload!
    consoleInstances: ConsoleInstanceListPayload!
    consoleInstance(identity: String!): ConsoleInstancePayload!
    opsOverview: OpsOverviewPayload!
    configuration: RielaConfiguration!
    bots(filter: BotFilter): BotListPayload!
    bot(botId: String!, remote: String): BotDetailPayload!
    botActivity(sessionId: String!, afterSequence: Int = 0, limit: Int = 200, waitMs: Int = 0, remote: String): BotActivityPage!
    botMemory(botId: String!, remote: String): BotMemoryPayload!
    botMemoryHistory(botId: String!, limit: Int, remote: String): BotMemoryHistoryPayload!
    botMemoryDiff(botId: String!, changeId: String!, remote: String): BotMemoryDiffPayload!
    botJobHistory(botId: String!, job: String, limit: Int, remote: String): BotJobHistoryPayload!
    botSuggestions(botId: String!, status: String, remote: String): BotSuggestionListPayload!
    modelCatalog(providerInstanceId: String, remote: String): ModelCatalogPayload!
    providers(remote: String): ProviderListPayload!
    provider(instanceId: String!, remote: String): ProviderPayload!
    remotes: RemoteListPayload!
  }
  type Mutation {
    executeWorkflow(input: ExecuteWorkflowInput!): ExecuteWorkflowPayload!
    registerMutableWorkflow(input: RegisterMutableWorkflowInput!): WorkflowMutationPayload!
    updateMutableWorkflow(input: UpdateMutableWorkflowInput!): WorkflowMutationPayload!
    deleteMutableWorkflow(input: DeleteMutableWorkflowInput!): WorkflowMutationPayload!
    activateWorkflow(input: SetWorkflowActivationInput!): WorkflowMutationPayload!
    deactivateWorkflow(input: SetWorkflowActivationInput!): WorkflowMutationPayload!
    consolidateWorkflows(input: ConsolidateWorkflowsInput!): WorkflowMutationPayload!
    updateWorkflowDefinition(input: UpdateWorkflowDefinitionInput!): WorkflowDefinitionUpdatePayload!
    updateWorkflowDefinitionPrompt(input: UpdateWorkflowDefinitionPromptInput!): WorkflowDefinitionMutationPayload!
    restoreWorkflowDefinition(input: RestoreWorkflowDefinitionInput!): WorkflowDefinitionMutationPayload!
    undoWorkflowDefinition(input: UndoWorkflowDefinitionInput!): WorkflowDefinitionMutationPayload!
    redoWorkflowDefinition(input: RedoWorkflowDefinitionInput!): WorkflowDefinitionMutationPayload!
    importWorkflowDefinition(input: ImportWorkflowDefinitionInput!): WorkflowDefinitionImportPayload!
    exportWorkflowDefinition(input: ExportWorkflowDefinitionInput!): WorkflowDefinitionExportPayload!
    rerunSession(input: RerunSessionInput!): SessionMutationPayload!
    resumeSession(input: ResumeSessionInput!): SessionMutationPayload!
    stopSession(input: StopSessionInput!): SessionMutationPayload!
    continueSession(input: ContinueSessionInput!): ControlPlaneResult!
    createWorkflowInstance(input: WorkflowInstanceInput!): WorkflowInstanceMutationPayload!
    updateWorkflowInstance(input: WorkflowInstanceInput!): WorkflowInstanceMutationPayload!
    deleteWorkflowInstance(identity: String!, workflowId: String): WorkflowInstanceMutationPayload!
    createRoutine(input: CreateRoutineInput!): RoutineMutationPayload!
    completeRoutine(input: CompleteRoutineInput!): RoutineMutationPayload!
    setRoutineStatus(input: SetRoutineStatusInput!): RoutineMutationPayload!
    setRoutineOverlapPolicy(input: SetRoutineOverlapPolicyInput!): RoutineMutationPayload!
    deleteRoutine(input: DeleteRoutineInput!): RoutineMutationPayload!
    mintPairingCode(input: MintPairingCodeInput!): PairingCodePayload!
    revokePairingGrant(input: RevokePairingGrantInput!): PairingGrantListPayload!
    sendManagerMessage(input: SendManagerMessageInput!): SendManagerMessagePayload!
    replayCommunication(input: ReplayCommunicationInput!): ReplayCommunicationPayload!
    retryCommunicationDelivery(input: RetryCommunicationDeliveryInput!): RetryCommunicationDeliveryPayload!
    requestTaskHandover(input: RequestTaskHandoverInput!): TaskHandoverMutationPayload!
    takeoverTask(input: TakeoverTaskInput!): TakeoverTaskPayload!
    answerTask(input: AnswerTaskInput!): TaskHandoverMutationPayload!
    heartbeatAttempt(attemptId: String!, token: String!): LeaseStatePayload!
    reportAttempt(input: ReportAttemptInput!): ReportAttemptPayload!
    updateAssistantConfiguration(input: UpdateAssistantConfigurationInput!): RielaConfiguration!
    updateAppearanceConfiguration(input: UpdateAppearanceConfigurationInput!): RielaConfiguration!
    updateHTTPServerConfiguration(input: UpdateHTTPServerConfigurationInput!): RielaConfiguration!
    createProfileConfiguration(input: ProfileConfigurationInput!): RielaConfiguration!
    removeProfileConfiguration(input: ProfileConfigurationInput!): RielaConfiguration!
    switchProfileConfiguration(input: ProfileConfigurationInput!): RielaConfiguration!
    addWorkflowDirectoryConfiguration(input: WorkflowDirectoryConfigurationInput!): ConfigurationRevision!
    updateWorkflowStorageConfiguration(input: UpdateWorkflowStorageConfigurationInput!): RielaConfiguration!
    updateWorkflowInstanceConfiguration(input: WorkflowInstanceConfigurationInput!): ConfigurationRevision!
    registerEventSourceConfiguration(input: EventSourceConfigurationInput!): ConfigurationRevision!
    createBot(input: CreateBotInput!): BotMutationPayload!
    updateBot(input: UpdateBotInput!): BotMutationPayload!
    setBotPaused(input: SetBotPausedInput!): BotMutationPayload!
    removeBot(input: RemoveBotInput!): BotMutationPayload!
    updateBotMemory(input: UpdateBotMemoryInput!): BotMemoryChangePayload!
    undoBotMemoryChange(input: UndoBotMemoryChangeInput!): BotMemoryChangePayload!
    captureBotFeedback(input: CaptureBotFeedbackInput!): BotMemoryChangePayload!
    runBotJob(input: RunBotJobInput!): BotJobPayload!
    decideBotSuggestion(input: DecideBotSuggestionInput!): BotSuggestionPayload!
    answerBotRequest(input: AnswerBotRequestInput!): BotRequestPayload!
    setBotListState(input: SetBotListStateInput!): BotMutationPayload!
    refreshProviders(input: RefreshProvidersInput!): ProviderListPayload!
    saveProviderInstance(input: SaveProviderInstanceInput!): ProviderPayload!
    removeProviderInstance(input: RemoveProviderInstanceInput!): ProviderListPayload!
    addRemote(input: AddRemoteInput!): RemoteListPayload!
    removeRemote(input: RemoveRemoteInput!): RemoteListPayload!
    useRemote(input: UseRemoteInput!): RemoteListPayload!
  }
  """
}
