import { describe, expect, test } from 'bun:test'
import type { WorkflowDefinitionResponse } from '../contracts'
import { discoveredDefinitionMatchesSelection } from './WorkflowDefinitionView'

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
