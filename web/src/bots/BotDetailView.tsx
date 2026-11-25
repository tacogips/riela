import { openAsk } from '../ask/entry'
import { For, Show, createMemo, createSignal, onCleanup } from 'solid-js'
import { APIError } from '../api'
import { ActionButton } from '../components/ActionButton'
import { createPollingResource } from '../polling'
import { botActivityReader, createActivityStream } from './activityStream'
import { activitySummary, type ActivityFeed } from './activityFeed'
import { boardOrder, boardRunHash, formatBotTime, formatElapsed, groupTitles, originAllowsActions, statusLabel } from './boardView'
import { BotListActions } from './BotListActions'
import { botsClient } from './client'
import type { AnswerBotRequestInput, BotBoardGroup, BotBoardItem, BotOverviewRow, BotPlan, SetBotListStateInput } from './contracts'
import { BotForm } from './BotForm'
import { BotMemoryPanel } from './BotMemoryPanel'
import { BotSuggestionsPanel } from './BotSuggestionsPanel'
import { managementError } from './remoteSelection'
import './bots.css'

function itemKey(item: BotBoardItem) {
  return JSON.stringify([item.itemKind, item.itemId])
}

export function BotDetailView(props: { profileKey: string; row: BotOverviewRow; onChange: () => void }) {
  const botId = props.row.bot.botId
  const remote = props.row.origin.remote
  const [editing, setEditing] = createSignal(false)
  const [memoryRevision, setMemoryRevision] = createSignal(0)
  const [jobResult, setJobResult] = createSignal<string>()
  const [selectedKey, setSelectedKey] = createSignal<string>()
  const [busy, setBusy] = createSignal(false)
  const [actionError, setActionError] = createSignal<unknown>()
  const detail = createPollingResource(
    () => JSON.stringify([props.profileKey, remote, botId]),
    (signal) => botsClient.getBot(botId, remote, signal),
  )
  const trustedDetail = () => {
    const value = detail.data()
    return value && originAllowsActions(value.origin, remote) ? value : undefined
  }
  const itemsByKey = createMemo(() => new Map(
    boardOrder.flatMap((group) => trustedDetail()?.board[group] ?? []).map((item) => [itemKey(item), item]),
  ))
  const selectedItem = () => itemsByKey().get(selectedKey() ?? '')
  const activityKey = () => {
    const item = selectedItem()
    return item?.sessionId ? JSON.stringify([props.profileKey, itemKey(item), item.sessionId]) : undefined
  }

  const mutate = async (operation: () => Promise<unknown>, answering = false) => {
    if (busy() || detail.error() || !trustedDetail()) return false
    setBusy(true)
    setActionError(undefined)
    try {
      try {
        await operation()
      } catch (error) {
        if (!answering || !(error instanceof APIError)
          || !['request_already_resolved', 'request_expired'].includes(error.code ?? '')) throw error
      }
      await detail.refresh()
      props.onChange()
      return true
    } catch (error) {
      setActionError(error)
      return false
    } finally {
      setBusy(false)
    }
  }

  const blocked = () => !!detail.error()

  return <section class="bots-detail" aria-label="Bot details">
    <header class="bots-header">
      <h2>{props.row.bot.name}</h2>
      <ActionButton class="secondary" onClick={() => openAsk({
        context: { kind: 'bot', id: botId }, label: `Bot ${props.row.bot.name}`, remote,
      })}>Ask</ActionButton>
      <Show when={trustedDetail() && !detail.error()}>
        <ActionButton aria-expanded={editing()} onClick={() => setEditing(!editing())}>Edit bot</ActionButton>
      </Show>
    </header>
    <Show when={editing() && trustedDetail() && !detail.error()}>
      <BotForm remote={remote} bot={trustedDetail()!.bot} busy={busy()}
        onSubmit={(input) => void mutate(async () => {
          await botsClient.updateBot({ botId, ...input }, remote)
          setEditing(false)
        })} />
    </Show>
    <Show when={actionError()}>{(error) => <p role="alert">{managementError(error())}</p>}</Show>
    <Show when={detail.error()}>{(error) => <p role="alert">{managementError(error())}</p>}</Show>
    <Show when={detail.loading() && !detail.data()}><p role="status">Loading bot…</p></Show>
    <Show when={detail.data() && !trustedDetail()}><p role="alert">Bot origin unverified.</p></Show>
    <Show when={trustedDetail()}>{(data) =>
      <div class="bot-detail-layout">
        <div class="bot-board">
          <For each={boardOrder}>{(group) => {
            const keys = createMemo(() => data().board[group].map(itemKey))
            const closedLabel = () => group === 'closed' && data().board.closedTotal > keys().length
              ? `${keys().length} of ${data().board.closedTotal}` : keys().length
            return <details class="bots-section" open={group !== 'closed'}>
              <summary>{groupTitles[group]} <small>{closedLabel()}</small></summary>
              <ul class="bots-rows">
                <For each={keys()}>{(key) =>
                  <Show when={itemsByKey().get(key)}>{(item) =>
                    <BoardCard item={item()} group={group} remote={remote} selected={selectedKey() === key} busy={busy() || blocked()}
                      onSelect={() => setSelectedKey(key)}
                      onAnswer={(input) => void mutate(() => botsClient.answerRequest(input, remote), true)}
                      onCorrection={(text) => mutate(async () => {
                        await botsClient.captureFeedback(botId, item().sessionId!, text, remote)
                        setMemoryRevision((value) => value + 1)
                      })}
                      onListChange={(change) => void mutate(() => botsClient.setListState({
                        botId, itemKind: item().itemKind, itemId: item().itemId, ...change,
                      }, remote))} />
                  }</Show>
                }</For>
              </ul>
            </details>
          }}</For>
          <Show when={data().routines.length}>
            <section class="bots-routines">
              <h2>Routines</h2>
              <ul class="bots-rows"><For each={data().routines}>{(routine) =>
                <li class="bots-row"><strong>{routine.name}</strong> <span class="bots-meta">{statusLabel(routine.status)}
                  <Show when={routine.nextRunAt}>{(at) => <time datetime={at()}>Next {formatBotTime(at())}</time>}</Show>
                </span></li>
              }</For></ul>
            </section>
          </Show>
          <section class="panel bot-management" aria-label="Bot jobs">
            <h2>Jobs</h2>
            <ul class="bots-rows"><For each={data().jobs}>{(job) =>
              <li class="bots-row bots-row-top">
                <div>
                  <strong>{job.job === 'upkeep' ? 'Memory upkeep' : 'Look around'}</strong>
                  <div class="bots-meta">{statusLabel(job.schedule)}
                    <Show when={job.lastRun}>{(run) =>
                      <span>{statusLabel(run().status)} · {formatBotTime(run().startedAt)}</span>
                    }</Show>
                  </div>
                </div>
                <ActionButton type="button" disabled={busy() || blocked()} onClick={() => void mutate(async () => {
                  setJobResult(undefined)
                  const result = await botsClient.runJob(botId, job.job, remote)
                  setJobResult([statusLabel(result.status), result.detail].filter(Boolean).join(' · '))
                })}>Run now</ActionButton>
              </li>
            }</For></ul>
            <Show when={jobResult()}>{(result) => <p role="status">{result()}</p>}</Show>
          </section>
          <BotMemoryPanel botId={botId} remote={remote} revision={memoryRevision()} disabled={blocked()} />
          <BotSuggestionsPanel botId={botId} remote={remote} disabled={blocked()} onChange={() => {
            void detail.refresh()
            props.onChange()
          }} />
        </div>
        <Show when={activityKey()} keyed>{(_key) =>
          <ActivityPane remote={remote} sessionId={selectedItem()!.sessionId!} title={selectedItem()!.title}
            onClose={() => setSelectedKey(undefined)} />
        }</Show>
      </div>
    }</Show>
  </section>
}

