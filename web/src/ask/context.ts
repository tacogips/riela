import type { HashRoute } from '../routes'
import type { AskContext } from './contracts'

export interface AskContextDisplay {
  context: AskContext
  label: string
  remote: string
}

export function askRemote(remote?: string): string {
  return remote && remote !== '*' && remote !== 'unverified' ? remote : 'local'
}

export function contextFromRoute(route: HashRoute | undefined, lookup: {
  botName?: (id: string, remote: string) => string | undefined
  workflowId?: (sourceId: string) => string | undefined
  remote?: string
} = {}): AskContextDisplay {
  const remote = askRemote(route && 'remote' in route ? route.remote ?? lookup.remote : lookup.remote)
  if (route?.view === 'run-detail' || route?.view === 'ops-run') {
    return { context: { kind: 'session', id: route.sessionId }, label: `Run ${route.sessionId}`, remote }
  }
  if (route?.view === 'bot-detail') {
    return { context: { kind: 'bot', id: route.botId }, label: `Bot ${lookup.botName?.(route.botId, remote) ?? route.botId}`, remote }
  }
  if (route?.view === 'workflow-detail') {
    const id = lookup.workflowId?.(route.sourceId)
    if (id) return { context: { kind: 'workflow', id }, label: `Workflow ${id}`, remote }
  }
  return { context: { kind: 'none' }, label: '', remote }
}
