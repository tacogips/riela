/**
 * Host-agnostic HTTP seam for the dashboard clients.
 *
 * The browser build never touches this beyond the default (a plain `fetch`
 * delegate). The desktop shell installs its own transport during startup, so
 * every request the SPA already routes through an injectable seam is executed
 * by the Tauri host process instead. Resolution is late-bound: clients that
 * captured `requestThroughHost` as a default parameter before installation
 * still reach the transport that is active at call time.
 */
export type HostTransport = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>

const browserTransport: HostTransport = (input, init) => fetch(input, init)

let activeTransport: HostTransport = browserTransport

export function setHostTransport(transport: HostTransport): void {
  activeTransport = transport
}

export function resetHostTransport(): void {
  activeTransport = browserTransport
}

export const requestThroughHost: HostTransport = (input, init) => activeTransport(input, init)
