import { rielaFetch } from '../transport'
import { For, Show, createSignal, onCleanup } from 'solid-js'
import { api } from '../api'
import { graphDocument, type GraphDocument } from './graph'

interface Generation {
  id: string
  profile: string
  revision: number
  status: 'running' | 'completed' | 'failed' | 'cancelled'
  definition: unknown
  messages: string[]
  error?: string
}

export function WorkflowAgentChat(props: {
  definition: GraphDocument
  disabled: boolean
  onStart: () => void
  onDefinition: (definition: GraphDocument) => void
  onActive: (active: boolean) => void
}) {
  const [message, setMessage] = createSignal('')
  const [active, setActive] = createSignal(false)
  const [error, setError] = createSignal('')
  const [history, setHistory] = createSignal<{ role: string; text: string }[]>([])
  const [replies, setReplies] = createSignal<string[]>([])
  let sessionId: string | undefined
  let controller: AbortController | undefined
  let timer: ReturnType<typeof setTimeout> | undefined
  let mounted = true
  let epoch = 0
  let revision = -1
  let sessionHeaders: Record<string, string> = {}
  const endpoint = '/api/v1/workflow-editor/generations'
  const request = async (path: string, method: string, body?: unknown, signal?: AbortSignal): Promise<Generation> => {
    const response = await rielaFetch(path, { method, credentials: 'same-origin', signal,
      headers: { ...sessionHeaders, 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) })
    const result = await response.json() as Omit<Generation, 'error'> & { error?: string | { message?: string } }
    if (!response.ok) throw new Error(typeof result.error === 'object' ? result.error.message : result.error ?? `Agent request failed (${response.status}).`)
    return result as Generation
  }
  const setRunning = (value: boolean) => { setActive(value); props.onActive(value) }
  const apply = (snapshot: Generation) => {
    if (snapshot.revision > revision) {
      // Reject malformed intermediate definitions before changing the visible graph.
      const definition = graphDocument(snapshot.definition)
      if (snapshot.revision > 0) props.onDefinition(definition)
      revision = snapshot.revision
      setReplies(snapshot.messages)
    }
    if (snapshot.status !== 'running') {
      setRunning(false)
      sessionId = undefined
      if (snapshot.error) setError(snapshot.error)
    }
  }
  const poll = async (generation: number) => {
    if (!mounted || generation !== epoch || !sessionId) return
    try {
      const snapshot = await request(`${endpoint}/${sessionId}`, 'GET', undefined, controller?.signal)
      if (!mounted || generation !== epoch) return
      apply(snapshot)
      if (snapshot.status === 'running') timer = setTimeout(() => void poll(generation), 400)
    } catch (failure) {
      if (!mounted || generation !== epoch) return
      setError(failure instanceof Error ? failure.message : String(failure))
      // Keep the current session live; retry observes that same generation.
    }
  }
  const send = async () => {
    if (!message().trim() || active() || props.disabled) return
    const text = message().trim()
    const generation = ++epoch
    controller = new AbortController()
    sessionHeaders = api.noteHeaders()
    revision = -1
    const previous = [...history(), ...replies().map((reply) => ({ role: 'Agent', text: reply }))]
    const context = previous.slice(-12).map((item) => ({ role: item.role === 'You' ? 'user' : 'assistant', text: item.text.slice(0, 4000) }))
    setHistory([...previous, { role: 'You', text }].slice(-40))
    setReplies([]); setError(''); setMessage(''); setRunning(true); props.onStart()
    try {
      const snapshot = await request(endpoint, 'POST', { message: text, history: context, definition: props.definition }, controller.signal)
      if (!mounted || generation !== epoch) {
        void request(`${endpoint}/${snapshot.id}`, 'DELETE', {}).catch(() => undefined)
        return
      }
      sessionId = snapshot.id
      apply(snapshot)
      if (snapshot.status === 'running') void poll(generation)
    } catch (failure) {
      if (!mounted || generation !== epoch) return
      setError(failure instanceof Error ? failure.message : String(failure)); setRunning(false)
    }
  }
  const stop = () => {
    epoch++
    if (timer) clearTimeout(timer)
    // A start request is allowed to return its ID so it can be cancelled too.
    if (sessionId) {
      controller?.abort()
      const id = sessionId
      sessionId = undefined
      void request(`${endpoint}/${id}`, 'DELETE', {}).catch((failure) => {
        if (mounted) setError(`Stopped local updates; server cancellation failed: ${String(failure)}`)
      })
    }
    if (mounted) setRunning(false)
  }
  onCleanup(() => { mounted = false; stop() })

  return <section class="editor-chat" aria-label="Workflow agent chat">
    <div class="section-title"><h3>Agent chat</h3><span role="status">{active() ? 'Agent working · live preview' : 'Draft changes · save when ready'}</span></div>
    <div class="editor-chat-messages" role="log" aria-live="polite">
      <For each={history()}>{(item) => <p><strong>{item.role}</strong> {item.text}</p>}</For>
      <For each={replies()}>{(text) => <p><strong>Agent</strong> {text}</p>}</For>
    </div>
    <Show when={error()}><p role="alert" class="field-error">{error()}</p>
      <Show when={active()}><button class="secondary" onClick={() => { setError(''); void poll(epoch) }}>Retry connection</button></Show>
    </Show>
    <form onSubmit={(event) => { event.preventDefault(); void send() }}>
      <label>Ask the agent<textarea rows="3" value={message()} placeholder="Create a research → draft → review workflow…" onInput={(event) => setMessage(event.currentTarget.value)} /></label>
      <button type="submit" disabled={active() || props.disabled || !message().trim()}>Send to agent</button>
      <Show when={active()}><button type="button" class="secondary" onClick={stop}>Stop generation</button></Show>
    </form>
  </section>
}
