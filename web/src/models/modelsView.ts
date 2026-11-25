import { relativeActivity } from '../bots/boardView'
import type { CatalogModel } from './contracts'

export function probeAgeLabel(probedAt: string | null | undefined, now = Date.now()): string {
  return probedAt ? `Probed ${relativeActivity(probedAt, now)}` : 'Not probed'
}

export function optionChips(model: CatalogModel): { label: string; value: string }[] {
  return [
    ...model.reasoningEfforts.map((value) => ({ label: 'Reasoning effort', value })),
    ...model.serviceTiers.map((value) => ({ label: 'Service tier', value })),
    ...model.modes.map((value) => ({ label: 'Mode', value })),
  ]
}
