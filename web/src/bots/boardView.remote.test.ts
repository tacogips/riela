import { expect, test } from 'bun:test'
import { parseViewHash } from '../routes'
import { boardRunHash, overviewPresentation } from './boardView'
import type { BotOverviewRow } from './contracts'

const observedAt = '2026-11-25T00:00:00Z'
const row: BotOverviewRow = {
  bot: { botId: 'bot', name: 'Bot', paused: false },
  counts: { needsYou: 1, working: 2, waiting: 0, planned: 0 },
  inProgress: [], listState: { pinned: false }, section: 'active', workspaceGroup: 'ungrouped',
  lastResult: 'Last result',
  origin: { remote: 'srv', connection: 'connected', verified: true, observedAt },
}

test('replaces cached counts and last result with the disconnected timestamp', () => {
  const disconnected = { ...row, origin: { ...row.origin, connection: 'disconnected' } }
  expect(overviewPresentation(disconnected, Date.parse(observedAt) + 120_000)).toEqual({
    section: 'disconnected', label: 'last seen 2 minutes ago', actionsEnabled: false,
  })
})

test('disables actions when the origin is unverified', () => {
  expect(overviewPresentation({ ...row, origin: { ...row.origin, verified: false } }).actionsEnabled).toBe(false)
  expect(overviewPresentation(row).actionsEnabled).toBe(true)
})

test('links in-progress, needs-you, and waiting sessions to the workflow run route', () => {
  for (const group of ['inProgress', 'needsYou', 'waiting'] as const) {
    const hash = boardRunHash(group, { sessionId: 'run/1' })
    expect(hash).toBe('#/runs/run%2F1')
    expect(parseViewHash(hash!)).toEqual({ view: 'run-detail', sessionId: 'run/1' })
  }
  expect(boardRunHash('waiting', { sessionId: 'run/1' }, 'srv')).toBe('#/runs/run%2F1?remote=srv')
  expect(boardRunHash('inProgress', { sessionId: null })).toBeUndefined()
  expect(boardRunHash('closed', { sessionId: 'run/1' })).toBeUndefined()
})
