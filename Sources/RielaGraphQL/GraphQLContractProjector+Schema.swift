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
  type BotCounts {\n  needsYou: Int!\n  working: Int!\n  waiting: Int!\n  planned: Int!\n}
  type BotOrigin {\n  remote: String!\n  serverId: String\n  serverName: String\n  verified: Boolean!\n  connection: String!\n  observedAt: String!\n}
  type BotListState {\n  pinned: Boolean!\n  manualOrder: Int\n  snoozedUntil: String\n  snoozedAt: String\n  settledAt: String\n  settledBy: String\n}
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
  type BotActivityPlanEntry {\n  content: String!\n  status: String!\n  priority: String!\n}
  type BotPendingRequest {\n  requestId: String!\n  title: String\n  options: [BotPermissionOption!]!\n  createdAt: String!\n  expiresAt: String!\n}
  type BotPermissionOption {\n  optionId: String!\n  name: String!\n  kind: String!\n}
  type BotBoardQuestion {\n  questionId: String!\n  text: String!\n  optionIds: [String!]!\n}
  type BotBoard {\n  needsYou: [BotBoardItem!]!\n  inProgress: [BotBoardItem!]!\n  waiting: [BotBoardItem!]!\n  planned: [BotBoardItem!]!\n  closed: [BotBoardItem!]!\n  closedTotal: Int!\n}
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
  type BotWorkspaceGroup {\n  key: String!\n  needsYou: Boolean!\n  botIds: [String!]!\n}
  type BotRoutine {\n  routineId: String!\n  name: String!\n  workflowName: String!\n  status: String!\n  nextRunAt: String\n}
  type BotListPayload {\n  bots: [BotOverviewRow!]!\n  groups: [BotWorkspaceGroup!]!\n  origin: BotOrigin\n}
  type BotDetailPayload {\n  bot: Bot!\n  board: BotBoard!\n  routines: [BotRoutine!]!\n  origin: BotOrigin!\n  suggestions: [BotSuggestion!]!\n  jobs: [BotJobSummary!]!\n  memory: BotMemorySummary!\n}
  type BotMutationPayload {\n  bot: Bot!\n  warnings: [String!]!\n  origin: BotOrigin!\n}
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
  input SetBotPausedInput {\n  botId: String!\n  paused: Boolean!\n  remote: String\n}
  input RemoveBotInput {\n  botId: String!\n  remote: String\n}
  input SetBotListStateInput {\n  botId: String!\n  itemKind: String\n  itemId: String\n  pinned: Boolean\n  manualOrder: Int\n  snoozedUntil: String\n  clearSnooze: Boolean\n  settled: Boolean\n  remote: String\n}
  type BotActivityEvent {\n  sessionId: String!\n  seq: Int!\n  executionId: String\n  at: String!\n  kind: String!\n  payload: JSONObject!\n}
  type BotActivityToolCall {\n  toolCallId: String!\n  title: String\n  toolKind: String\n  status: String\n  locations: [BotActivityLocation!]\n  updatedAt: String!\n}
  type BotActivityLocation {\n  path: String!\n  line: Int\n}
  type BotActivitySubagent {\n  subSessionId: String!\n  title: String\n  state: String\n}
  type BotActivityStop {\n  stopReason: String!\n  limited: Boolean!\n  limitedResetAt: String\n}
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
  input AnswerBotRequestInput {\n  requestId: String!\n  optionId: String\n  decline: Boolean\n  remote: String\n}
  type BotRequestPayload {\n  requestId: String!\n  status: String!\n  outcomeOptionId: String\n  resolvedBy: String\n  origin: BotOrigin!\n}
  type BotMemorySummary {\n  instructionCount: Int!\n  noteCount: Int!\n  lastChangedAt: String\n}
  type BotMemoryPayload {\n  botId: String!\n  markdown: String!\n  instructionCount: Int!\n  noteCount: Int!\n  changes: [BotMemoryChange!]!\n  origin: BotOrigin!\n}
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
  type BotMemoryChangeEntry {\n  recordId: Int!\n  op: String!\n  fromVersion: Int\n  toVersion: Int!\n}
  input UpdateBotMemoryInput {\n  botId: String!\n  markdown: String!\n  reason: String\n  remote: String\n}
  input UndoBotMemoryChangeInput {\n  botId: String!\n  changeId: String\n  remote: String\n}
  input CaptureBotFeedbackInput {\n  botId: String!\n  sessionId: String\n  taskId: String\n  text: String\n  topic: String\n  fromFindings: Boolean\n  remote: String\n}
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
  type BotSuggestionListPayload {\n  botId: String!\n  suggestions: [BotSuggestion!]!\n  origin: BotOrigin!\n}
  type BotSuggestionPayload {\n  suggestion: BotSuggestion!\n  origin: BotOrigin!\n}
  type BotJobSummary {\n  job: String!\n  schedule: String!\n  lastRun: BotJobRun\n}
  type BotJobHistoryPayload {\n  runs: [BotJobRun!]!\n  origin: BotOrigin!\n}
  type BotJobRun {\n  botId: String!\n  job: String!\n  periodKey: String!\n  status: String!\n  sessionId: String\n  detail: String\n  startedAt: String!\n  finishedAt: String\n}
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
  input DecideBotSuggestionInput {\n  suggestionId: String!\n  decision: String!\n  run: Boolean\n  reason: String\n  remote: String\n}
  input RunBotJobInput {\n  botId: String!\n  job: String!\n  force: Boolean\n  remote: String\n}
  type CatalogModel {\n  id: String!\n  label: String\n  sources: [String!]!\n  reasoningEfforts: [String!]!\n  serviceTiers: [String!]!\n  modes: [String!]!\n  observedAt: String\n  origin: BotOrigin\n}
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
  type PairingGrant {\n  grantId: String!\n  clientName: String!\n  scope: String!\n  createdAt: String!\n  lastUsedAt: String\n  revokedAt: String\n}
  type PairingGrantListPayload {\n  grants: [PairingGrant!]!\n}
  type PairingCodePayload {\n  code: String!\n  expiresAt: String!\n  address: String!\n  scope: String!\n}
  input MintPairingCodeInput {\n  address: String!\n  scope: String\n}
  input RevokePairingGrantInput {\n  grantId: String!\n}
  type RemoteSummary {\n  name: String!\n  address: String!\n  serverName: String!\n  scope: String!\n  lastSeenAt: String\n  connection: String!\n}
  type RemoteListPayload {\n  active: String!\n  remotes: [RemoteSummary!]!\n}
  input AddRemoteInput {\n  name: String!\n  code: String!\n  clientName: String\n}
  input RemoveRemoteInput {\n  name: String!\n}
  input UseRemoteInput {\n  name: String!\n}
  input StartAskInput {\n  message: String!\n  context: AskContextInput\n  selection: AskSelectionInput\n  draftDefinition: JSON\n  remote: String\n}
  input SendAskMessageInput {\n  conversationId: String!\n  message: String!\n  context: AskContextInput\n  draftDefinition: JSON\n  remote: String\n}
  input AskActionInput {\n  conversationId: String!\n  actionId: String!\n  remote: String\n}
  input AskConversationInput {\n  conversationId: String!\n  remote: String\n}
  input AskContextInput {\n  kind: String!\n  id: String\n}
  input AskSelectionInput {\n  vendor: String\n  providerInstanceId: String\n  model: String\n  effort: String\n}
  type AskContext {\n  kind: String!\n  id: String\n}
  type AskSelection {\n  vendor: String\n  providerInstanceId: String\n  model: String\n  effort: String\n}
  type AskConversation {\n  conversationId: String!\n  title: String!\n  context: AskContext!\n  selection: AskSelection!\n  turn: AskTurn\n  usage: AskUsage!\n  createdAt: String!\n  updatedAt: String!\n}
  type AskTurn {
    turnId: String!
    status: String!
    startedAt: String!
    finishedAt: String
    backend: String!
    providerInstanceId: String!
    model: String
    toolTransport: String!
    limitedPolicy: Boolean!
    error: AskTurnError
    runnerId: String!
    heartbeatAt: String!
    toolCalls: Int!
    toolBytes: Int!
  }
  type AskTurnError {\n  code: String!\n  message: String!\n}
  type AskUsage {\n  turns: Int!\n  toolCalls: Int!\n  toolBytes: Int!\n}
  type AskMessage {\n  seq: Int!\n  role: String!\n  text: String!\n  turnId: String!\n  citations: [AskRef!]!\n  truncated: Boolean!\n  createdAt: String!\n}
  type AskRef {\n  kind: String!\n  id: String!\n  sessionId: String\n}
  type AskAction {
    actionId: String!
    conversationId: String!
    turnId: String!
    kind: String!
    target: JSON!
    reason: String!
    status: String!
    createdAt: String!
    expiresAt: String!
    decidedAt: String
    decision: String
    decidedBy: String
    result: AskActionResult
  }
  type AskActionResult {\n  ok: Boolean!\n  summary: String\n  ids: [String!]!\n  code: String\n  message: String\n}
  type AskLimits {
    userMessageBytes: Int!
    assistantMessageBytes: Int!
    messagesPerConversation: Int!
    conversationsPerStore: Int!
    historyMessages: Int!
    historyMessageCharacters: Int!
    turnsPerConversation: Int!
    toolCallsPerTurn: Int!
    toolCallsPerConversation: Int!
    toolResultBytes: Int!
    toolBytesPerTurn: Int!
    toolBytesPerConversation: Int!
    roundsPerTurn: Int!
    turnDeadlineSeconds: Int!
    draftDefinitionBytes: Int!
    actionsPerTurn: Int!
    actionLifetimeSeconds: Int!
    contextSummaryBytes: Int!
  }
  type AskConversationPayload {\n  conversation: AskConversation!\n  messages: [AskMessage!]!\n  actions: [AskAction!]!\n  limits: AskLimits!\n  warnings: [String!]!\n  origin: BotOrigin!\n}
  type AskConversationListPayload {\n  conversations: [AskConversation!]!\n  origin: BotOrigin!\n}
  type AskActivityPage {
    events: [BotActivityEvent!]!
    state: BotActivityState
    lastSequence: Int!
    firstRetainedSequence: Int!
    truncated: Boolean!
    activitySource: String!
    turnStatus: String!
    origin: BotOrigin!
  }
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
  type ExecuteWorkflowPayload {\n  workflowExecutionId: String!\n  sessionId: String!\n  status: String!\n  exitCode: Int!\n}
  type WorkflowExecutionSummary {\n  session: WorkflowExecutionSessionSummary!\n  nodeExecutions: [WorkflowExecutionNodeSummary!]!\n}
  type WorkflowExecutionSessionSummary {\n  sessionId: String!\n  workflowName: String!\n  workflowId: String!\n  transitions: [WorkflowExecutionTransitionSummary!]!\n}
  type WorkflowExecutionTransitionSummary {\n  when: String\n}
  type WorkflowExecutionNodeSummary {\n  nodeExecId: String!\n}
  type ControlPlaneResult {\n  accepted: Boolean!\n  status: String!\n  diagnostics: [String!]!\n}
  type ManagerIntentSummary {\n  kind: String!\n  targetId: String\n  reason: String\n}
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
  type ReplayCommunicationPayload {\n  sourceCommunicationId: String!\n  workflowExecutionId: String!\n  replayedCommunicationId: String!\n  status: String!\n}
  type RetryCommunicationDeliveryPayload {\n  communicationId: String!\n  activeDeliveryAttemptId: String!\n  status: String!\n}
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
  type LoopFindingSeverityCounts {\n  high: Int!\n  medium: Int!\n  low: Int!\n  informational: Int!\n}
  type LoopBlockingFinding {\n  id: String!\n  severity: String!\n  filePath: String\n  line: Int\n  message: String!\n  evidenceRefs: [String!]!\n}
  type LoopResidualRisk {\n  severity: String!\n  message: String!\n  evidenceRefs: [String!]!\n  owner: String\n  accepted: Boolean!\n}
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
  type SessionBackendActivityEvidence {\n  kind: String!\n  detail: String!\n  path: String\n  observedAt: String\n  ageMs: Int\n}
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
  type SessionObservabilityView {\n  root: SessionRollupNode!\n  backendActivity: SessionBackendActivity\n  rollupTruncated: Boolean\n  rollupSnapshotLimit: Int\n}
  type SessionObservabilityPayload {\n  result: ControlPlaneResult!\n  view: SessionObservabilityView\n}
  type WorkflowInstance {\n  identity: String!\n  workflowId: String!\n  sourceIdentity: String\n  displayName: String\n  configuration: JSONObject!\n}
  type WorkflowInstanceQueryPayload {\n  result: ControlPlaneResult!\n  value: WorkflowInstance\n}
  type WorkflowInstancesQueryPayload {\n  result: ControlPlaneResult!\n  value: [WorkflowInstance!]\n}
  type WorkflowInstanceMutationPayload {\n  result: ControlPlaneResult!\n  instance: WorkflowInstance\n}
  type StepExecution {\n  executionId: String!\n  stepId: String!\n  nodeId: String!\n  attempt: Int!\n  backend: String\n  status: String!\n  failureReason: String\n}
  type Communication {\n  communicationId: String!\n  fromStepId: String\n  toStepId: String\n  lifecycleStatus: String!\n  deliveryKind: String!\n  createdOrder: Int!\n}
  type HookEvent {\n  vendor: String!\n  eventName: String!\n  agentSessionId: String!\n  payloadHash: String\n}
  type EventReceipt {\n  sourceId: String!\n  eventId: String!\n  status: String!\n}
  type ReplyDispatch {\n  sourceId: String!\n  provider: String!\n  payload: JSONObject!\n}
  type LogEntry {\n  level: String!\n  message: String!\n}
  type LLMSessionMessage {\n  role: String!\n  content: String!\n}
  input ContinueSessionInput {\n  workflowId: String!\n  sessionId: String!\n  input: JSONObject!\n}
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
  input ReplayCommunicationInput {\n  workflowId: String!\n  workflowExecutionId: String!\n  communicationId: String!\n  reason: String\n  idempotencyKey: String\n  managerSessionId: String\n}
  input RetryCommunicationDeliveryInput {\n  workflowId: String!\n  workflowExecutionId: String!\n  communicationId: String!\n  reason: String\n  idempotencyKey: String\n  managerSessionId: String\n}
  input WorkflowInstanceInput {\n  identity: String!\n  workflowId: String!\n  sourceIdentity: String\n  displayName: String\n  configuration: JSONObject\n}
  type LoopCostSummary {\n  totalInputTokens: Int\n  totalOutputTokens: Int\n  totalTokens: Int\n  totalDurationMs: Int\n  stepsWithUsage: Int!\n  stepsWithoutUsage: Int!\n  partial: Boolean!\n}
  type LoopCostSummaryDelta {\n  totalInputTokensDelta: Int\n  totalOutputTokensDelta: Int\n  totalTokensDelta: Int\n  totalDurationMsDelta: Int\n}
  type LoopGateOutcome {\n  gateId: String!\n  stepId: String!\n  decision: String!\n  required: Boolean\n  blockingFindingCount: Int!\n}
  type LoopGateFailureCount {\n  gateId: String!\n  count: Int!\n}
  type LoopGateChange {\n  gateId: String!\n  baseDecision: String\n  targetDecision: String\n  severityCountsDelta: LoopFindingSeverityCounts!\n}
  type LoopVerificationChange {\n  commandSummary: String!\n  baseOutcome: String\n  targetOutcome: String\n}
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
  input RerunSessionInput {\n  workflowId: String!\n  sessionId: String!\n  stepId: String!\n  managerSessionId: String\n}
  input ResumeSessionInput {\n  workflowId: String!\n  sessionId: String!\n  managerSessionId: String\n}
  input StopSessionInput {\n  workflowId: String!\n  sessionId: String!\n  reason: String\n  managerSessionId: String\n}
  type SessionLineage {\n  sessionId: String!\n  parentSessionId: String\n  rootSessionId: String!\n  entryMode: String!\n  sourceStepId: String\n}
  type SessionMutationPayload {\n  result: ControlPlaneResult!\n  sessionId: String\n  status: String\n  lineage: SessionLineage\n}
  type ConsoleInstanceEnvironmentVariable {\n  name: String!\n  isSet: Boolean!\n  masked: String!\n}
  type ConsoleInstanceRequiredEnvironment {\n  name: String!\n  description: String\n  required: Boolean!\n  secret: Boolean!\n  source: String!\n  present: Boolean!\n}
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
  type ConsoleInstanceListPayload {\n  profile: String!\n  revision: Int!\n  items: [ConsoleInstance!]!\n}
  type ConsoleInstancePayload {\n  profile: String!\n  revision: Int!\n  item: ConsoleInstance\n}
  type OpsOverviewTransition {\n  toStepId: String!\n  label: String\n  fanoutJoinStepId: String\n}
  type OpsOverviewStep {\n  id: String!\n  nodeId: String!\n  role: String\n  description: String\n  transitions: [OpsOverviewTransition!]!\n}
  type OpsOverviewNode {\n  id: String!\n  kind: String\n  role: String\n  addon: String\n}
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
  type OpsOverviewInstance {\n  id: String!\n  sourceId: String!\n  isDefault: Boolean!\n  name: String!\n  workflowId: String!\n  status: String!\n  active: Boolean!\n}
  type OpsOverviewRun {\n  instanceId: String!\n  sessionId: String!\n  workflowId: String!\n  status: String!\n  currentStepId: String\n  activeStepIds: [String!]!\n  updatedAt: String!\n}
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
    askConversations(remote: String): AskConversationListPayload!
    askConversation(conversationId: String!, remote: String): AskConversationPayload!
    askActivity(conversationId: String!, afterSequence: Int = 0, limit: Int = 200, waitMs: Int = 0, remote: String): AskActivityPage!
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
    startAsk(input: StartAskInput!): AskConversationPayload!
    sendAskMessage(input: SendAskMessageInput!): AskConversationPayload!
    cancelAsk(input: AskConversationInput!): AskConversationPayload!
    confirmAskAction(input: AskActionInput!): AskConversationPayload!
    dismissAskAction(input: AskActionInput!): AskConversationPayload!
    removeAskConversation(input: AskConversationInput!): AskConversationListPayload!
  }
  """
}
