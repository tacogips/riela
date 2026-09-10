/** Shared API transport. Desktop requests travel over the inherited native IPC pipe. */
export interface NativeResponse {
  status: number
  headers: Record<string, string>
  body: string
}

type Invoke = <T>(command: string, args: Record<string, unknown>) => Promise<T>

export function createDesktopTransport(invoke: Invoke) {
  return async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const base = typeof location === 'undefined' ? 'http://tauri.localhost' : location.origin
    const request = new Request(input instanceof Request ? input : new URL(String(input), base), init)
    const url = new URL(request.url)
    if (url.origin !== base || !(url.pathname.startsWith('/api/v1/') || url.pathname === '/graphql')) {
      throw new TypeError('Desktop transport only accepts local Riela API requests.')
    }
    request.signal.throwIfAborted()
    const body = request.body ? await request.text() : ''
    request.signal.throwIfAborted()
    return new Promise<Response>((resolve, reject) => {
      const abort = () => reject(request.signal.reason)
      request.signal.addEventListener('abort', abort, { once: true })
      invoke<NativeResponse>('riela_request', {
        request: {
          method: request.method,
          path: url.pathname + url.search,
          headers: Object.fromEntries(request.headers.entries()),
          body,
        },
      }).then(result => {
        request.signal.throwIfAborted()
        const bytes = Uint8Array.from(atob(result.body), char => char.charCodeAt(0))
        resolve(new Response(result.status === 204 || request.method === 'HEAD' ? null : bytes, {
          status: result.status, headers: result.headers,
        }))
      }).catch(reject).finally(() => request.signal.removeEventListener('abort', abort))
    })
  }
}

export function isDesktop(): boolean {
  return '__TAURI__' in globalThis
}

// Kept in this page's memory only; never persisted or placed in a URL.
let browserAccessToken = ''
export function setBrowserAccessToken(token: string): void {
  browserAccessToken = token
}

export function createBrowserTransport(transport: typeof fetch, origin: string, token: () => string) {
  return (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const request = new Request(input instanceof Request ? input : new URL(String(input), origin), init)
    const url = new URL(request.url)
    const credential = token()
    if (credential && url.origin === origin && (url.pathname.startsWith('/api/v1/') || url.pathname === '/graphql')) {
      const headers = new Headers(request.headers)
      headers.set('Authorization', `Bearer ${credential}`)
      return transport(new Request(request, { headers, redirect: 'error' }))
    }
    return transport(request)
  }
}

export function rielaFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  const native = (globalThis as typeof globalThis & {
    __TAURI__?: { core: { invoke: Invoke } }
  }).__TAURI__
  return native
    ? createDesktopTransport(native.core.invoke)(input, init)
    : createBrowserTransport(fetch, location.origin, () => browserAccessToken)(input, init)
}
