import { describe, expect, test } from 'bun:test'
import { parseViewHash, viewHash, type HashRoute } from './routes'

describe('hash route parsing', () => {
  test('keeps the published run-link contract', () => {
    expect(parseViewHash('#/runs/session-1')).toEqual({ view: 'run-detail', sessionId: 'session-1' })
    expect(parseViewHash(`#/runs/${encodeURIComponent('feature/x session')}`))
      .toEqual({ view: 'run-detail', sessionId: 'feature/x session' })
  })

  test('parses navigation views and the command deck', () => {
    for (const view of ['instances', 'logs', 'workflows', 'ops', 'bots', 'models', 'settings'] as const) {
      expect(parseViewHash(`#/${view}`)).toEqual({ view })
    }
  })

  test('parses ops runs with encoded composite identifiers', () => {
    const instanceId = 'project-workflow:/tmp/riela:review-loop'
    const hash = viewHash({ view: 'ops-run', instanceId, sessionId: 'session-aurora-042' })
    expect(hash).toBe(`#/ops/runs/${encodeURIComponent(instanceId)}/session-aurora-042`)
    expect(parseViewHash(hash)).toEqual({ view: 'ops-run', instanceId, sessionId: 'session-aurora-042' })
  })

  test('allows an empty instance for private ops runs', () => {
    expect(parseViewHash('#/ops/runs//session-9'))
      .toEqual({ view: 'ops-run', instanceId: '', sessionId: 'session-9' })
  })

  test('parses and round-trips the Bots list and detail links', () => {
    expect(viewHash({ view: 'bots' })).toBe('#/bots')
    expect(parseViewHash('#/bots/release-bot')).toEqual({ view: 'bot-detail', botId: 'release-bot' })
    const detail = { view: 'bot-detail', botId: 'release/bot' } as const
    expect(viewHash(detail)).toBe('#/bots/release%2Fbot')
    expect(parseViewHash(viewHash(detail))).toEqual(detail)
    expect(parseViewHash('#/bots/')).toBeUndefined()
    expect(parseViewHash('#/bots/release/bot')).toBeUndefined()
  })

  test('rejects malformed or unknown hashes', () => {
    for (const hash of ['', '#', '#/', '#/unknown', '#/runs', '#/runs/', '#/ops/runs/only-three', '#/runs/a/b', '#/runs/%ZZ', 'runs/x']) {
      expect(parseViewHash(hash)).toBeUndefined()
    }
  })

  test('round-trips every route shape', () => {
    const routes: HashRoute[] = [
      { view: 'instances' },
      { view: 'workflow-detail', sourceId: 'profile-workflow:/a/b:日本語' },
      { view: 'workflow-detail', sourceId: 'project:/a:review', configurationId: '日本語/a', tab: 'history' },
      { view: 'ops' },
      { view: 'run-detail', sessionId: 'session with spaces' },
      { view: 'run-detail', sourceId: 'source/a', configurationId: 'config/b', sessionId: 'run/c' },
      { view: 'ops-run', instanceId: 'a/b:c', sessionId: 's/1' },
    ]
    for (const route of routes) {
      expect(parseViewHash(viewHash(route))).toEqual(route)
    }
  })
})

test('preserves host identity for paired routes with overlapping ids', () => {
  const bot = { view: 'bot-detail', botId: 'report/a', remote: 'office' } as const
  const run = { view: 'run-detail', sessionId: 'run/a', remote: 'office' } as const
  expect(viewHash(bot)).toBe('#/bots/report%2Fa?remote=office')
  expect(viewHash(run)).toBe('#/runs/run%2Fa?remote=office')
  expect(parseViewHash(viewHash(bot))).toEqual(bot)
  expect(parseViewHash(viewHash(run))).toEqual(run)
})

test('keeps the explicit local origin on record links', () => {
  const bot = { view: 'bot-detail', botId: 'b1', remote: 'local' } as const
  const run = { view: 'run-detail', sessionId: 's1', remote: 'local' } as const
  expect(parseViewHash(viewHash(bot))).toEqual(bot)
  expect(parseViewHash(viewHash(run))).toEqual(run)
})
