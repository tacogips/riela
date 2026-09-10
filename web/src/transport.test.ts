import { describe, expect, test } from 'bun:test'
import { createBrowserTransport, createDesktopTransport, type NativeResponse } from './transport'

test('browser credentials stay on local API calls and forbid redirects', async () => {
  const requests: Request[] = []
  const mock = (async (input: RequestInfo | URL) => {
    requests.push(input as Request)
    return new Response('{}')
  }) as typeof fetch
  const transport = createBrowserTransport(mock, 'https://riela.example', () => 'test-token')
  await transport('/graphql', { method: 'POST', body: '{}', headers: { 'X-Riela-Profile': 'work' } })
  expect(requests[0]?.headers.get('Authorization')).toBe('Bearer test-token')
  expect(requests[0]?.headers.get('X-Riela-Profile')).toBe('work')
  expect(requests[0]?.redirect).toBe('error')
  expect(await requests[0]?.text()).toBe('{}')
  await transport('https://other.example/api/v1/bootstrap')
  await transport('/assets/app.js')
  expect(requests[1]?.headers.has('Authorization')).toBe(false)
  expect(requests[2]?.headers.has('Authorization')).toBe(false)
})

describe('desktop API transport', () => {
  test('preserves encoded paths, query, profile headers, JSON and binary responses', async () => {
    let sent: Record<string, unknown> | undefined
    const transport = createDesktopTransport(async <T>(command: string, args: Record<string, unknown>) => {
      expect(command).toBe('riela_request')
      sent = args
      return { status: 409, headers: { 'Content-Type': 'application/json' },
        body: btoa(JSON.stringify({ error: 'profile_conflict' })) } as T
    })
    const response = await transport('/api/v1/instances/a%2Fb?revision=2', {
      method: 'PUT', headers: { 'Content-Type': 'application/json', 'X-Riela-Profile': 'work' },
      body: JSON.stringify({ value: '日本語' }),
    })
    expect(sent).toEqual({ request: {
      method: 'PUT', path: '/api/v1/instances/a%2Fb?revision=2',
      headers: { 'content-type': 'application/json', 'x-riela-profile': 'work' },
      body: '{"value":"日本語"}',
    } })
    expect(response.status).toBe(409)
    expect(await response.json()).toEqual({ error: 'profile_conflict' })
  })

  test('rejects external origins and non-API paths before invoking native code', async () => {
    let calls = 0
    const transport = createDesktopTransport(async <T>() => { calls++; return {} as T })
    for (const path of ['https://example.com/api/v1/bootstrap', '/etc/passwd', '//evil.test/graphql']) {
      await expect(transport(path)).rejects.toThrow('local Riela API')
    }
    expect(calls).toBe(0)
  })

  test('aborted requests never reach the host', async () => {
    let calls = 0
    const transport = createDesktopTransport(async <T>() => { calls++; return {} as T })
    const controller = new AbortController()
    controller.abort()
    await expect(transport('/api/v1/bootstrap', { signal: controller.signal })).rejects.toThrow()
    expect(calls).toBe(0)
  })

  test('handles empty 204 responses', async () => {
    const result: NativeResponse = { status: 204, headers: {}, body: '' }
    const transport = createDesktopTransport(async <T>() => result as T)
    expect((await transport('/api/v1/instances/a', { method: 'DELETE' })).status).toBe(204)
  })
})
