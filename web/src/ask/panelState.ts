import type { ActivityFeed } from '../bots/activityFeed'
import type { AskAction, AskMessage, AskSnapshot } from './contracts'

type Item =
  | { kind: 'stored'; message: AskMessage }
  | { kind: 'answer' | 'thought' | 'tool' | 'plan' | 'usage' | 'error'; text: string }
  | { kind: 'action'; action: AskAction }

function liveItems(feed: ActivityFeed | undefined, turnId: string, transport: string): Item[] {
  const events = feed?.events.filter((event) => event.executionId === turnId) ?? []
  const items: Item[] = []
  const chunks = new Map<string, Extract<Item, { text: string }>>()
  for (const { kind, payload } of events) {
    if ((kind !== 'message' && kind !== 'thought') || typeof payload.text !== 'string' || !payload.text) continue
    const messageId = String(payload.messageId ?? '')
    // Rounds assigns an ID to each answer line, while MCP groups by message ID.
    const group = kind === 'message' && transport === 'rounds' ? messageId.replace(/:\d+$/, '') : messageId
    const key = `${kind}:${group}`
    let item = chunks.get(key)
    if (!item) {
      item = { kind: kind === 'message' ? 'answer' : 'thought', text: '' }
      items.push(item)
      chunks.set(key, item)
    }
    item.text = payload.replace ? payload.text : item.text + payload.text
  }
  if (feed?.state?.currentExecutionId !== turnId) return items
  for (const tool of feed.state.toolCalls) {
    items.push({ kind: 'tool', text: [tool.title || tool.toolCallId, tool.status].filter(Boolean).join(' · ') })
  }
  for (const plan of feed.state.plans) {
    for (const entry of plan.entries) items.push({ kind: 'plan', text: `${entry.content} · ${entry.status}` })
  }
  const usage = feed.state.usage
  if (usage) {
    const parts = [
      usage.used == null ? null : `${usage.used} used`,
      usage.size == null ? null : `${usage.size} limit`,
      usage.input_tokens == null ? null : `${usage.input_tokens} in`,
      usage.output_tokens == null ? null : `${usage.output_tokens} out`,
      usage.total_tokens == null ? null : `${usage.total_tokens} total`,
    ].filter(Boolean)
    if (parts.length) items.push({ kind: 'usage', text: `Tokens · ${parts.join(' · ')}` })
  }
  return items
}

export function panelState({ snapshot, feed, error, pending }: {
  snapshot?: AskSnapshot; feed?: ActivityFeed; error?: string; pending?: boolean
}) {
  const turn = snapshot?.conversation.turn
  const running = turn?.status === 'running'
  const items: Item[] = snapshot?.messages.map((message) => ({ kind: 'stored', message })) ?? []
  if (running && turn) items.push(...liveItems(feed, turn.turnId, turn.toolTransport))
  if (turn?.error) items.push({ kind: 'error', text: `${turn.error.code} · ${turn.error.message}` })
  for (const action of snapshot?.actions ?? []) items.push({ kind: 'action', action })
  if (error) items.push({ kind: 'error', text: error })
  return { items, running, canSend: !pending && !running }
}
