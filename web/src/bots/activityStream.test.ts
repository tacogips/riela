import { expect, test } from 'bun:test'
import { createActivityStream } from './activityStream'
import type { ActivityQuery } from './client'
import type { BotActivityPage } from './contracts'

function terminalPage(size = 0): BotActivityPage {
  return {
    events: Array.from({ length: size }, (_, index) => ({
      seq: index + 1, at: '2026-11-25T00:00:00Z', kind: 'message', payload: {},
    })),
    state: null, lastSequence: size, truncated: false, sessionStatus: 'completed', activitySource: 'acp', origin: { remote: 'local', verified: true, connection: 'connected', observedAt: '2026-11-25T00:00:00Z' },
  }
}

function harness() {
  let hidden = false
  let listener: (() => void) | undefined
  let timer: { callback: () => void; ms: number; id: ReturnType<typeof setTimeout> } | undefined
  return {
    environment: {
      hidden: () => hidden,
      onVisibilityChange: (callback: () => void) => {
        listener = callback
        return () => { listener = undefined }
      },
      setTimer: (callback: () => void, ms: number) => {
        const id = 1 as unknown as ReturnType<typeof setTimeout>
        timer = { callback, ms, id }
        return id
      },
      clearTimer: (id: ReturnType<typeof setTimeout>) => {
        if (timer?.id === id) timer = undefined
      },
    },
    setHidden: (value: boolean) => { hidden = value; listener?.() },
    nextDelay: () => timer?.ms,
    tick: () => {
      const callback = timer?.callback
      timer = undefined
      callback?.()
    },
  }
}

test('stops after a settled terminal page', async () => {
  const clock = harness()
  let reads = 0
  const dispose = createActivityStream({ getActivity: async () => { reads++; return terminalPage() } },
    'session', () => {}, clock.environment)
  await Promise.resolve()
  expect(reads).toBe(1)
  expect(clock.nextDelay()).toBeUndefined()
  dispose()
})

test('drains a full terminal page before stopping', async () => {
  const clock = harness()
  const cursors: number[] = []
  const dispose = createActivityStream({
    getActivity: async ({ afterSequence }) => {
      cursors.push(afterSequence)
      return afterSequence ? terminalPage() : terminalPage(200)
    },
  }, 'session', () => {}, clock.environment)
  await Promise.resolve()
  expect(clock.nextDelay()).toBe(0)
  clock.tick()
  await Promise.resolve()
  expect(cursors).toEqual([0, 200])
  expect(clock.nextDelay()).toBeUndefined()
  dispose()
})

test('retries a failed activity request after five seconds', async () => {
  const clock = harness()
  const error = new Error('Connection lost')
  const errors: unknown[] = []
  let reads = 0
  const dispose = createActivityStream({
    getActivity: async () => {
      if (++reads === 1) throw error
      return terminalPage()
    },
  }, 'session', (update) => errors.push(update.error), clock.environment)
  await Promise.resolve()
  expect(clock.nextDelay()).toBe(5_000)
  expect(errors).toEqual([error])
  clock.tick()
  await Promise.resolve()
  expect(errors).toEqual([error, undefined])
  dispose()
})

test('aborts in-flight activity on dispose and ignores a late response', async () => {
  const clock = harness()
  let signal: AbortSignal | undefined
  let resolvePage: ((value: BotActivityPage) => void) | undefined
  let updates = 0
  const dispose = createActivityStream({
    getActivity: (request) => {
      signal = request.signal
      return new Promise((resolve) => { resolvePage = resolve })
    },
  }, 'session', () => { updates++ }, clock.environment)
  expect(signal?.aborted).toBe(false)
  dispose()
  expect(signal?.aborted).toBe(true)
  resolvePage?.(terminalPage())
  await Promise.resolve()
  expect(updates).toBe(0)
  expect(clock.nextDelay()).toBeUndefined()
})

test('pauses while hidden and throttles immediate empty live responses', async () => {
  const clock = harness()
  const requests: ActivityQuery[] = []
  clock.setHidden(true)
  const dispose = createActivityStream({
    getActivity: async (request) => {
      requests.push(request)
      return { ...terminalPage(), sessionStatus: 'running' }
    },
  }, 'session', () => {}, clock.environment)
  expect(requests).toHaveLength(0)
  clock.setHidden(false)
  await Promise.resolve()
  expect(requests[0]).toMatchObject({ afterSequence: 0, waitMs: 25_000 })
  expect(clock.nextDelay()).toBe(250)
  clock.setHidden(true)
  clock.tick()
  expect(requests).toHaveLength(1)
  clock.setHidden(false)
  await Promise.resolve()
  expect(requests).toHaveLength(2)
  dispose()
})
