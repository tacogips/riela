import { formatBotTime } from './boardView'
import type { BotMemoryChange } from './contracts'

export function isDirty(original: string, edited: string): boolean {
  return original !== edited
}

export function changeLabel(change: BotMemoryChange): string {
  return [change.actor, change.reason, formatBotTime(change.createdAt)].filter(Boolean).join(' · ')
}
