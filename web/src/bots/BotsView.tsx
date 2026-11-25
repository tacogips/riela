import { For, Show, createMemo, createSignal } from 'solid-js'
import { ActionButton } from '../components/ActionButton'
import { createPollingResource } from '../polling'
import { BotListActions } from './BotListActions'
import { countsLabel, formatElapsed, relativeActivity, sectionOrder } from './boardView'
import { botsClient } from './client'
import type { BotGrouping, BotOverviewRow } from './contracts'
import './bots.css'

const sectionTitles = {
  active: 'Active',
  working: 'Working',
  snoozed: 'Snoozed',
  settled: 'Settled',
}

// NodeExecutionBackend in Sources/RielaCore/WorkflowModel.swift.
const drivers = [
  ['codex-agent', 'Codex'],
  ['claude-code-agent', 'Claude Code'],
  ['cursor-cli-agent', 'Cursor CLI'],
  ['official/openai-sdk', 'OpenAI SDK'],
  ['official/anthropic-sdk', 'Anthropic SDK'],
  ['official/gemini-sdk', 'Gemini SDK'],
  ['official/cursor-sdk', 'Cursor SDK'],
] as const

export function BotsView(props: { profileKey: string; onOpenBot: (botId: string) => void }) {
  const [groupBy, setGroupBy] = createSignal<BotGrouping>('none')
  const [creating, setCreating] = createSignal(false)
  const [busy, setBusy] = createSignal(false)
  const [actionError, setActionError] = createSignal<unknown>()
  const list = createPollingResource(
    () => JSON.stringify([props.profileKey, groupBy()]),
    (signal) => botsClient.listBots(groupBy(), signal),
  )
  const rowsById = createMemo(() => new Map(list.data()?.bots.map((row) => [row.bot.botId, row])))
  const groupsByKey = createMemo(() => new Map(list.data()?.groups.map((group) => [group.key, group])))

  const mutate = async (operation: () => Promise<unknown>) => {
    if (busy()) return
    setBusy(true)
    setActionError(undefined)
    try {
      await operation()
      await list.refresh()
    } catch (error) {
      setActionError(error)
    } finally {
      setBusy(false)
    }
  }

  const createBot = (form: HTMLFormElement) => {
    const fields = new FormData(form)
    const name = String(fields.get('name') ?? '').trim()
    const defaultBackend = String(fields.get('backend') ?? '') || undefined
    const defaultModel = String(fields.get('model') ?? '').trim() || undefined
    if (!name) return
    void mutate(async () => {
      await botsClient.createBot({ name, defaultBackend, defaultModel })
      setCreating(false)
    })
  }

  const renderRow = (botId: string) => {
    const row = () => rowsById().get(botId)
    return <Show when={row()}>{(botRow) =>
      <BotRow row={botRow()} busy={busy()} onOpen={() => props.onOpenBot(botId)} mutate={mutate} />
    }</Show>
  }

  return <section class="bots-page" aria-label="Bots">
    <header class="bots-header">
      <h1>Bots</h1>
      <div class="bot-actions">
        <label>Group by <select value={groupBy()} onChange={(event) => setGroupBy(event.currentTarget.value === 'workspace' ? 'workspace' : 'none')}>
          <option value="none">None</option>
          <option value="workspace">Workspace</option>
        </select></label>
        <ActionButton aria-expanded={creating()} onClick={() => setCreating(!creating())}>New bot</ActionButton>
      </div>
    </header>

    <Show when={creating()}>
      <form class="panel bots-form" onSubmit={(event) => { event.preventDefault(); createBot(event.currentTarget) }}>
        <label>Name<input name="name" required /></label>
        <label>Backend<select name="backend">
          <option value="">Default</option>
          <For each={drivers}>{([value, label]) => <option value={value}>{label}</option>}</For>
        </select></label>
        <label>Model<input name="model" placeholder="Default" /></label>
        <ActionButton type="submit" disabled={busy()}>Create bot</ActionButton>
      </form>
    </Show>

    <Show when={actionError()}>{(error) => <p role="alert">{String(error())}</p>}</Show>
    <Show when={list.error()}>{(error) => <p role="alert">{String(error())}</p>}</Show>
    <Show when={list.loading() && !list.data()}><p role="status">Loading bots…</p></Show>
    <Show when={list.data()?.bots.length === 0}><p>No bots yet.</p></Show>

    <For each={sectionOrder}>{(section) => {
      const rows = createMemo(() => list.data()?.bots.filter((row) => row.section === section) ?? [])
      const ids = createMemo(() => rows().map((row) => row.bot.botId))
      const sectionIds = createMemo(() => new Set(ids()))
      const keys = createMemo(() => list.data()?.groups
        .filter((group) => group.botIds.some((id) => sectionIds().has(id)))
        .map((group) => group.key) ?? [])
      return <Show when={rows().length > 0}>
        <details class="bots-section" open={section === 'active'}>
          <summary>{sectionTitles[section]} <small>{rows().length}</small></summary>
          <Show when={groupBy() === 'workspace'} fallback={<ul class="bots-rows"><For each={ids()}>{renderRow}</For></ul>}>
            <For each={keys()}>{(key) => {
              const group = () => groupsByKey().get(key)
              const groupIds = () => group()?.botIds.filter((id) => sectionIds().has(id))
              return <details class="bots-group" open>
                <summary>{key === 'ungrouped' ? 'Ungrouped' : key} <Show when={group()?.needsYou}><NeedsYouDot /></Show></summary>
                <ul class="bots-rows"><For each={groupIds()}>{renderRow}</For></ul>
              </details>
            }}</For>
          </Show>
        </details>
      </Show>
    }}</For>
  </section>
}

