import { For, Show, createEffect, createMemo, createResource, createSignal, on, onCleanup, untrack } from 'solid-js'
import { APIError, api, requireExpectedProfile } from '../api'
import { createActivityStream } from '../bots/activityStream'
import type { ActivityFeed } from '../bots/activityFeed'
import { botsClient } from '../bots/client'
import { ActionButton } from '../components/ActionButton'
import { MarkdownBody } from '../components/Markdown'
import { configurationClient } from '../config/client'
import type { WorkflowSources } from '../contracts'
import { readAskViewState, writeAskViewState } from '../profileViewState'
import type { HashRoute } from '../routes'
import { actionCard } from './actions'
import { citationLinks } from './citations'
import { askActivityReader, askClient } from './client'
import { askRemote, contextFromRoute } from './context'
import type { AskAction, AskSelection, AskSnapshot } from './contracts'
import { askEditor, askEntry } from './entry'
import { panelState } from './panelState'
import { pickerState, resolvedSelection } from './picker'
import './ask.css'

function errorCode(error: unknown): string {
  return error instanceof APIError ? error.code : 'request_failed'
}

export function AskPanel(props: {
  storageKey: string
  route: HashRoute | undefined
  profileName: string
  selectedRemote: string
  remoteLoading: boolean
  remoteName?: (remote: string) => string | undefined
}) {
  const restored = readAskViewState(props.storageKey)
  const [open, setOpen] = createSignal(restored.open)
  const [active, setActive] = createSignal(restored.active)
  const [snapshot, setSnapshot] = createSignal<AskSnapshot>()
  const [feed, setFeed] = createSignal<ActivityFeed>()
  const [error, setError] = createSignal<string>()
  const [streamError, setStreamError] = createSignal<string>()
  const [reloadNeeded, setReloadNeeded] = createSignal(false)
  const [pending, setPending] = createSignal(false)
  const [selection, setSelection] = createSignal<AskSelection>({})
  const [message, setMessage] = createSignal('')
  const [cleared, setCleared] = createSignal(false)
  const [entry, setEntry] = createSignal<ReturnType<typeof askEntry>>()
  let revision = 0
  let log: HTMLDivElement | undefined
  let followLog = true

  const [sources] = createResource(() => open() && (props.profileName || 'cli-serve'), async () => {
    const value = await api.get<WorkflowSources>('/api/v1/workflows/sources')
    return props.profileName ? requireExpectedProfile(value, props.profileName).discovered : value.discovered
  })
  const knownSources = () => sources.error ? [] : sources.latest ?? []
  const [botName] = createResource(() => {
    const route = props.route
    if (!open() || route?.view !== 'bot-detail') return false
    return { id: route.botId, remote: askRemote(route.remote ?? props.selectedRemote) }
  }, async ({ id, remote: target }) => {
    const value = await botsClient.getBot(id, target).catch(() => undefined)
    return value ? { id, remote: target, name: value.bot.name } : undefined
  })
  const routeContext = createMemo(() => contextFromRoute(props.route, {
    remote: props.selectedRemote,
    botName: (id, target) => {
      const value = botName.latest
      return value?.id === id && value.remote === target ? value.name : undefined
    },
    workflowId: (sourceId) => knownSources().find(({ id }) => id === sourceId)?.workflowId,
  }))
  const context = () => entry() ?? routeContext()
  const remote = () => askRemote(context().remote)
  const draftOwners = new Map<string, string>()
  const [providers] = createResource(() => open() && remote(), (target) => botsClient.getModelCatalog(target))
  const [configuration] = createResource(() => open() && remote() === 'local', () =>
    configurationClient.get().catch(() => undefined))
  const picker = createMemo(() => pickerState(providers.error || providers.loading ? [] : providers.latest ?? [],
    selection(), configuration.latest?.assistant))
  const state = createMemo(() => panelState({
    snapshot: snapshot(), feed: feed(), error: error() ?? streamError(), pending: pending(),
  }))

  createEffect(on([() => props.route, () => props.selectedRemote], () => {
    setEntry(undefined)
    setCleared(false)
  }))
  createEffect(on(askEntry, (next) => {
    if (!next) return
    setEntry(next)
    setCleared(false)
    setOpen(true)
  }, { defer: true }))
  createEffect(() => {
    if (open() && state().items.length && followLog) {
      queueMicrotask(() => { if (log?.isConnected) log.scrollTop = log.scrollHeight })
    }
  })

  const reset = () => {
    revision++
    setActive(undefined)
    setSnapshot(undefined)
    setFeed(undefined)
    setError(undefined)
    setStreamError(undefined)
    setReloadNeeded(false)
    setPending(false)
    setSelection({})
    draftOwners.clear()
  }

  createEffect((previous?: string) => {
    const target = remote()
    if (previous !== undefined && previous !== target) untrack(reset)
    return target
  })

  createEffect(() => writeAskViewState(props.storageKey, { open: open(), active: active() }))

  function accept(value: AskSnapshot) {
    setSnapshot(value)
    setSelection(value.conversation.selection)
  }

  createEffect(() => {
    const current = active()
    if (!open() || !current || current.remote !== remote() || untrack(snapshot)) return
    const controller = new AbortController()
    const started = revision
    setPending(true)
    void askClient.get(current.conversationId, current.remote, controller.signal).then((value) => {
      if (!controller.signal.aborted && started === revision) accept(value)
    }).catch((failure: unknown) => {
      if (!controller.signal.aborted && started === revision) setError(errorCode(failure))
    }).finally(() => {
      if (!controller.signal.aborted && started === revision) setPending(false)
    })
    onCleanup(() => {
      controller.abort()
      if (started === revision) setPending(false)
    })
  })

  const turnKey = createMemo(() => {
    const turn = snapshot()?.conversation.turn
    return turn?.status === 'running' ? turn.turnId : undefined
  })

  async function reload(conversationId: string, target: string, started: number, signal?: AbortSignal) {
    try {
      const next = await askClient.get(conversationId, target, signal)
      if (started !== revision || signal?.aborted) return
      setReloadNeeded(false)
      setStreamError(undefined)
      accept(next)
    } catch (failure) {
      if (started !== revision || signal?.aborted) return
      setStreamError(errorCode(failure))
      setReloadNeeded(true)
    }
  }

  createEffect(() => {
    if (!open() || !turnKey()) return
    const current = active()
    if (!current || current.remote !== remote()) return
    const controller = new AbortController()
    const started = revision
    setFeed(undefined)
    setStreamError(undefined)
    setReloadNeeded(false)
    const stop = createActivityStream(askActivityReader(askClient, current.conversationId, current.remote), (update) => {
      if (started !== revision) return
      setFeed(update.feed)
      setStreamError(update.error ? errorCode(update.error) : undefined)
      if (update.ended) void reload(current.conversationId, current.remote, started, controller.signal)
    })
    onCleanup(() => { stop(); controller.abort() })
  })

  const mutate = async (operation: () => Promise<AskSnapshot>, after?: (value: AskSnapshot) => void) => {
    if (pending()) return
    const started = revision
    setPending(true)
    setError(undefined)
    try {
      const value = await operation()
      if (started !== revision) return
      accept(value)
      after?.(value)
    } catch (failure) {
      if (started === revision) setError(errorCode(failure))
    } finally {
      if (started === revision) setPending(false)
    }
  }

  const canSend = () => state().canSend && !props.remoteLoading &&
    (!active() || active()?.remote !== remote() || !!snapshot()) &&
    (!selection().providerInstanceId || !!picker().input.providerInstanceId)
  const send = () => {
    const text = message().trim()
    if (!text || !canSend()) return
    const target = remote()
    const current = active()
    const editor = target === 'local' ? askEditor() : undefined
    const routeRef = context().context
    const input = {
      message: text,
      context: cleared() ? { kind: 'none' } as const : routeRef,
      draftDefinition: editor?.draft(),
      remote: target,
    }
    void mutate(() => current?.remote === target && snapshot()
      ? askClient.send({ ...input, conversationId: current.conversationId })
      : askClient.start({ ...input, selection: picker().input }), (value) => {
      const turn = value.conversation.turn
      if (editor && turn) draftOwners.set(turn.turnId, editor.key)
      setActive({ conversationId: value.conversation.conversationId, remote: target })
      setMessage('')
    })
  }

  const editorFor = (action: AskAction) => {
    const editor = askEditor()
    if (!editor || action.kind !== 'applyWorkflow' || action.target.mode !== 'draft' || remote() !== 'local') return
    const ownerKey = draftOwners.get(action.turnId)
    const ref = snapshot()?.conversation.context
    const workflowId = ref?.kind === 'workflow' ? ref.id : action.target.baseWorkflowId ?? action.target.workflowId
    if (ownerKey ? editor.key === ownerKey : editor.workflowId() === workflowId) return editor
  }

  const decide = (action: AskAction, confirm: boolean) => {
    const current = active()
    if (!current || state().running || !actionCard(action).canDecide) return
    const isDraft = confirm && action.kind === 'applyWorkflow' && action.target.mode === 'draft'
    const editor = isDraft ? editorFor(action) : undefined
    if (isDraft && !editor) { setError('Open the workflow editor to apply'); return }
    if (editor && !editor.canApply()) { setError('Workflow editor is busy'); return }
    const request = confirm ? askClient.confirm.bind(askClient) : askClient.dismiss.bind(askClient)
    void mutate(() => request(current.conversationId, action.actionId, current.remote), (value) => {
      const result = value.actions.find(({ actionId }) => actionId === action.actionId)
      if (!editor || result?.kind !== 'applyWorkflow' || result.status !== 'confirmed' || !result.result?.ok) return
      if (askEditor() !== editor || !editor.canApply()) { setError('Open the workflow editor to apply'); return }
      editor.apply(result.target.definition)
    })
  }

  const stop = () => {
    const current = active()
    if (current) void mutate(() => askClient.cancel(current.conversationId, current.remote))
  }
  const origin = () => snapshot()?.origin.serverName || props.remoteName?.(remote()) || remote()
  const lockedPicker = () => !!snapshot() || pending()
  const sourceForWorkflow = (id: string) => knownSources().find((source) => source.workflowId === id)?.id
  const messageLinks = (citations: Parameters<typeof citationLinks>[0]) =>
    citationLinks(citations, active()?.remote ?? remote(), sourceForWorkflow)

  return <div class="ask-dock">
    <ActionButton class="ask-rail" aria-controls="ask-panel" aria-expanded={open()} onClick={() => setOpen(!open())}>Ask</ActionButton>
    <Show when={open()}>
      <aside class="ask-panel panel" id="ask-panel" aria-label="Ask Riela">
        <header class="ask-header">
          <div class="ask-row">
            <h2>Ask Riela</h2>
            <ActionButton class="secondary" disabled={!state().canSend} onClick={reset}>New</ActionButton>
            <ActionButton class="secondary" onClick={() => setOpen(false)} aria-label="Close Ask Riela">Close</ActionButton>
          </div>
          <div class="ask-row">
            <Show when={!cleared() && context().label}>
              <ActionButton class="secondary ask-context" aria-label={`Clear context ${context().label}`}
                onClick={() => setCleared(true)}>{context().label} ×</ActionButton>
            </Show>
            <span class="status-chip">{origin()}</span>
          </div>
          <div class="ask-pickers">
            <label>Vendor<select disabled={lockedPicker()} value={selection().providerInstanceId ?? ''}
              onChange={(event) => setSelection({ providerInstanceId: event.currentTarget.value || undefined })}>
              <option value="">{remote() === 'local' ? picker().defaultLabel : 'Server default'}</option>
              <For each={picker().providers}>{(provider) => <option value={provider.instanceId}>{provider.label}</option>}</For>
            </select></label>
            <Show when={selection().providerInstanceId}>
              <label>Model<select disabled={lockedPicker()} value={selection().model ?? ''}
                onChange={(event) => setSelection({ ...selection(), model: event.currentTarget.value || undefined, effort: undefined })}>
                <option value="">Default</option>
                <For each={picker().models}>{(model) => <option value={model.id}>{model.label ?? model.id}</option>}</For>
              </select></label>
            </Show>
            <Show when={picker().efforts.length > 0}>
              <label>Effort<select disabled={lockedPicker()} value={selection().effort ?? ''}
                onChange={(event) => setSelection({ ...selection(), effort: event.currentTarget.value || undefined })}>
                <option value="">Default</option>
                <For each={picker().efforts}>{(effort) => <option value={effort}>{effort}</option>}</For>
              </select></label>
            </Show>
          </div>
          <Show when={snapshot()?.conversation.turn}>{(turn) => <small>{resolvedSelection(turn())}</small>}</Show>
          <Show when={providers.error}><small role="status">{errorCode(providers.error)}</small></Show>
          <For each={snapshot()?.warnings}>{(warning) => <small role="status">{warning}</small>}</For>
        </header>
        <div class="ask-log" role="log" aria-label="Conversation" ref={log}
          onScroll={(event) => {
            const el = event.currentTarget
            followLog = el.scrollHeight - el.clientHeight - el.scrollTop < 40
          }}>
          <For each={state().items}>{(item) => {
            if (item.kind === 'stored') return item.message.role === 'user'
              ? <p class="ask-user">{item.message.text}</p>
              : <MarkdownBody markdown={item.message.text} citations={messageLinks(item.message.citations)} />
            if (item.kind === 'action') {
              const card = actionCard(item.action)
              return <article class="ask-action">
                <strong>{card.title}</strong>
                <Show when={card.detail}><p>{card.detail}</p></Show>
                <Show when={card.canDecide} fallback={<small>{card.state}</small>}>
                  <div class="ask-row">
                    <ActionButton disabled={pending() || state().running} onClick={() => decide(item.action, true)}>Confirm</ActionButton>
                    <ActionButton class="secondary" disabled={pending() || state().running} onClick={() => decide(item.action, false)}>Dismiss</ActionButton>
                  </div>
                </Show>
              </article>
            }
            if (item.kind === 'answer') return <MarkdownBody markdown={item.text} citations={new Map()} />
            return <p classList={{ 'field-error': item.kind === 'error', 'ask-activity': item.kind !== 'error' }}
              role={item.kind === 'error' ? 'alert' : undefined}>{item.text}</p>
          }}</For>
          <Show when={reloadNeeded() && active()}>{(current) => <ActionButton class="secondary"
            onClick={() => void reload(current().conversationId, current().remote, revision)}>Retry</ActionButton>}</Show>
        </div>
        <form class="ask-composer" onSubmit={(event) => { event.preventDefault(); send() }}>
          <textarea aria-label="Message" placeholder="Ask Riela" rows="2" value={message()}
            onInput={(event) => setMessage(event.currentTarget.value)} />
          <div class="ask-row">
            <ActionButton type="submit" disabled={!message().trim() || !canSend()}>Send</ActionButton>
            <Show when={state().running}><ActionButton class="secondary" disabled={pending()} onClick={stop}>Stop</ActionButton></Show>
          </div>
        </form>
      </aside>
    </Show>
  </div>
}