function BoardCard(props: {
  item: BotBoardItem
  group: BotBoardGroup
  remote: string
  selected: boolean
  busy: boolean
  onSelect: () => void
  onAnswer: (input: AnswerBotRequestInput) => void
  onListChange: (change: Partial<SetBotListStateInput>) => void
  onCorrection: (text: string) => Promise<boolean>
}) {
  const item = () => props.item
  const [correction, setCorrection] = createSignal('')
  const runHash = () => boardRunHash(props.group, item(), props.remote)
  return <li class="bots-row bot-card" classList={{ 'bot-card-selected': props.selected }}>
    <div class="bots-row-top">
      <div>
        <Show when={runHash()} fallback={<strong>{item().title}</strong>}>{(href) =>
          <a class="bot-run-link" href={href()}>{item().title}</a>
        }</Show>
        <div class="bots-meta">{[
          item().stepId, item().nodeId, item().backend, item().model,
          item().elapsedMs == null ? undefined : formatElapsed(item().elapsedMs!),
        ].filter(Boolean).join(' · ')}</div>
      </div>
      <Show when={item().sessionId}>
        <ActionButton type="button" aria-pressed={props.selected} onClick={props.onSelect}>Activity</ActionButton>
      </Show>
    </div>
    <div class="bots-meta">
      <span>{statusLabel(item().status)}</span>
      <span>Source: {item().activitySource}</span>
      <Show when={item().waitingReason && item().waitingReason !== item().status}><span>{item().waitingReason}</span></Show>
      <Show when={item().limitedResetAt}>{(at) => <time datetime={at()}>Resets {formatBotTime(at())}</time>}</Show>
    </div>
    <Show when={item().doingNow}><div>{item().doingNow}</div></Show>
    <Show when={item().lastResult}><div>{item().lastResult}</div></Show>
    <PlanEntries plans={item().checklist} />
    <Show when={props.group === 'needsYou' && item().answerPath === 'bot'}>
      <For each={item().pendingRequests}>{(request) =>
        <div class="bot-request">
          <strong>{request.title ?? 'Permission request'}</strong>
          <div class="bot-actions">
            <For each={request.options}>{(option) =>
              <ActionButton type="button" disabled={props.busy}
                onClick={() => props.onAnswer({ requestId: request.requestId, optionId: option.optionId })}>
                {option.name}
              </ActionButton>
            }</For>
            <ActionButton type="button" disabled={props.busy}
              onClick={() => props.onAnswer({ requestId: request.requestId, decline: true })}>Decline</ActionButton>
          </div>
        </div>
      }</For>
    </Show>
    <Show when={props.group === 'needsYou' && item().answerPath === 'task' && item().question}>{(question) =>
      <div class="bot-request">
        <strong>{question().text}</strong>
        <span class="bots-meta">{item().itemKind === 'task' ? 'Task' : 'Session'} {item().itemId}</span>
      </div>
    }</Show>
    <Show when={props.group === 'closed' && item().sessionId}>
      <form class="bot-actions" onSubmit={(event) => {
        event.preventDefault()
        const text = correction().trim()
        if (text) void props.onCorrection(text).then((saved) => { if (saved) setCorrection('') })
      }}>
        <label>Correction <input value={correction()} disabled={props.busy}
          onInput={(event) => setCorrection(event.currentTarget.value)} /></label>
        <ActionButton type="submit" disabled={props.busy || !correction().trim()}>Save correction</ActionButton>
      </form>
    </Show>
    <Show when={item().itemKind === 'session' || item().itemKind === 'task'}>
      <details class="bot-card-actions">
        <summary>List actions</summary>
        <BotListActions state={item().listState} snoozed={false} busy={props.busy}
          canSettle={item().pendingRequests.length === 0 && (props.group === 'planned' || props.group === 'closed')} onChange={props.onListChange} />
      </details>
    </Show>
  </li>
}

