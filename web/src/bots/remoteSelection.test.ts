import { expect, test } from 'bun:test'
import { APIError } from '../api'
import type { RemoteList } from './contracts'
import { readRemoteTargets, remoteArgument, resolveRemoteSelection } from './remoteSelection'

const registry: RemoteList = {
  active: 'srv',
  remotes: [{ name: 'srv', address: 'https://srv.example', serverName: 'Server', connection: 'connected' }],
}

test('uses the server default only without a stored host filter', () => {
  expect(resolveRemoteSelection(null, registry)).toBe('srv')
  expect(resolveRemoteSelection('local', registry)).toBe('local')
  expect(resolveRemoteSelection('*', registry)).toBe('*')
  expect(resolveRemoteSelection('missing', registry)).toBe('local')
})

test('uses the item host for an operation in the all-host view', () => {
  expect(remoteArgument('*', 'srv')).toBe('srv')
  expect(remoteArgument('local')).toBe('local')
  expect(remoteArgument('*')).toBe('*')
})

test('preserves healthy hosts when a grant is revoked', async () => {
  const result = await readRemoteTargets(['local', 'srv', 'other'], async (remote) => {
    if (remote === 'srv') throw new APIError('Revoked', 403, 'remote_unauthorized')
    return remote
  })
  expect(result).toEqual({
    values: ['local', 'other'],
    failures: [{ remote: 'srv', code: 'remote_unauthorized' }],
  })
})
