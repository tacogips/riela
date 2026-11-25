import { For, Show, createResource, createSignal } from 'solid-js'
import { ActionButton } from '../components/ActionButton'
import { originAllowsActions } from './boardView'
import { botsClient } from './client'
import { changeLabel, isDirty } from './memoryPanel'
import { managementError } from './remoteSelection'

export function BotMemoryPanel(props: { botId: string; remote: string; revision: number; disabled: boolean }) {
  const [memory, { refetch }] = createResource(
    () => props.revision,
    () => botsClient.getMemory(props.botId, props.remote),
  )
  const [draft, setDraft] = createSignal<string>()
  const [busy, setBusy] = createSignal(false)
  const [error, setError] = createSignal<string>()
  const loaded = () => memory.error ? undefined : memory.latest
  const trusted = () => {
    const value = loaded()
    return value && originAllowsActions(value.origin, props.remote) ? value : undefined
  }
  const markdown = () => draft() ?? trusted()?.markdown ?? ''
  const dirty = () => isDirty(trusted()?.markdown ?? '', markdown())
  const changes = () => trusted()?.changes.slice(0, 20) ?? []

  const change = async (operation: () => Promise<unknown>) => {
    if (busy() || props.disabled || !trusted()) return
    setBusy(true)
    setError(undefined)
    try {
      await operation()
      await refetch()
      if (trusted()) setDraft(undefined)
    } catch (failure) {
      setError(managementError(failure))
    } finally {
      setBusy(false)
    }
  }

  return <section class="panel bot-management" aria-label="Bot memory">
    <h2>Memory</h2>
    <Show when={memory.loading && !loaded()}><p role="status">Loading memory…</p></Show>
    <Show when={memory.error}>{(failure) => <div class="bot-actions">
      <span role="alert">{managementError(failure())}</span>
      <ActionButton type="button" onClick={() => void refetch()}>Retry memory</ActionButton>
    </div>}</Show>
    <Show when={loaded() && !trusted()}><p role="alert">Memory origin unverified.</p></Show>
    <Show when={error()}>{(code) => <p role="alert">{code()}</p>}</Show>
    <Show when={trusted()}>
      <form class="bot-management" onSubmit={(event) => {
        event.preventDefault()
        if (dirty()) void change(() => botsClient.updateMemory(props.botId, markdown(), props.remote))
      }}>
        <textarea aria-label="Memory Markdown" rows={10} value={markdown()} disabled={busy()} onInput={(event) => setDraft(event.currentTarget.value)} />
        <div class="bot-actions">
          <ActionButton type="submit" disabled={!dirty() || busy() || props.disabled || memory.loading}>Save memory</ActionButton>
        </div>
      </form>
      <Show when={changes().length}>
        <h3>Recent changes</h3>
        <ul class="bots-rows"><For each={changes()}>{(entry, index) => <li class="bots-row bots-row-top">
          <span>{changeLabel(entry)}</span>
          <Show when={index() === 0}>
            <ActionButton type="button" disabled={busy() || dirty() || props.disabled || memory.loading}
              onClick={() => void change(() => botsClient.undoMemory(props.botId, entry.changeId, props.remote))}>Undo</ActionButton>
          </Show>
        </li>}</For></ul>
      </Show>
    </Show>
  </section>
}
