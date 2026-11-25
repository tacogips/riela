import { For, Show, createMemo, createSignal, onCleanup } from 'solid-js'
import { APIError } from '../api'
import { ActionButton } from '../components/ActionButton'
import { createPollingResource } from '../polling'
import { createActivityStream } from './activityStream'
import { activitySummary, type ActivityFeed } from './activityFeed'
import { boardOrder, formatBotTime, formatElapsed, groupTitles, statusLabel } from './boardView'
import { BotListActions } from './BotListActions'
import { botsClient } from './client'
import type { AnswerBotRequestInput, BotBoardGroup, BotBoardItem, BotPlan, SetBotListStateInput } from './contracts'
import './bots.css'

function itemKey(item: BotBoardItem) {
  return JSON.stringify([item.itemKind, item.itemId])
}

export function BotDetailView(props: { profileKey: string; botId: string; onBack: () => void }) {
  const [selectedKey, setSelectedKey] = createSignal<string>()
  const [busy, setBusy] = createSignal(false)
  const [actionError, setActionError] = createSignal<unknown>()
  const detail = createPollingResource(
    () => JSON.stringify([props.profileKey, props.botId]),
    (signal) => botsClient.getBot(props.botId, signal),
  )
  const itemsByKey = createMemo(() => new Map(
    boardOrder.flatMap((group) => detail.data()?.board[group] ?? []).map((item) => [itemKey(item), item]),
  ))
  const selectedItem = () => itemsByKey().get(selectedKey() ?? '')
  const activityKey = () => {
    const item = selectedItem()
    return item?.sessionId ? JSON.stringify([props.profileKey, itemKey(item), item.sessionId]) : undefined
  }

  const mutate = async (operation: () => Promise<unknown>, answering = false) => {
    if (busy()) return
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
    } catch (error) {
      setActionError(error)
    } finally {
      setBusy(false)
    }
  }

  return <section class="bots-page" aria-label="Bot details">
    <header class="bots-header">
      <ActionButton onClick={props.onBack}>All bots</ActionButton>
      <h1>{detail.data()?.bot.name ?? 'Bot'}</h1>
    </header>
    <Show when={actionError()}>{(error) => <p role="alert">{String(error())}</p>}</Show>
    <Show when={detail.error()}>{(error) => <p role="alert">{String(error())}</p>}</Show>
    <Show when={detail.loading() && !detail.data()}><p role="status">Loading bot…</p></Show>
    <Show when={detail.data()}>{(data) =>
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
                    <BoardCard item={item()} group={group} selected={selectedKey() === key} busy={busy()}
                      onSelect={() => setSelectedKey(key)}
                      onAnswer={(input) => void mutate(() => botsClient.answerRequest(input), true)}
                      onListChange={(change) => void mutate(() => botsClient.setListState({
                        botId: props.botId, itemKind: item().itemKind, itemId: item().itemId, ...change,
                      }))} />
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
        </div>
        <Show when={activityKey()} keyed>{(_key) =>
          <ActivityPane sessionId={selectedItem()!.sessionId!} title={selectedItem()!.title}
            onClose={() => setSelectedKey(undefined)} />
        }</Show>
      </div>
    }</Show>
  </section>
}

function BoardCard(props: {
  item: BotBoardItem
  group: BotBoardGroup
  selected: boolean
  busy: boolean
  onSelect: () => void
  onAnswer: (input: AnswerBotRequestInput) => void
  onListChange: (change: Partial<SetBotListStateInput>) => void
}) {
  const item = () => props.item
  return <li class="bots-row bot-card" classList={{ 'bot-card-selected': props.selected }}>
    <div class="bots-row-top">
      <div>
        <strong>{item().title}</strong>
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

function ActivityPane(props: { sessionId: string; title: string; onClose: () => void }) {
  const [feed, setFeed] = createSignal<ActivityFeed>()
  const [error, setError] = createSignal<unknown>()
  onCleanup(createActivityStream(botsClient, props.sessionId, (update) => {
    setFeed(update.feed)
    setError(update.error)
  }))

  return <aside class="panel bots-activity" aria-label="Bot activity">
    <header class="bots-header">
      <h2>{props.title} activity</h2>
      <ActionButton type="button" onClick={props.onClose}>Close</ActionButton>
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