function NeedsYouDot() {
  return <span class="bots-dot" role="img" aria-label="Needs you" />
}

function BotRow(props: {
  row: BotOverviewRow
  busy: boolean
  onOpen: () => void
  mutate: (operation: () => Promise<unknown>) => Promise<void>
}) {
  const bot = () => props.row.bot
  const counts = () => props.row.counts
  return <li class="bots-row">
    <div class="bots-row-top">
      <div>
        <div class="bots-identity">
          <Show when={counts().needsYou > 0}><NeedsYouDot /></Show>
          <ActionButton type="button" icon={false} onClick={props.onOpen}>{bot().name}</ActionButton>
          <Show when={bot().paused}><span class="bots-meta">Paused</span></Show>
          <Show when={props.row.origin.remote !== 'local'}>
            <span class="bots-meta">{props.row.origin.serverName ?? props.row.origin.remote}</span>
          </Show>
        </div>
        <div class="bots-meta">
          <Show when={countsLabel(counts())}>{(label) => <span>{label()}</span>}</Show>
          <Show when={props.row.lastResult}><span>{props.row.lastResult}</span></Show>
          <Show when={props.row.lastActivityAt}>{(at) => <time datetime={at()}>{relativeActivity(at())}</time>}</Show>
        </div>
      </div>
      <div class="bot-actions">
        <BotListActions state={props.row.listState} snoozed={props.row.section === 'snoozed'}
          canSettle={counts().working + counts().waiting + counts().needsYou === 0} busy={props.busy}
          onChange={(change) => void props.mutate(() => botsClient.setListState({ botId: bot().botId, ...change }))} />
        <ActionButton type="button" disabled={props.busy}
          onClick={() => void props.mutate(() => botsClient.setPaused(bot().botId, !bot().paused))}>
          {bot().paused ? 'Resume' : 'Pause'}
        </ActionButton>
      </div>
    </div>
    <Show when={props.row.inProgress.length}>
      <ul class="bots-work"><For each={props.row.inProgress}>{(item) =>
        <li><strong>{item.title}</strong> <span class="bots-meta">{[
          item.workflowId !== item.title ? item.workflowId : undefined, item.stepId, item.nodeId, item.backend, item.model,
          item.elapsedMs == null ? undefined : formatElapsed(item.elapsedMs),
        ].filter(Boolean).join(' · ')}</span></li>
      }</For></ul>
    </Show>
  </li>
}
