import { expect, test } from 'bun:test'
import { optionChips, probeAgeLabel } from './modelsView.ts'

test('formats the last probe and unprobed state', () => {
  expect(probeAgeLabel(null)).toBe('Not probed')
  expect(probeAgeLabel('2026-11-25T00:00:00Z', Date.parse('2026-11-25T00:03:00Z'))).toBe('Probed 3 minutes ago')
})

test('only produces chips for the model capabilities reported', () => {
  const model = { id: 'a', sources: [], reasoningEfforts: [], serviceTiers: [], modes: [] }
  expect(optionChips(model)).toEqual([])
  expect(optionChips({ ...model, reasoningEfforts: ['high'], modes: ['edit'] })).toEqual([
    { label: 'Reasoning effort', value: 'high' },
    { label: 'Mode', value: 'edit' },
  ])
})
