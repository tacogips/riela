export interface Bot {
  botId: string
  name: string
  paused: boolean
  defaultBackend?: string | null
  defaultModel?: string | null
}

export interface BotCounts {
  needsYou: number
  working: number
  waiting: number
  planned: number
}

export interface BotOrigin {
  remote: string
  serverName?: string | null
  serverId?: string | null
  verified: boolean
  connection: string
  observedAt: string
}

export interface BotListState {
  pinned: boolean
  snoozedUntil?: string | null
  settledAt?: string | null
  settledBy?: string | null
}

export type BotSection = 'active' | 'working' | 'snoozed' | 'settled' | 'disconnected'
export type BotGrouping = 'none' | 'workspace'
export type BotBoardGroup = 'needsYou' | 'inProgress' | 'waiting' | 'planned' | 'closed'

export interface BotWorkSummary {
  title: string
  workflowId?: string | null
  stepId?: string | null
  nodeId?: string | null
  backend?: string | null
  model?: string | null
  elapsedMs?: number | null
}

export interface BotPlan {
  planId: string
  entries: { content: string; status: string }[]
}

export interface BotPendingRequest {
  requestId: string
  title?: string | null
  options: { optionId: string; name: string }[]
}

export interface BotBoardItem extends BotWorkSummary {
  itemKind: string
  itemId: string
  status: string
  waitingReason?: string | null
  limitedResetAt?: string | null
  activitySource: string
  doingNow?: string | null
  checklist: BotPlan[]
  pendingRequests: BotPendingRequest[]
  answerPath?: 'bot' | 'task' | null
  question?: { text: string } | null
  lastResult?: string | null
  sessionId?: string | null
  listState: BotListState
}

export interface BotOverviewRow {
  bot: Bot
  counts: BotCounts
  inProgress: BotWorkSummary[]
  lastActivityAt?: string | null
  lastResult?: string | null
  listState: BotListState
  section: BotSection
  workspaceGroup: string
  origin: BotOrigin
}

export interface BotListPayload {
  origin?: BotOrigin | null
  bots: BotOverviewRow[]
  groups: { key: string; needsYou: boolean; botIds: string[] }[]
}

export interface BotDetailPayload {
  bot: Bot
  origin: BotOrigin
  jobs: BotJobSummary[]
  board: Record<BotBoardGroup, BotBoardItem[]> & { closedTotal: number }
  routines: { routineId: string; name: string; status: string; nextRunAt?: string | null }[]
}

export interface BotActivityEvent {
  seq: number
  at: string
  kind: string
  payload: Record<string, unknown>
}

export interface BotActivityState {
  currentExecutionId?: string | null
  currentStepId?: string | null
  plans: BotPlan[]
  toolCalls: { toolCallId: string; title?: string | null; status?: string | null }[]
  pendingRequestIds: string[]
  lastMessageLine?: string | null
}

export interface BotActivityPage {
  origin: BotOrigin
  events: BotActivityEvent[]
  state?: BotActivityState | null
  lastSequence: number
  truncated: boolean
  sessionStatus: string
  activitySource: string
}

interface BotFields {
  purpose?: string
  personaId?: string
  defaultBackend?: string
  defaultModel?: string
  providerInstanceId?: string
  workspace?: string
  memoryUpkeep?: string
  lookAround?: string
  permissionWaitMs?: number
}

export type CreateBotInput = BotFields & { id?: string; name: string }
export type UpdateBotInput = BotFields & { botId: string; name?: string }
export interface SetBotListStateInput {
  botId: string
  itemKind?: string
  itemId?: string
  pinned?: boolean
  manualOrder?: number
  snoozedUntil?: string
  clearSnooze?: boolean
  settled?: boolean
}

export type AnswerBotRequestInput = { requestId: string } & (
  { optionId: string; decline?: never } | { optionId?: never; decline: true }
)

export interface BotMemoryChange {
  changeId: string
  actor: string
  reason: string
  createdAt: string
}

export interface BotMemory {
  markdown: string
  changes: BotMemoryChange[]
  origin: BotOrigin
}

export interface BotSuggestion {
  suggestionId: string
  title: string
  detail?: string | null
  action?: { workflowName: string } | null
  origin?: BotOrigin | null
}

export interface BotJobSummary {
  job: string
  schedule: string
  lastRun?: { status: string; startedAt: string; detail?: string | null } | null
}

export interface RemoteSummary {
  name: string
  serverName: string
  address: string
  connection: string
  lastSeenAt?: string | null
}

export interface RemoteList {
  active: string
  remotes: RemoteSummary[]
}
