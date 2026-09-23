export type HashRoute =
  | { view: 'instances' | 'logs' | 'workflows' | 'ops' | 'settings' }
  | { view: 'workflow-detail'; sourceId: string; configurationId?: string; tab?: 'settings' | 'history' | 'definition' }
  | { view: 'run-detail'; sessionId: string; sourceId?: string; configurationId?: string }
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
  if (segments.length === 6 && segments[0] === 'workflows' && segments[1] && segments[2] === 'configurations' && segments[3] && segments[4] === 'runs' && segments[5]) {
    return { view: 'run-detail', sourceId: segments[1], configurationId: segments[3], sessionId: segments[5] }
  }
  if ((segments.length === 4 || segments.length === 5) && segments[0] === 'workflows' && segments[1] && segments[2] === 'configurations' && segments[3]) {
    const tab = segments[4] ?? 'settings'
    if (tab !== 'settings' && tab !== 'history' && tab !== 'definition') return undefined
    return { view: 'workflow-detail', sourceId: segments[1], configurationId: segments[3], tab }
  }
  if (segments.length === 2 && segments[0] === 'workflows' && segments[1]) {
    return { view: 'workflow-detail', sourceId: segments[1] }
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
  if (route.view === 'workflow-detail') {
    const base = `#/workflows/${encodeURIComponent(route.sourceId)}`
    return route.configurationId ? `${base}/configurations/${encodeURIComponent(route.configurationId)}/${route.tab ?? 'settings'}` : base
  }
  if (route.view === 'run-detail') {
    if (route.sourceId && route.configurationId) return `#/workflows/${encodeURIComponent(route.sourceId)}/configurations/${encodeURIComponent(route.configurationId)}/runs/${encodeURIComponent(route.sessionId)}`
    return `#/runs/${encodeURIComponent(route.sessionId)}`
  }
  if (route.view === 'ops-run') {
    return `#/ops/runs/${encodeURIComponent(route.instanceId)}/${encodeURIComponent(route.sessionId)}`
  }
  return `#/${route.view}`
}
