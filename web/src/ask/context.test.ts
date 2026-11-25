import { expect, test } from 'bun:test'
import { contextFromRoute } from './context'

test('run context carries the route remote ahead of the selected remote', () => {
  expect(contextFromRoute({ view: 'run-detail', sessionId: 's1', remote: 'server' }, { remote: 'other' }))
    .toEqual({ context: { kind: 'session', id: 's1' }, label: 'Run s1', remote: 'server' })
  expect(contextFromRoute({ view: 'ops-run', instanceId: 'i1', sessionId: 's2' }).context)
    .toEqual({ kind: 'session', id: 's2' })
})

test('uses known names and resolves workflow source IDs without sending source content', () => {
  expect(contextFromRoute({ view: 'bot-detail', botId: 'b1' }, { remote: 'pair', botName: () => 'Release' }))
    .toEqual({ context: { kind: 'bot', id: 'b1' }, label: 'Bot Release', remote: 'pair' })
  const workflow = { view: 'workflow-detail', sourceId: 'opaque-source' } as const
  expect(contextFromRoute(workflow, { workflowId: () => 'release' }).context).toEqual({ kind: 'workflow', id: 'release' })
  expect(contextFromRoute(workflow).context).toEqual({ kind: 'none' })
  expect(contextFromRoute({ view: 'settings' }, { remote: '*' })).toEqual({ context: { kind: 'none' }, label: '', remote: 'local' })
})
