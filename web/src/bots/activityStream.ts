import { mergeActivityPage, nextCursor, type ActivityFeed } from './activityFeed'
import { activityPageLimit, type BotsClient } from './client'
import type { BotActivityPage } from './contracts'

type ActivityReader = (cursor: number, signal: AbortSignal) => Promise<BotActivityPage>

export const activityWaitMs = 25_000

export function botActivityReader(client: Pick<BotsClient, 'getActivity'>, sessionId: string, remote?: string): ActivityReader {
  return (afterSequence, signal) => client.getActivity({ sessionId, afterSequence, signal, waitMs: activityWaitMs, remote })
}

interface ActivityStreamEnvironment {
  hidden: () => boolean
  onVisibilityChange: (callback: () => void) => () => void
  setTimer: (callback: () => void, ms: number) => ReturnType<typeof setTimeout>
  clearTimer: (timer: ReturnType<typeof setTimeout>) => void
}

const browserEnvironment: ActivityStreamEnvironment = {
  hidden: () => document.hidden,
  onVisibilityChange: (callback) => {
    document.addEventListener('visibilitychange', callback)
    return () => document.removeEventListener('visibilitychange', callback)
  },
  setTimer: (callback, ms) => setTimeout(callback, ms),
  clearTimer: (timer) => clearTimeout(timer),
}

const terminalStatuses = new Set(['completed', 'failed', 'cancelled'])

export function createActivityStream(
  reader: ActivityReader,
  publish: (state: { feed?: ActivityFeed; error?: unknown; ended?: boolean }) => void,
  environment: ActivityStreamEnvironment = browserEnvironment,
): () => void {
  let feed: ActivityFeed | undefined
  let request: AbortController | undefined
  let timer: ReturnType<typeof setTimeout> | undefined
  let disposed = false
  let ended = false

  const schedule = (ms: number) => {
    timer = environment.setTimer(() => {
      timer = undefined
      void read()
    }, ms)
  }

  const read = async () => {
    if (disposed || ended || request || timer !== undefined || environment.hidden()) return
    const current = new AbortController()
    request = current
    try {
      const page = await reader(nextCursor(feed), current.signal)
      if (current.signal.aborted) return
      feed = mergeActivityPage(feed, page)
      const settled = terminalStatuses.has(page.sessionStatus) && page.state?.currentExecutionId == null
      ended = (settled || page.sessionStatus === 'unknown') && page.events.length < activityPageLimit
      publish({ feed, ended })
      if (!ended) schedule(page.events.length ? 0 : 250)
    } catch (error) {
      if (current.signal.aborted) return
      publish({ feed, error })
      schedule(5_000)
    } finally {
      if (request === current) request = undefined
    }
  }

  const pause = () => {
    request?.abort()
    request = undefined
    if (timer !== undefined) environment.clearTimer(timer)
    timer = undefined
  }
  const unsubscribe = environment.onVisibilityChange(() => {
    if (environment.hidden()) pause()
    else void read()
  })
  void read()
  return () => {
    disposed = true
    pause()
    unsubscribe()
  }
}
