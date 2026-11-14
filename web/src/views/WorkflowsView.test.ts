import { describe, expect, test } from 'bun:test'
import type { WorkflowDefinitionResponse } from '../contracts'
import type { RegistryWorkflow } from '../workflows/types'
import {
  discoveredDefinitionMatchesSelection,
  mutableDetailMatchesSelection,
  sourcePathForProfileTransition,
} from './WorkflowsView'

const workflow = (workflowId: string, originId: string): RegistryWorkflow => ({
  originId,
  workflowId,
  name: workflowId,
  description: null,
  scope: 'USER',
  provenance: 'MUTABLE',
  mutable: true,
  activationState: 'ACTIVE',
  valid: true,
  definitionRevision: 'revision-1',
  diagnostics: [],
})

describe('mutable workflow selection ownership', () => {
  test('permits actions only for the exact selected workflow and origin', () => {
    const selected = workflow('selected', 'origin:selected')
    expect(mutableDetailMatchesSelection(selected, selected)).toBe(true)
    expect(mutableDetailMatchesSelection(selected, workflow('other', 'origin:selected'))).toBe(false)
    expect(mutableDetailMatchesSelection(selected, workflow('selected', 'origin:other'))).toBe(false)
    expect(mutableDetailMatchesSelection(selected, undefined)).toBe(false)
  })
})

describe('discovered workflow selection ownership', () => {
  test('permits display only for the exact profile and source', () => {
    const detail = {
      sourceId: 'source-a',
    } as WorkflowDefinitionResponse
    const resource = { profileKey: 'profile-a', sourceId: 'source-a', detail }
    expect(discoveredDefinitionMatchesSelection('profile-a', 'source-a', resource)).toBe(true)
    expect(discoveredDefinitionMatchesSelection('profile-a', 'source-b', resource)).toBe(false)
    expect(discoveredDefinitionMatchesSelection('profile-b', 'source-a', resource)).toBe(false)
    expect(discoveredDefinitionMatchesSelection('profile-a', 'source-a', undefined)).toBe(false)
  })
})

describe('workflow source profile ownership', () => {
  test('clears a directory draft when the active profile changes', () => {
    expect(sourcePathForProfileTransition(
      'riela-app:first',
      'riela-app:second',
      '/private/first/workflows',
    )).toBe('')
    expect(sourcePathForProfileTransition(
      'riela-app:first',
      'riela-app:first',
      '/private/first/workflows',
    )).toBe('/private/first/workflows')
  })
})
