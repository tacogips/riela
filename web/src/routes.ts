export type HashRoute =
  | { view: 'instances' | 'logs' | 'workflows' | 'ops' | 'settings' }
  | { view: 'run-detail'; sessionId: string }
  | { view: 'ops-run'; instanceId: string; sessionId: string }

const NAV_VIEWS = new Set(['instances', 'logs', 'workflows', 'ops', 'settings'] as const)
type NavView = typeof NAV_VIEWS extends Set<infer T> ? T : never

/**
 * Parses a location hash into a route. `#/runs/{sessionId}` is a published
 * contract (RIELA_WEB_RUN_LINK_TEMPLATE) and must keep resolving. Segments
 * are split before decoding so encoded slashes survive inside identifiers.
 */
export function parseViewHash(hash: string): HashRoute | undefined {
  if (!hash.startsWith('#/')) return undefined
  const rawSegments = hash.slice(2).split('/')
  let segments: string[]
  try {
    segments = rawSegments.map((segment) => decodeURIComponent(segment))
  } catch {
    return undefined
  }
  if (segments.length === 2 && segments[0] === 'runs' && segments[1]) {
    return { view: 'run-detail', sessionId: segments[1] }
  }
  if (segments.length === 4 && segments[0] === 'ops' && segments[1] === 'runs' && segments[3]) {
    return { view: 'ops-run', instanceId: segments[2] ?? '', sessionId: segments[3] }
  }
  if (segments.length === 1 && NAV_VIEWS.has(segments[0] as NavView)) {
    return { view: segments[0] as NavView }
  }
  return undefined
}

export function viewHash(route: HashRoute): string {
  if (route.view === 'run-detail') {
    return `#/runs/${encodeURIComponent(route.sessionId)}`
  }
  if (route.view === 'ops-run') {
    return `#/ops/runs/${encodeURIComponent(route.instanceId)}/${encodeURIComponent(route.sessionId)}`
  }
  return `#/${route.view}`
}
