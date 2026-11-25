import { For, Show, createMemo, createSignal } from 'solid-js'
import { ActionButton } from '../components/ActionButton'
import { createPollingResource } from '../polling'
import { BotListActions } from './BotListActions'
import { boardRunHash, formatElapsed, originAllowsActions, overviewPresentation, relativeActivity, sectionOrder } from './boardView'
import { botsClient } from './client'
import type { BotGrouping, BotOverviewRow } from './contracts'
import { BotDetailView } from './BotDetailView'
import { BotForm } from './BotForm'
import { RemoteSwitcher } from './RemoteSwitcher'
import { managementError, readRemoteTargets, remoteArgument, type RemoteSelection } from './remoteSelection'
import './bots.css'

const visibleSections = [...sectionOrder, 'disconnected'] as const

const sectionTitles = {
  active: 'Active',
  working: 'Working',
  snoozed: 'Snoozed',
  settled: 'Settled',
  disconnected: 'Disconnected',
}

export function BotsView(props: {
  profileKey: string
  remote: RemoteSelection
  selection?: { botId: string; remote?: string }
  onOpenBot: (botId: string, remote?: string) => void
  onBack: () => void
}) {
  const remote = props.remote
  const [groupBy, setGroupBy] = createSignal<BotGrouping>('none')
  const [creating, setCreating] = createSignal(false)
  const [busy, setBusy] = createSignal(false)
  const [actionError, setActionError] = createSignal<string>()
  const list = createPollingResource(
    () => remote.registry.loading && !remote.snapshot()
      ? undefined : JSON.stringify([props.profileKey, groupBy(), remote.targets()]),
    (signal) => readRemoteTargets(remote.targets(), (name) => botsClient.listBots(groupBy(), name, signal)),
  )
  const rows = createMemo(() => list.data()?.values.flatMap((value) => value.bots) ?? [])
  const selected = createMemo(() => {
    const target = props.selection
    const available = rows().filter((row) => overviewPresentation(row).actionsEnabled)
    if (!target) return available.find((row) => row.section === 'active')
    const targetRemote = target.remote ?? (remote.selection() === '*' ? 'local' : remote.selection())
    return available.find((row) => row.bot.botId === target.botId && row.origin.remote === targetRemote)
  })
  const createTarget = () => {
    const name = remote.selection()
    if (name === '*') return undefined
    return list.data()?.values.some(({ origin, bots }) =>
      origin ? originAllowsActions(origin, name)
        : name === 'local' || bots.some((row) => originAllowsActions(row.origin, name))) ? name : undefined
  }
  const selectedKey = () => {
    const row = selected()
    return row ? JSON.stringify([row.origin.remote, row.origin.serverId, row.bot.botId]) : undefined
  }

  const mutate = async (operation: () => Promise<unknown>) => {
    if (busy()) return
    setBusy(true)
    setActionError(undefined)
    try {
      await operation()
      await list.refresh()
    } catch (error) {
      setActionError(managementError(error))
    } finally {
      setBusy(false)
    }
  }

  const renderRow = (row: BotOverviewRow) =>
    <BotRow row={row} busy={busy()} selected={selected() === row}
      onOpen={() => props.onOpenBot(row.bot.botId, row.origin.remote)}
      target={remoteArgument(remote.selection(), row.origin.remote)}
      mutate={mutate} />

  return <section class="bots-page" aria-label="Bots">
    <header class="bots-header">
      <h1>Bots</h1>
      <RemoteSwitcher remote={remote} onSelect={() => {
        setCreating(false)
        props.onBack()
      }} />
    </header>
    <div class="bots-master-detail" classList={{ 'bots-detail-open': !!props.selection }}>
      <aside class="bots-list-pane" aria-label="Bot list">
        <div class="bot-actions">
          <label>Group by <select value={groupBy()} onChange={(event) => setGroupBy(event.currentTarget.value === 'workspace' ? 'workspace' : 'none')}>
            <option value="none">None</option>
            <option value="workspace">Workspace</option>
          </select></label>
          <Show when={createTarget()}>
            <ActionButton aria-expanded={creating()} onClick={() => setCreating(!creating())}>New bot</ActionButton>
          </Show>
        </div>
        <Show when={creating() && createTarget()} keyed>{(target) =>
          <BotForm remote={target} busy={busy()} onSubmit={(input) => void mutate(async () => {
            await botsClient.createBot(input, target)
            setCreating(false)
          })} />
        }</Show>
        <Show when={actionError()}>{(error) => <p role="alert">{error()}</p>}</Show>
        <For each={list.data()?.failures}>{(failure) =>
          <p role="alert">{failure.remote} · {failure.code}</p>
        }</For>
        <Show when={list.loading() && !list.data()}><p role="status">Loading bots…</p></Show>
        <Show when={list.data()?.values.length && !rows().length}><p>No bots yet.</p></Show>
        <For each={visibleSections}>{(section) => {
          const sectionRows = createMemo(() => rows().filter((row) => overviewPresentation(row).section === section))
          const groups = createMemo(() => [...new Set(sectionRows().map((row) => row.workspaceGroup))])
          return <Show when={sectionRows().length > 0}>
            <details class="bots-section" open={section === 'active' || section === 'working' || section === 'disconnected'}>
              <summary>{sectionTitles[section]} <small>{sectionRows().length}</small></summary>
              <Show when={groupBy() === 'workspace' && section !== 'disconnected'}
                fallback={<ul class="bots-rows"><For each={sectionRows()}>{renderRow}</For></ul>}>
                <For each={groups()}>{(group) => {
                  const groupRows = createMemo(() => sectionRows().filter((row) => row.workspaceGroup === group))
                  return <details class="bots-group" open>
                    <summary>{group === 'ungrouped' ? 'Ungrouped' : group}
                      <Show when={groupRows().some((row) => row.counts.needsYou > 0)}><NeedsYouDot /></Show>
                    </summary>
                    <ul class="bots-rows"><For each={groupRows()}>{renderRow}</For></ul>
                  </details>
                }}</For>
              </Show>
            </details>
          </Show>
        }}</For>
      </aside>
      <div class="bots-detail-pane">
        <Show when={props.selection}><ActionButton class="bots-list-back" onClick={props.onBack}>All bots</ActionButton></Show>
        <Show when={selectedKey()} keyed fallback={
          <Show when={list.data()}><p class="panel">{props.selection ? 'Bot unavailable.' : 'Select a bot.'}</p></Show>
        }>{(_key) =>
          <BotDetailView profileKey={props.profileKey} row={selected()!} onChange={() => void list.refresh()} />
        }</Show>
      </div>
    </div>
  </section>
}