function PlanEntries(props: { plans: BotPlan[] }) {
  return <Show when={props.plans.length}>
    <ul class="bots-work"><For each={props.plans}>{(plan) =>
      <For each={plan.entries}>{(entry) => <li><span class="bots-meta">{statusLabel(entry.status)}</span> {entry.content}</li>}</For>
    }</For></ul>
  </Show>
}

export function ActivityPane(props: { sessionId: string; remote: string; title: string; onClose?: () => void }) {
  const [feed, setFeed] = createSignal<ActivityFeed>()
  const [error, setError] = createSignal<unknown>()
  onCleanup(createActivityStream(botActivityReader(botsClient, props.sessionId, props.remote), (update) => {
    setFeed(update.feed)
    setError(update.error)
  }))

  return <aside class="panel bots-activity" aria-label="Bot activity">
    <header class="bots-header">
      <h2>{props.title} activity</h2>
      <Show when={props.onClose}><ActionButton type="button" onClick={props.onClose}>Close</ActionButton></Show>
    </header>
    <Show when={error()}>{(requestError) => <p role="alert">{String(requestError())} · Retrying…</p>}</Show>
    <Show when={!feed() && !error()}><p role="status">Loading activity…</p></Show>
    <Show when={feed()}>{(activity) => <>
      <div class="bots-meta"><span>Source: {activity().activitySource}</span><span>{statusLabel(activity().sessionStatus)}</span></div>
      <Show when={activity().truncated}>
        <p class="bots-meta">Earlier activity was trimmed.</p>
        <Show when={activity().state}>{(state) => <>
          <Show when={state().currentStepId}><p>{state().currentStepId}</p></Show>
          <Show when={state().lastMessageLine}><p>{state().lastMessageLine}</p></Show>
          <PlanEntries plans={state().plans} />
          <For each={state().toolCalls}>{(tool) => <div>{tool.title ?? tool.toolCallId} <span class="bots-meta">{tool.status ? statusLabel(tool.status) : ''}</span></div>}</For>
          <Show when={state().pendingRequestIds.length}><p>{state().pendingRequestIds.length} pending</p></Show>
        </>}</Show>
      </Show>
      <Show when={activity().events.length} fallback={<p>No activity events.</p>}>
        <ol class="bots-events" aria-label="Activity events"><For each={activity().events}>{(event) =>
          <li><time datetime={event.at}>{formatBotTime(event.at)}</time><span>{activitySummary(event)}</span></li>
        }</For></ol>
      </Show>
    </>}</Show>
  </aside>
}
