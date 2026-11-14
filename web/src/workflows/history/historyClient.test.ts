import { describe, expect, test } from 'bun:test'
import { APIError } from '../../api'
import { WorkflowHistoryClient } from './historyClient'

function harness(data: unknown, errors?: unknown[]) {
  const calls: { operationName: string; variables: unknown; query: string }[] = []
  const client = new WorkflowHistoryClient({
    appHeaders: () => ({ 'X-Test': 'yes' }),
    request: async (_input, init) => {
      calls.push(JSON.parse(String(init?.body)))
      return new Response(JSON.stringify({ data, errors }), { status: 200 })
    },
  })
  return { client, calls }
}
describe('workflow history client', () => {
  test('sends definition query and mutation variables with CAS', async () => {
    const { client, calls } = harness({ workflowDefinitionHistory: [], workflowDefinition: { versionId: 'head', revision: 2 }, workflowDefinitionDiff: [] })
    await client.history('flow'); await client.head('flow'); await client.diff('flow', 'old', 'head')
    await client.restore('flow', 'old', 'because', 'head'); await client.undo('flow', 'undo', 'head')
    expect(calls.map(call => call.operationName)).toEqual(['WorkflowHistory', 'WorkflowHead', 'WorkflowDiff', 'RestoreDefinition', 'UndoDefinition'])
    expect(calls[0]!.query).toContain('limit: 50')
    expect(calls[2]!.variables).toEqual({ workflowName: 'flow', fromVersionId: 'old', toVersionId: 'head' })
    expect(calls[3]!.variables).toEqual({ input: { workflowName: 'flow', versionId: 'old', reason: 'because', expectedVersionId: 'head' } })
    expect(calls[4]!.variables).toEqual({ input: { workflowName: 'flow', reason: 'undo', expectedVersionId: 'head' } })
  })
  test('maps pending regressions and sends proposal decisions', async () => {
    const proposal = { proposalId: 'p', regressedVersionId: 'v2', rollbackToVersionId: 'v1', baselineSessionId: 's1', targetSessionId: 's2', policy: 'approval-required', regressions: [{ kind: 'gate', gateId: 'g', detail: 'worse' }] }
    const { client, calls } = harness({ workflowRollbackProposals: [proposal] })
    expect(await client.proposals('flow')).toEqual([proposal])
    await client.approve('flow', 'p', ''); await client.reject('flow', 'p', 'reason')
    expect(calls[0]!.query).toContain('status: "pending"')
    expect(calls[1]!.variables).toEqual({ input: { workflowName: 'flow', proposalId: 'p', reason: null } })
    expect(calls[2]!.variables).toEqual({ input: { workflowName: 'flow', proposalId: 'p', reason: 'reason' } })
  })
  test('preserves GraphQL error codes', async () => {
    const { client } = harness(null, [{ message: 'superseded', extensions: { code: 'ROLLBACK_SUPERSEDED' } }])
    try { await client.proposals('flow'); throw new Error('expected failure') } catch (error) {
      expect(error).toBeInstanceOf(APIError)
      expect((error as APIError).code).toBe('ROLLBACK_SUPERSEDED')
    }
  })
})
