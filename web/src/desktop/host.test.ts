import { describe, expect, test } from 'bun:test'
import {
  DesktopHostError,
  createDesktopTransport,
  fromDesktopFetchResponse,
  isDesktopRuntime,
  toDesktopFetchRequest,
  type DesktopFetchRequest,
  type DesktopFetchResponse,
} from './host'

interface FakeCall {
  command: string
  args?: Record<string, unknown>
}

function fakeInvoke(handlers: Record<string, (args?: Record<string, unknown>) => unknown>) {
  const calls: FakeCall[] = []
  const invoke = async <T,>(command: string, args?: Record<string, unknown>): Promise<T> => {
    calls.push({ command, args })
    const handler = handlers[command]
    if (!handler) throw new Error(`unexpected command ${command}`)
    return (await handler(args)) as T
  }
  return { invoke, calls }
}

function okResponse(body = '{"ok":true}'): DesktopFetchResponse {
  return { status: 200, headers: [['content-type', 'application/json']], body }
}

describe('isDesktopRuntime', () => {
  test('detects the Tauri internals bridge', () => {
    expect(isDesktopRuntime({ __TAURI_INTERNALS__: {} })).toBe(true)
  })

  test('is false in a plain browser global', () => {
    expect(isDesktopRuntime({})).toBe(false)
    expect(isDesktopRuntime(undefined)).toBe(false)
  })
})

describe('toDesktopFetchRequest', () => {
  test('defaults to GET with no headers and no body', () => {
    expect(toDesktopFetchRequest('/api/v1/bootstrap')).toEqual({
      path: '/api/v1/bootstrap',
      method: 'GET',
      headers: [],
      body: null,
    })
  })

  test('upper-cases the method and keeps a string body verbatim', () => {
    const request = toDesktopFetchRequest('/graphql', {
      method: 'post',
      body: '{"query":"{ __typename }"}',
    })
    expect(request.method).toBe('POST')
    expect(request.body).toBe('{"query":"{ __typename }"}')
  })

  test('normalises Headers, arrays and records alike', () => {
    const expected = [['x-riela-csrf', 'token-1']]
    expect(toDesktopFetchRequest('/x', { headers: new Headers({ 'X-Riela-CSRF': 'token-1' }) }).headers).toEqual(
      expected as Array<[string, string]>,
    )
    expect(toDesktopFetchRequest('/x', { headers: [['X-Riela-CSRF', 'token-1']] }).headers).toEqual([
      ['X-Riela-CSRF', 'token-1'],
    ])
    expect(toDesktopFetchRequest('/x', { headers: { 'X-Riela-CSRF': 'token-1' } }).headers).toEqual([
      ['X-Riela-CSRF', 'token-1'],
    ])
  })

  test('rejects absolute URLs, protocol-relative paths, URL and Request inputs', () => {
    expect(() => toDesktopFetchRequest('http://example.com/api')).toThrow(DesktopHostError)
    expect(() => toDesktopFetchRequest('//example.com/api')).toThrow(DesktopHostError)
    expect(() => toDesktopFetchRequest('api/v1/bootstrap')).toThrow(DesktopHostError)
    expect(() => toDesktopFetchRequest(new URL('http://127.0.0.1:8787/api'))).toThrow(DesktopHostError)
    expect(() => toDesktopFetchRequest(new Request('http://127.0.0.1:8787/api'))).toThrow(DesktopHostError)
  })

  test('rejects non-string bodies with invalid_request', () => {
    try {
      toDesktopFetchRequest('/api', { method: 'POST', body: new Blob(['x']) })
      throw new Error('expected a DesktopHostError')
    } catch (error) {
      expect(error).toBeInstanceOf(DesktopHostError)
      expect((error as DesktopHostError).code).toBe('invalid_request')
    }
  })
})

