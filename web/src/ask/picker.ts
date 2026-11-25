import type { ProviderInstance } from '../models/contracts'
import type { AskSelection, AskTurn } from './contracts'

const cursorAPI = 'official/cursor-sdk'
const geminiAPI = 'official/gemini-sdk'

export function askProviders(catalog: ProviderInstance[]): ProviderInstance[] {
  return catalog.filter(({ driver }) => driver !== cursorAPI && driver !== geminiAPI)
}

export function pickerState(catalog: ProviderInstance[], selection: AskSelection, assistant?: { vendor: string; model: string }) {
  const providers = askProviders(catalog)
  const provider = providers.find(({ instanceId }) => instanceId === selection.providerInstanceId)
  const models = provider?.models ?? []
  const efforts = models.find(({ id }) => id === selection.model)?.reasoningEfforts ?? []
  const input: AskSelection = provider ? {
    providerInstanceId: provider.instanceId,
    model: selection.model || undefined,
    effort: selection.effort && efforts.includes(selection.effort) ? selection.effort : undefined,
  } : {}
  const defaultLabel = assistant?.vendor && assistant.vendor !== 'automatic'
    ? [assistant.vendor, assistant.model].filter(Boolean).join(' · ') : 'Automatic'
  return { providers, models, efforts, input, defaultLabel }
}

export function resolvedSelection(turn: AskTurn): string {
  return [turn.providerInstanceId, turn.backend === turn.providerInstanceId ? null : turn.backend,
    turn.model, turn.toolTransport, turn.limitedPolicy ? 'Limited policy' : null].filter(Boolean).join(' · ')
}
