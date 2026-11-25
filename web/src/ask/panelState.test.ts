import { expect, test } from 'bun:test'
import type { ActivityFeed } from '../bots/activityFeed'
import type { AskMessage, AskSnapshot, AskTurn } from './contracts'
import { panelState } from './panelState'

const turn: AskTurn = {
  turnId: 't1', backend: 'codex-agent', providerInstanceId: 'codex-agent',
  status: 'running', toolTransport: 'mcp', limitedPolicy: false,
}
const prompt: AskMessage = { seq: 1, role: 'user', text: 'Status?', turnId: 't1', citations: [] }
const snapshot: AskSnapshot = {
  conversation: { conversationId: 'c1', title: 'Run', context: { kind: 'none' }, selection: {}, turn },
  messages: [prompt],
  limits: {
    userMessageBytes: 4096, assistantMessageBytes: 4096, messagesPerConversation: 100,
    conversationsPerStore: 100, historyMessages: 20, historyMessageCharacters: 2048, turnsPerConversation: 50,
    toolCallsPerTurn: 10, toolCallsPerConversation: 50, toolResultBytes: 4096, toolBytesPerTurn: 16384,
    toolBytesPerConversation: 65536, roundsPerTurn: 4, turnDeadlineSeconds: 120, draftDefinitionBytes: 32768,
    actionsPerTurn: 4, actionLifetimeSeconds: 86400, contextSummaryBytes: 4096,
  },
  actions: [], warnings: [], origin: { remote: 'local', verified: true, connection: 'connected', observedAt: '' },
}
const feed: ActivityFeed = {
  activitySource: 'acp', lastSequence: 4, truncated: false, sessionStatus: 'running',
  events: [
    { seq: 1, at: '', executionId: 'earlier', kind: 'message', payload: { text: 'Previous turn' } },
    { seq: 2, at: '', executionId: 't1', kind: 'message', payload: { messageId: 'm1', text: 'Running' } },
    { seq: 3, at: '', executionId: 't1', kind: 'message', payload: { messageId: 'm1', text: ' now.' } },
    { seq: 4, at: '', executionId: 't1', kind: 'thought', payload: { text: 'Check the run.' } },
  ],
  state: {
    currentExecutionId: 't1', pendingRequestIds: [],
    toolCalls: [{ toolCallId: 'call1', title: 'session_status', status: 'completed' }],
    plans: [{ planId: 'p1', entries: [{ content: 'Inspect', status: 'completed' }] }],
    usage: { used: 100, size: 200 },
  },
}
test('projects only the current turn while running and replaces activity with the stored answer', () => {
  expect(panelState({ snapshot, feed })).toEqual({ running: true, canSend: false, items: [
    { kind: 'stored', message: prompt },
    { kind: 'answer', text: 'Running now.' },
    { kind: 'thought', text: 'Check the run.' },
    { kind: 'tool', text: 'session_status · completed' },
    { kind: 'plan', text: 'Inspect · completed' },
    { kind: 'usage', text: 'Tokens · 100 used · 200 limit' },
  ] })
  const settled: AskSnapshot = {
    ...snapshot,
    conversation: { ...snapshot.conversation, turn: { ...turn, status: 'completed' } },
    messages: [...snapshot.messages, { seq: 2, role: 'assistant', text: 'Still running.', turnId: 't1', citations: [] }],
  }
  expect(panelState({ snapshot: settled, feed })).toEqual({
    running: false, canSend: true, items: settled.messages.map((message) => ({ kind: 'stored', message })),
  })
})

test('shows the turn error without displaying live answer text on failure', () => {
  const failed: AskSnapshot = { ...snapshot, conversation: { ...snapshot.conversation,
    turn: { ...turn, status: 'failed', error: { code: 'ask_timeout', message: 'Deadline' } },
  } }
  expect(panelState({ snapshot: failed, feed }).items).toEqual([
    { kind: 'stored', message: prompt }, { kind: 'error', text: 'ask_timeout · Deadline' },
  ])
})
