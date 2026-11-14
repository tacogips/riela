import { describe, expect, test } from 'bun:test'
import { parseViewHash, viewHash, type HashRoute } from './routes'

describe('hash route parsing', () => {
  test('keeps the published run-link contract', () => {
    expect(parseViewHash('#/runs/session-1')).toEqual({ view: 'run-detail', sessionId: 'session-1' })
    expect(parseViewHash(`#/runs/${encodeURIComponent('feature/x session')}`))
      .toEqual({ view: 'run-detail', sessionId: 'feature/x session' })
  })

  test('parses navigation views and the command deck', () => {
    for (const view of ['instances', 'logs', 'workflows', 'ops', 'settings'] as const) {
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

  test('rejects malformed or unknown hashes', () => {
    for (const hash of ['', '#', '#/', '#/unknown', '#/runs', '#/runs/', '#/ops/runs/only-three', '#/runs/a/b', '#/runs/%ZZ', 'runs/x']) {
      expect(parseViewHash(hash)).toBeUndefined()
    }
  })

  test('round-trips every route shape', () => {
    const routes: HashRoute[] = [
      { view: 'instances' },
      { view: 'ops' },
      { view: 'run-detail', sessionId: 'session with spaces' },
      { view: 'ops-run', instanceId: 'a/b:c', sessionId: 's/1' },
    ]
    for (const route of routes) {
      expect(parseViewHash(viewHash(route))).toEqual(route)
    }
  })
})