function NeedsYouDot() {
  return <span class="bots-dot" role="img" aria-label="Needs you" />
}

function BotRow(props: {
  row: BotOverviewRow
  busy: boolean
  selected: boolean
  target: string
  onOpen: () => void
  mutate: (operation: () => Promise<unknown>) => Promise<void>
}) {
  const bot = () => props.row.bot
  const counts = () => props.row.counts
  const presentation = () => overviewPresentation(props.row)
  const origin = () => props.row.origin
  return <li class="bots-row" classList={{ 'bot-card-selected': props.selected }}>
    <div class="bots-row-top">
      <div>
        <div class="bots-identity">
          <Show when={presentation().section !== 'disconnected' && counts().needsYou > 0}><NeedsYouDot /></Show>
          <Show when={presentation().actionsEnabled} fallback={<strong>{bot().name}</strong>}>
            <ActionButton type="button" icon={false} aria-current={props.selected ? 'true' : undefined}
              onClick={props.onOpen}>{bot().name}</ActionButton>
          </Show>
          <Show when={presentation().section !== 'disconnected' && bot().paused}><span class="bots-meta">Paused</span></Show>
          <Show when={origin().remote !== 'local'}>
            <span class="bots-meta">{origin().serverName ?? origin().remote}</span>
          </Show>
          <Show when={!origin().verified}><span class="bots-meta">Unverified</span></Show>
        </div>
        <div class="bots-meta">
          <Show when={presentation().label}>{(label) => <span>{label()}</span>}</Show>
          <Show when={presentation().section !== 'disconnected' && props.row.lastActivityAt}>{(at) => <time datetime={at()}>{relativeActivity(at())}</time>}</Show>
        </div>
      </div>
      <Show when={presentation().actionsEnabled}><div class="bot-actions bots-row-actions">
        <BotListActions state={props.row.listState} snoozed={props.row.section === 'snoozed'}
          canSettle={counts().working + counts().waiting + counts().needsYou === 0} busy={props.busy}
          onChange={(change) => void props.mutate(() => botsClient.setListState({ botId: bot().botId, ...change }, props.target))} />
        <ActionButton type="button" disabled={props.busy}
          onClick={() => void props.mutate(() => botsClient.setPaused(bot().botId, !bot().paused, props.target))}>
          {bot().paused ? 'Resume' : 'Pause'}
        </ActionButton>
      </div></Show>
    </div>
    <Show when={presentation().section !== 'disconnected' && props.row.inProgress.length}>
      <ul class="bots-work"><For each={props.row.inProgress}>{(item) =>
        <li><Show when={boardRunHash('inProgress', item, props.target)} fallback={<strong>{item.title}</strong>}>{(href) =>
          <a class="bot-run-link" href={href()}>{item.title}</a>
        }</Show> <span class="bots-meta">{[
          item.workflowId !== item.title ? item.workflowId : undefined, item.stepId, item.nodeId, item.backend, item.model,
          item.elapsedMs == null ? undefined : formatElapsed(item.elapsedMs),
        ].filter(Boolean).join(' · ')}</span></li>
      }</For></ul>
    </Show>
  </li>
}
