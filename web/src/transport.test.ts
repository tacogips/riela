import { afterEach, describe, expect, test } from 'bun:test'
import { RielaAPIClient } from './api'
import { requestThroughHost, resetHostTransport, setHostTransport } from './transport'

afterEach(() => {
  resetHostTransport()
})

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

describe('requestThroughHost', () => {
  test('resolves the active transport at call time, not at capture time', async () => {
    const captured = requestThroughHost
    const calls: string[] = []
    setHostTransport((input) => {
      calls.push(String(input))
      return Promise.resolve(jsonResponse({ ok: true }))
    })

    const response = await captured('/api/v1/bootstrap')

    expect(calls).toEqual(['/api/v1/bootstrap'])
    expect(await response.json()).toEqual({ ok: true })
  })

  test('a client constructed before installation still uses the installed transport', async () => {
    const client = new RielaAPIClient()
    const calls: string[] = []
    setHostTransport((input) => {
      calls.push(String(input))
      return Promise.resolve(
        jsonResponse({ profile: 'default', revision: 3, csrfToken: 'token-1' }),
      )
    })

    const bootstrap = await client.bootstrap()

    expect(calls).toEqual(['/api/v1/bootstrap'])
    expect(bootstrap.csrfToken).toBe('token-1')
    expect(client.noteHeaders()).toEqual({
      'X-Riela-CSRF': 'token-1',
      'X-Riela-Profile': 'default',
    })
  })

  test('resetHostTransport restores the default browser transport', async () => {
    let installedCalls = 0
    setHostTransport(() => {
      installedCalls += 1
      return Promise.resolve(jsonResponse({ ok: true }))
    })
    await requestThroughHost('/api/v1/bootstrap')
    expect(installedCalls).toBe(1)

    resetHostTransport()

    // The default transport delegates to the global fetch, which fails on an
    // unroutable loopback port rather than reaching the installed fake.
    await expect(requestThroughHost('http://127.0.0.1:1/never')).rejects.toBeDefined()
    expect(installedCalls).toBe(1)
  })
})
