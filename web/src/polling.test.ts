import { describe, expect, test } from 'bun:test'
import {
  createPollingController,
  type PollingEnvironment,
  type PollingState,
} from './polling'

interface Deferred<T> {
  promise: Promise<T>
  resolve: (value: T) => void
  reject: (error: unknown) => void
}

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void
  let reject!: (error: unknown) => void
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}

function harness<T>() {
  let hidden = false
  let visibilityListener: (() => void) | undefined
  let intervalCallback: (() => void) | undefined
  let cleared = 0
  const states: PollingState<T>[] = []
  const environment: PollingEnvironment = {
    hidden: () => hidden,
    setInterval: (callback) => {
      intervalCallback = callback
      return callback
    },
    clearInterval: () => {
      cleared += 1
      intervalCallback = undefined
    },
    addVisibilityListener: (listener) => {
      visibilityListener = listener
    },
    removeVisibilityListener: (listener) => {
      if (visibilityListener === listener) visibilityListener = undefined
    },
  }
  return {
    environment,
    states,
    publish: (state: PollingState<T>) => states.push({ ...state }),
    latest: () => states.at(-1),
    setHidden: (value: boolean) => {
      hidden = value
      visibilityListener?.()
    },
    tick: () => intervalCallback?.(),
    cleared: () => cleared,
    hasListener: () => visibilityListener !== undefined,
    hasTimer: () => intervalCallback !== undefined,
  }
}

describe('polling controller', () => {
  test('does not automatically load an initially hidden context', async () => {
    const view = harness<number>()
    view.setHidden(true)
    let loads = 0
    const controller = createPollingController(
      () => 'profile',
      async () => ++loads,
      view.publish,
      5_000,
      view.environment,
    )

    controller.contextChanged()
    await Promise.resolve()
    expect(loads).toBe(0)
    expect(view.latest()?.status).toBe('paused')
    await controller.refresh()
    expect(loads).toBe(1)
  })

  test('pauses while hidden and refreshes immediately when visible', async () => {
    const view = harness<number>()
    let loads = 0
    const controller = createPollingController(
      () => 'profile',
      async () => ++loads,
      view.publish,
      5_000,
      view.environment,
    )

    controller.contextChanged()
    await controller.refresh()
    expect(loads).toBe(1)
    expect(view.latest()).toMatchObject({ data: 1, loading: false, status: 'on' })
    await controller.refresh()
    expect(loads).toBe(2)

    view.setHidden(true)
    expect(view.latest()?.status).toBe('paused')
    expect(view.hasTimer()).toBe(false)

    view.setHidden(false)
    await Promise.resolve()
    expect(loads).toBe(3)
    expect(view.latest()).toMatchObject({ data: 3, loading: false, status: 'on' })
    expect(view.hasTimer()).toBe(true)
  })

  test('suppresses overlapping requests and retries after failure while retaining data', async () => {
    const view = harness<number>()
    const requests: Deferred<number>[] = []
    const controller = createPollingController(
      () => 'profile',
      () => {
        const request = deferred<number>()
        requests.push(request)
        return request.promise
      },
      view.publish,
      5_000,
      view.environment,
    )

    controller.contextChanged()
    await Promise.resolve()
    view.tick()
    void controller.refresh()
    expect(requests).toHaveLength(1)
    requests[0]?.resolve(7)
    await requests[0]?.promise
    await Promise.resolve()
    expect(view.latest()).toMatchObject({ data: 7, loading: false })

    view.tick()
    await Promise.resolve()
    expect(requests).toHaveLength(2)
    requests[1]?.reject(new Error('temporary'))
    await requests[1]?.promise.catch(() => undefined)
    await Promise.resolve()
    expect(view.latest()?.data).toBe(7)
    expect((view.latest()?.error as Error).message).toBe('temporary')

    view.tick()
    await Promise.resolve()
    expect(requests).toHaveLength(3)
  })

  test('rejects stale content, loading, and error commits after context changes', async () => {
    const view = harness<number>()
    let key = 'first'
    const requests: Deferred<number>[] = []
    const signals: AbortSignal[] = []
    const controller = createPollingController(
      () => key,
      (signal) => {
        signals.push(signal)
        const request = deferred<number>()
        requests.push(request)
        return request.promise
      },
      view.publish,
      5_000,
      view.environment,
    )

    controller.contextChanged()
    await Promise.resolve()
    key = 'second'
    controller.contextChanged()
    await Promise.resolve()
    expect(signals[0]?.aborted).toBe(true)
    expect(requests).toHaveLength(2)

    requests[0]?.reject(new Error('stale'))
    await requests[0]?.promise.catch(() => undefined)
    await Promise.resolve()
    expect(view.latest()?.error).toBeUndefined()
    expect(view.latest()?.loading).toBe(true)

    requests[1]?.resolve(2)
    await requests[1]?.promise
    await Promise.resolve()
    expect(view.latest()).toMatchObject({ data: 2, error: undefined, loading: false })
  })

  test('disposal aborts work and removes timer and visibility listener', async () => {
    const view = harness<number>()
    const request = deferred<number>()
    let signal: AbortSignal | undefined
    const controller = createPollingController(
      () => 'profile',
      (value) => {
        signal = value
        return request.promise
      },
      view.publish,
      5_000,
      view.environment,
    )

    controller.contextChanged()
    await Promise.resolve()
    controller.dispose()
    expect(signal?.aborted).toBe(true)
    expect(view.hasListener()).toBe(false)
    expect(view.hasTimer()).toBe(false)
    expect(view.cleared()).toBeGreaterThan(0)

    request.resolve(9)
    await request.promise
    await Promise.resolve()
    expect(view.latest()?.data).toBeUndefined()
  })
})
