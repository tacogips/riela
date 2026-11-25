import type { BotActivityPage, BotOrigin } from '../bots/contracts'
import type { GraphDocument } from '../workflows/graph'

export type AskContext = { kind: 'none' } | { kind: 'session' | 'bot' | 'workflow'; id: string }

export interface AskSelection {
  vendor?: string | null
  providerInstanceId?: string | null
  model?: string | null
  effort?: string | null
}

export interface AskTurn {
  turnId: string
  status: 'running' | 'completed' | 'failed' | 'cancelled'
  backend: string
  providerInstanceId: string
  model?: string | null
  toolTransport: 'mcp' | 'rounds'
  limitedPolicy: boolean
  error?: { code: string; message: string } | null
}

export interface AskConversation {
  conversationId: string
  title: string
  context: AskContext
  selection: AskSelection
  turn?: AskTurn | null
}

export interface AskRef {
  kind: 'session' | 'step' | 'bot' | 'workflow' | 'routine'
  id: string
  sessionId?: string | null
}

export interface AskMessage {
  seq: number
  role: 'user' | 'assistant'
  text: string
  turnId: string
  citations: AskRef[]
}

interface AskActionBase {
  actionId: string
  turnId: string
  status: 'proposed' | 'confirming' | 'confirmed' | 'failed' | 'dismissed'
  reason: string
  expiresAt: string
  result?: { ok: boolean; summary?: string | null; code?: string | null } | null
}

export type AskAction = AskActionBase & (
  | { kind: 'stopSession' | 'rerunSession'; target: { sessionId: string } }
  | { kind: 'answerBotRequest'; target: { requestId: string; optionId?: string; decline?: boolean } }
  | { kind: 'setBotPaused'; target: { botId: string; paused: boolean } }
  | { kind: 'applyWorkflow'; target: {
    mode: 'draft' | 'store'
    workflowId: string
    baseWorkflowId?: string
    expectedDefinitionRevision?: string
    definition: GraphDocument
  } }
)

export interface AskLimits {
  userMessageBytes: number
  assistantMessageBytes: number
  messagesPerConversation: number
  conversationsPerStore: number
  historyMessages: number
  historyMessageCharacters: number
  turnsPerConversation: number
  toolCallsPerTurn: number
  toolCallsPerConversation: number
  toolResultBytes: number
  toolBytesPerTurn: number
  toolBytesPerConversation: number
  roundsPerTurn: number
  turnDeadlineSeconds: number
  draftDefinitionBytes: number
  actionsPerTurn: number
  actionLifetimeSeconds: number
  contextSummaryBytes: number
}

export interface AskSnapshot {
  conversation: AskConversation
  messages: AskMessage[]
  actions: AskAction[]
  limits: AskLimits
  warnings: string[]
  origin: BotOrigin
}

export interface AskList {
  conversations: AskConversation[]
  origin: BotOrigin
}

export interface AskMessageInput {
  message: string
  context: AskContext
  draftDefinition?: GraphDocument
  remote?: string
}

export interface AskActivityPage extends Omit<BotActivityPage, 'sessionStatus'> {
  turnStatus: string
  firstRetainedSequence: number
}
