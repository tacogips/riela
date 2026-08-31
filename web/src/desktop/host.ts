/**
 * The only Tauri-aware module in the frontend.
 *
 * Riela's loopback servers send no CORS headers and validate `Host`/`Origin`
 * together with the `X-Riela-CSRF` token, so a WebView `fetch` originating from
 * `tauri://localhost` cannot talk to them. Instead every dashboard request is
 * handed to the Rust host through the `riela_fetch` command, which performs the
 * HTTP call from the native process with the correct header policy.
 *
 * Nothing outside this file (and `web/src/index.tsx`, which installs it) knows
 * that a desktop shell exists.
 *
 * Cancellation is honoured at this boundary only: aborting rejects the caller
 * with the same `AbortError` a browser `fetch` produces, but the Rust request
 * already in flight is not cancelled and runs to completion (bounded by the
 * host's own 30s request timeout). Its response is discarded.
 */
import { setHostTransport, type HostTransport } from '../transport'

export interface DesktopInvoke {
  <T>(command: string, args?: Record<string, unknown>): Promise<T>
}

export interface DesktopFetchRequest {
  path: string
  method: string
  headers: Array<[string, string]>
  body: string | null
}

export interface DesktopFetchResponse {
  status: number
  headers: Array<[string, string]>
  body: string
}

export type DesktopServerState = 'discovering' | 'starting' | 'connected' | 'failed'

export interface DesktopServerStatus {
  state: DesktopServerState
  endpoint?: { origin: string; kind: 'riela-app' | 'cli-serve'; managed: boolean }
  detail?: string
}

export class DesktopHostError extends Error {
  override readonly name = 'RielaDesktopHostError'

  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message)
  }
}

/** Statuses whose `Response` constructor forbids a body. */
const BODYLESS_STATUSES = new Set([204, 205, 304])

export function isDesktopRuntime(globalObject: unknown = globalThis): boolean {
  return typeof globalObject === 'object' && globalObject !== null && '__TAURI_INTERNALS__' in globalObject
}

function normalizeHeaders(headers: HeadersInit | undefined): Array<[string, string]> {
  if (!headers) return []
  if (headers instanceof Headers) return [...headers.entries()]
  if (Array.isArray(headers)) {
    return headers.map(([name, value]) => [String(name), String(value)] as [string, string])
  }
  return Object.entries(headers).map(([name, value]) => [name, String(value)] as [string, string])
}

export function toDesktopFetchRequest(input: RequestInfo | URL, init?: RequestInit): DesktopFetchRequest {
  if (typeof input !== 'string') {
    throw new DesktopHostError(
      'invalid_request',
      'The Riela desktop host only accepts same-origin relative paths, not URL or Request objects.',
    )
  }
  if (!input.startsWith('/') || input.startsWith('//')) {
    throw new DesktopHostError(
      'invalid_request',
      `The Riela desktop host only accepts relative paths beginning with "/" (received "${input}").`,
    )
  }

  const body = init?.body
  if (body !== undefined && body !== null && typeof body !== 'string') {
    throw new DesktopHostError(
      'invalid_request',
      'The Riela desktop host only accepts string request bodies.',
    )
  }

  return {
    path: input,
    method: (init?.method ?? 'GET').toUpperCase(),
    headers: normalizeHeaders(init?.headers),
    body: body ?? null,
  }
}

export function fromDesktopFetchResponse(response: DesktopFetchResponse): Response {
  const body = BODYLESS_STATUSES.has(response.status) ? null : response.body
  return new Response(body, { status: response.status, headers: response.headers })
}

interface RejectionShape {
  code?: unknown
  message?: unknown
}

function toHostError(error: unknown): DesktopHostError {
  if (error instanceof DesktopHostError) return error
  if (typeof error === 'object' && error !== null) {
    const { code, message } = error as RejectionShape
    if (typeof code === 'string') {
      return new DesktopHostError(code, typeof message === 'string' ? message : code)
    }
    if (error instanceof Error) return new DesktopHostError('request_failed', error.message)
  }
  return new DesktopHostError('request_failed', String(error))
}

function abortError(signal: AbortSignal): unknown {
  // `signal.reason` is what a browser fetch rejects with; the DOMException
  // fallback keeps `polling.ts`'s AbortError check working everywhere.
  return signal.reason ?? new DOMException('The operation was aborted.', 'AbortError')
}

/**
 * Rejects as soon as `signal` aborts, mirroring `fetch`. An already-aborted
 * signal short-circuits before `start` runs, so no host request is issued; once
 * started, the host request keeps running — see the module header.
 */
function withAbort<T>(start: () => Promise<T>, signal: AbortSignal | null | undefined): Promise<T> {
  if (!signal) return start()
  if (signal.aborted) return Promise.reject(abortError(signal))
  const pending = start()
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(abortError(signal))
    signal.addEventListener('abort', onAbort, { once: true })
    pending.then(resolve, reject).finally(() => signal.removeEventListener('abort', onAbort))
  })
}

export function createDesktopTransport(invoke: DesktopInvoke): HostTransport {
  return async (input, init) => {
    const request = toDesktopFetchRequest(input, init)
    const signal = init?.signal
    const send = () =>
      withAbort(() => invoke<DesktopFetchResponse>('riela_fetch', { request }), signal)
    try {
      return fromDesktopFetchResponse(await send())
    } catch (error) {
      if (signal?.aborted) throw error
      const hostError = toHostError(error)
      if (hostError.code !== 'server_unavailable') throw hostError
      // The server may still be starting (or was restarted underneath us);
      // re-run discovery once and retry exactly one more time.
      await withAbort(() => invoke<DesktopServerStatus>('riela_server_retry'), signal)
      try {
        return fromDesktopFetchResponse(await send())
      } catch (retryError) {
        if (signal?.aborted) throw retryError
        throw toHostError(retryError)
      }
    }
  }
}

export async function installDesktopHost(): Promise<boolean> {
  if (!isDesktopRuntime()) return false
  const { invoke } = await import('@tauri-apps/api/core')
  setHostTransport(createDesktopTransport(invoke as DesktopInvoke))
  return true
}
