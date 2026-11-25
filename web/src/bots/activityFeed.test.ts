import { expect, test } from 'bun:test'
import { activitySummary, mergeActivityPage, nextCursor } from './activityFeed'
import type { BotActivityPage, BotActivityState } from './contracts'

const state: BotActivityState = {
  currentExecutionId: 'execution', currentStepId: 'review', plans: [],
  toolCalls: [], pendingRequestIds: [], lastMessageLine: null,
}

function page(sequences: number[], overrides: Partial<BotActivityPage> = {}): BotActivityPage {
  return {
    events: sequences.map((seq) => ({ seq, kind: 'message', at: '2026-11-25T00:00:00Z', payload: { text: 'Working' } })),
    state, lastSequence: sequences.at(-1) ?? 0, truncated: false, sessionStatus: 'running',
    activitySource: 'acp', origin: { remote: 'local', verified: true, connection: 'connected', observedAt: '2026-11-25T00:00:00Z' }, ...overrides,
  }
}

test('appends consecutive pages and advances the cursor', () => {
  const feed = mergeActivityPage(mergeActivityPage(undefined, page([1, 2])), page([3, 4]))
  expect(feed.events.map((event) => event.seq)).toEqual([1, 2, 3, 4])
  expect(nextCursor(feed)).toBe(4)
})

test('drops duplicate sequences without losing the replacement state', () => {
  const nextState = { ...state, currentStepId: 'report' }
  const feed = mergeActivityPage(mergeActivityPage(undefined, page([1, 2])), page([2, 3, 3], { state: nextState }))
  expect(feed.events.map((event) => event.seq)).toEqual([1, 2, 3])
  expect(feed.state).toEqual(nextState)
  expect(nextCursor(feed)).toBe(3)
})

test('replaces the feed with retained events and state after truncation', () => {
  const nextState = { ...state, pendingRequestIds: ['request'] }
  const feed = mergeActivityPage(mergeActivityPage(undefined, page([1, 2])), page([9, 10], { state: nextState, truncated: true }))
  expect(feed.events.map((event) => event.seq)).toEqual([9, 10])
  expect(feed.state).toEqual(nextState)
  expect(nextCursor(feed)).toBe(10)
  expect(mergeActivityPage(feed, page([11])).truncated).toBe(true)
})

test('normalizes an activity label to one line', () => {
  expect(activitySummary({
    ...page([1]).events[0]!,
    kind: 'toolCall',
    payload: { title: 'Read\n status' },
  })).toBe('tool call: Read status')
})
