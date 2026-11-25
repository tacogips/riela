import { expect, test } from 'bun:test'
import type { ProviderInstance } from '../models/contracts'
import { askProviders, pickerState, resolvedSelection } from './picker'

function provider(instanceId: string, driver: string): ProviderInstance {
  return { instanceId, driver, label: instanceId, builtIn: true,
    origin: { remote: 'local', verified: true, connection: 'connected', observedAt: '' },
    models: [
      { id: 'standard', sources: [], reasoningEfforts: [], serviceTiers: [], modes: [] },
      { id: 'reasoning', sources: [], reasoningEfforts: ['low', 'high'], serviceTiers: [], modes: [] },
    ],
  }
}

test('keeps the setting as the default and allows Automatic without an override', () => {
  expect(pickerState([], {}, { vendor: 'cursor-api', model: 'selected' }))
    .toMatchObject({ defaultLabel: 'cursor-api · selected', input: {} })
  expect(pickerState([], {}, { vendor: 'automatic', model: 'ignored' }))
    .toMatchObject({ defaultLabel: 'Automatic', input: {} })
})

test('sends the selected provider, model and supported effort', () => {
  const catalog = [provider('team', 'codex-agent')]
  expect(pickerState(catalog, { providerInstanceId: 'team', model: 'reasoning', effort: 'high' }))
    .toMatchObject({ input: { providerInstanceId: 'team', model: 'reasoning', effort: 'high' }, efforts: ['low', 'high'] })
  expect(pickerState(catalog, { providerInstanceId: 'team', model: 'standard', effort: 'high' }))
    .toMatchObject({ input: { model: 'standard', effort: undefined }, efforts: [] })
  expect(resolvedSelection({
    turnId: 't1', status: 'running', providerInstanceId: 'team', backend: 'cursor-cli-agent',
    model: 'standard', toolTransport: 'rounds', limitedPolicy: true,
  })).toBe('team · cursor-cli-agent · standard · rounds · Limited policy')
})

test('omits Cursor API and Gemini API instances while keeping catalog order', () => {
  const catalog = [provider('first', 'codex-agent'), provider('cursor', 'official/cursor-sdk'),
    provider('cursor-cli', 'cursor-cli-agent'), provider('gemini', 'official/gemini-sdk'),
    provider('last', 'official/openai-sdk')]
  expect(askProviders(catalog).map(({ instanceId }) => instanceId)).toEqual(['first', 'cursor-cli', 'last'])
})
