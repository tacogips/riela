import { describe, expect, test } from 'bun:test'
import { requireExpectedProfile } from '../api'
import type { Instance } from '../contracts'
import {
  instanceEditorIdentity,
  instanceEditorSnapshot,
  instanceSelectionForProfile,
} from './InstancesView'

function instance(
  id: string,
  workingDirectory: string,
  variables: Record<string, string>,
): Instance {
  return {
    id,
    name: id,
    workflowId: id,
    source: id,
    sourceKind: 'directory',
    status: 'stopped',
    statusDetail: 'Stopped',
    active: false,
    enabledAtLaunch: false,
    workingDirectory,
    environmentFilePath: null,
    environmentVariables: [],
    requiredEnvironment: [],
    workflowVariables: variables,
    nodePatchCount: 0,
    nodePatches: {},
    eventSources: [],
  }
}

describe('instance profile selection', () => {
  test('clears a selected instance when the active profile changes', () => {
    expect(instanceSelectionForProfile('riela-app:first', 'riela-app:second', 'project:workflow'))
      .toBeUndefined()
  })

  test('preserves selection for the initial and unchanged profile', () => {
    expect(instanceSelectionForProfile(undefined, 'riela-app:first', 'project:workflow'))
      .toBe('project:workflow')
    expect(instanceSelectionForProfile('riela-app:first', 'riela-app:first', 'project:workflow'))
      .toBe('project:workflow')
  })

  test('rejects a response owned by a different active profile', () => {
    expect(() => requireExpectedProfile({ profile: 'second' }, 'first')).toThrow()
    expect(requireExpectedProfile({ profile: 'first', revision: 2 }, 'first').revision).toBe(2)
  })
})

describe('instance editor ownership', () => {
  test('keys the editor by profile and instance identity', () => {
    expect(instanceEditorIdentity('riela-app:first', 'shared-id'))
      .not.toBe(instanceEditorIdentity('riela-app:second', 'shared-id'))
  })

  test('seeds values and expected revision from the selected instance only', () => {
    const first = instanceEditorSnapshot(instance('first', '/first', { owner: 'first' }), 4)
    const second = instanceEditorSnapshot(instance('second', '/second', { owner: 'second' }), 9)

    expect(first).toMatchObject({
      workingDirectory: '/first',
      variables: '{\n  "owner": "first"\n}',
      expectedRevision: 4,
    })
    expect(second).toMatchObject({
      workingDirectory: '/second',
      variables: '{\n  "owner": "second"\n}',
      expectedRevision: 9,
    })
  })
})
