import type { BotBoardGroup, BotCounts } from './contracts'

export const groupTitles = {
  needsYou: 'Needs you',
  inProgress: 'In progress',
  waiting: 'Waiting',
  planned: 'Planned',
  closed: 'Closed',
} satisfies Record<BotBoardGroup, string>

export const boardOrder = ['needsYou', 'inProgress', 'waiting', 'planned', 'closed'] as const
export const sectionOrder = ['active', 'working', 'snoozed', 'settled'] as const

export function statusLabel(status: string): string {
  return status.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/_/g, ' ').toLowerCase()
}

export function formatElapsed(ms: number): string {
  const seconds = Math.floor(Math.max(0, ms) / 1000)
  const hours = Math.floor(seconds / 3600)
  const minutes = Math.floor(seconds / 60) % 60
  return [hours && `${hours}h`, minutes && `${minutes}m`, `${seconds % 60}s`].filter(Boolean).join(' ')
}

export function countsLabel(counts: BotCounts): string {
  return [
    counts.needsYou && `${counts.needsYou} needs you`,
    counts.working && `${counts.working} working`,
    counts.waiting && `${counts.waiting} waiting`,
    counts.planned && `${counts.planned} planned`,
  ].filter(Boolean).join(' · ')
}

export function relativeActivity(at: string, now = Date.now()): string {
  const seconds = Math.round((Date.parse(at) - now) / 1000)
  const format = new Intl.RelativeTimeFormat('en', { numeric: 'auto' })
  for (const [unit, length] of [['day', 86_400], ['hour', 3_600], ['minute', 60]] as const) {
    if (Math.abs(seconds) >= length) return format.format(Math.trunc(seconds / length), unit)
  }
  return format.format(seconds, 'second')
}

const timeFormat = new Intl.DateTimeFormat('en', { dateStyle: 'medium', timeStyle: 'short' })

export function formatBotTime(at: string): string {
  return timeFormat.format(new Date(at))
}