describe('fromDesktopFetchResponse', () => {
  test('rebuilds a JSON response with status, headers and body', async () => {
    const response = fromDesktopFetchResponse(okResponse('{"profile":"default"}'))
    expect(response.ok).toBe(true)
    expect(response.status).toBe(200)
    expect(response.headers.get('content-type')).toBe('application/json')
    expect(await response.json()).toEqual({ profile: 'default' })
  })

  test('passes error statuses through instead of throwing', async () => {
    const response = fromDesktopFetchResponse({ status: 404, headers: [], body: 'unknown path' })
    expect(response.ok).toBe(false)
    expect(response.status).toBe(404)
    expect(await response.text()).toBe('unknown path')
  })

  test('drops the body for statuses that forbid one', async () => {
    for (const status of [204, 205, 304]) {
      const response = fromDesktopFetchResponse({ status, headers: [], body: '' })
      expect(response.status).toBe(status)
      expect(await response.text()).toBe('')
    }
  })
})

describe('createDesktopTransport', () => {
  test('forwards path, CSRF header and JSON body verbatim to riela_fetch', async () => {
    const { invoke, calls } = fakeInvoke({ riela_fetch: () => okResponse() })
    const transport = createDesktopTransport(invoke)

    await transport('/graphql', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', 'X-Riela-CSRF': 'token-1' },
      body: '{"query":"{ __typename }"}',
    })

    expect(calls).toHaveLength(1)
    expect(calls[0]?.command).toBe('riela_fetch')
    expect(calls[0]?.args?.request).toEqual({
      path: '/graphql',
      method: 'POST',
      headers: [
        ['Content-Type', 'application/json'],
        ['X-Riela-CSRF', 'token-1'],
      ],
      body: '{"query":"{ __typename }"}',
    } satisfies DesktopFetchRequest)
  })

  test('retries exactly once through riela_server_retry when the server is unavailable', async () => {
    let attempts = 0
    const { invoke, calls } = fakeInvoke({
      riela_fetch: () => {
        attempts += 1
        if (attempts === 1) throw { code: 'server_unavailable', message: 'Still connecting to Riela…' }
        return okResponse()
      },
      riela_server_retry: () => ({ state: 'connected' }),
    })

    const response = await createDesktopTransport(invoke)('/api/v1/bootstrap')

    expect(response.status).toBe(200)
    expect(calls.map((call) => call.command)).toEqual(['riela_fetch', 'riela_server_retry', 'riela_fetch'])
  })

  test('gives up after the single retry and surfaces the host error code', async () => {
    const { invoke, calls } = fakeInvoke({
      riela_fetch: () => {
        throw { code: 'server_unavailable', message: 'riela serve did not become ready within 20s' }
      },
      riela_server_retry: () => ({ state: 'failed' }),
    })

    try {
      await createDesktopTransport(invoke)('/api/v1/bootstrap')
      throw new Error('expected a DesktopHostError')
    } catch (error) {
      expect(error).toBeInstanceOf(DesktopHostError)
      expect((error as DesktopHostError).code).toBe('server_unavailable')
      expect((error as DesktopHostError).message).toBe('riela serve did not become ready within 20s')
    }
    expect(calls.map((call) => call.command)).toEqual(['riela_fetch', 'riela_server_retry', 'riela_fetch'])
  })

  test('does not retry other failures', async () => {
    const { invoke, calls } = fakeInvoke({
      riela_fetch: () => {
        throw { code: 'request_failed', message: 'connection reset' }
      },
    })

    await expect(createDesktopTransport(invoke)('/api/v1/bootstrap')).rejects.toBeInstanceOf(DesktopHostError)
    expect(calls.map((call) => call.command)).toEqual(['riela_fetch'])
  })

  test('rejects invalid requests before reaching the host', async () => {
    const { invoke, calls } = fakeInvoke({ riela_fetch: () => okResponse() })

    await expect(createDesktopTransport(invoke)('http://example.com/api')).rejects.toBeInstanceOf(DesktopHostError)
    expect(calls).toHaveLength(0)
  })
})
