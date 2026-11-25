import { For, Show, createSignal } from 'solid-js'
import { ActionButton } from '../components/ActionButton'
import { relativeActivity } from './boardView'
import { botsClient } from './client'
import type { RemoteList } from './contracts'
import { managementError, type RemoteSelection } from './remoteSelection'

export function RemoteSwitcher(props: { remote: RemoteSelection; onSelect?: () => void }) {
  const [busy, setBusy] = createSignal(false)
  const [error, setError] = createSignal<string>()
  const registry = props.remote.snapshot
  const current = () => registry()?.remotes.find(({ name }) => name === props.remote.selection())

  const change = async (operation: () => Promise<RemoteList>) => {
    if (busy() || props.remote.registry.loading) return
    setBusy(true)
    setError(undefined)
    try {
      props.remote.mutate(await operation())
    } catch (failure) {
      setError(managementError(failure))
    } finally {
      setBusy(false)
    }
  }

  return <div class="bots-remote">
    <div class="bot-actions">
      <label>Host <select value={props.remote.selection()} onChange={(event) => {
        props.remote.select(event.currentTarget.value)
        props.onSelect?.()
      }}>
        <option value="local">Local</option>
        <For each={registry()?.remotes}>{(remote) =>
          <option value={remote.name}>{remote.name}</option>
        }</For>
        <option value="*">All</option>
      </select></label>
      <Show when={current()}>{(remote) => <span class="bots-meta">
        {remote().serverName}
        <Show when={remote().connection === 'disconnected'}>
          {' · Disconnected'}
          <Show when={remote().lastSeenAt}>{(at) => <> · last seen {relativeActivity(at())}</>}</Show>
        </Show>
      </span>}</Show>
    </div>
    <details>
      <summary>Manage remotes</summary>
      <form class="bots-form" onSubmit={(event) => {
        event.preventDefault()
        const form = event.currentTarget
        const fields = new FormData(form)
        const code = String(fields.get('code') ?? '').trim()
        const name = String(fields.get('name') ?? '').trim()
        form.reset()
        if (name && code) void change(() => botsClient.addRemote(name, code))
      }}>
        <label>Name<input name="name" required /></label>
        <label>Pairing code<input name="code" type="password" autocomplete="off" required /></label>
        <ActionButton type="submit" disabled={busy() || props.remote.registry.loading}>Add remote</ActionButton>
      </form>
      <div class="bot-actions">
        <Show when={registry() && props.remote.selection() !== '*' && registry()?.active !== props.remote.selection()}>
          <ActionButton type="button" disabled={busy() || props.remote.registry.loading}
            onClick={() => {
              const remote = props.remote.selection()
              // Preserve the active filter while changing the registry default.
              props.remote.select(remote)
              void change(() => botsClient.useRemote(remote))
            }}>Set default</ActionButton>
        </Show>
        <Show when={current()}>{(remote) =>
          <ActionButton type="button" disabled={busy() || props.remote.registry.loading} onClick={() => {
            const name = remote().name
            void change(async () => {
              const updated = await botsClient.removeRemote(name)
              props.onSelect?.()
              return updated
            })
          }}>Remove remote</ActionButton>
        }</Show>
      </div>
    </details>
    <Show when={error()}>{(code) => <p role="alert">{code()}</p>}</Show>
    <Show when={props.remote.registry.error}>{(failure) => <div class="bot-actions">
      <span role="alert">{managementError(failure())}</span>
      <ActionButton type="button" onClick={() => void props.remote.refetch()}>Retry remotes</ActionButton>
    </div>}</Show>
  </div>
}
