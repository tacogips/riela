import { expect, test } from 'bun:test'
import { actionCard } from './actions'
import type { AskAction } from './contracts'

const action: AskAction = {
  actionId: 'a1', turnId: 't1', kind: 'setBotPaused', target: { botId: 'b1', paused: true },
  status: 'proposed', expiresAt: '2026-11-26T00:00:00Z', reason: '[plain](https://example.test)',
}
const now = Date.parse('2026-11-25T00:00:00Z')

test('uses typed targets for titles and leaves reasons as plain text', () => {
  expect(actionCard(action, now)).toEqual({
    title: 'Pause bot b1', detail: '[plain](https://example.test)', state: 'proposed', canDecide: true,
  })
})

test('confirmed and expired actions cannot be decided again', () => {
  expect(actionCard({ ...action, status: 'confirmed', result: { ok: true, summary: 'Paused' } }, now))
    .toMatchObject({ state: 'Paused', canDecide: false })
  expect(actionCard(action, Date.parse(action.expiresAt))).toMatchObject({ state: 'expired', canDecide: false })
})
