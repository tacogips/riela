import type { BotActivityEvent, BotActivityPage } from './contracts'

export type ActivityFeed = Pick<BotActivityPage, 'events' | 'state' | 'activitySource' | 'sessionStatus' | 'lastSequence' | 'truncated'>

export function mergeActivityPage(feed: ActivityFeed | undefined, page: BotActivityPage): ActivityFeed {
  const reset = !feed || page.truncated
  const events = reset ? [] : [...feed.events]
  let cursor = reset ? 0 : nextCursor(feed)
  for (const event of page.events) {
    if (event.seq <= cursor) continue
    events.push(event)
    cursor = event.seq
  }
  return {
    events,
    state: page.state,
    activitySource: page.activitySource,
    sessionStatus: page.sessionStatus,
    lastSequence: Math.max(cursor, page.lastSequence),
    truncated: Boolean(feed?.truncated || page.truncated),
  }
}

export function nextCursor(feed: ActivityFeed | undefined): number {
  return feed?.lastSequence ?? 0
}

export function activitySummary(event: BotActivityEvent): string {
  const label = event.kind.replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase()
  for (const key of ['text', 'title', 'reason', 'status', 'stepId', 'stopReason']) {
    const value = event.payload[key]
    if (typeof value !== 'string' || !value.trim()) continue
    return `${label}: ${value.trim().replace(/\s+/g, ' ').slice(0, 160)}`
  }
  return label
}
