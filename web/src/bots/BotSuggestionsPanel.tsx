import { For, Show, createSignal } from 'solid-js'
import { ActionButton } from '../components/ActionButton'
import { createPollingResource } from '../polling'
import { originAllowsActions } from './boardView'
import { botsClient } from './client'
import { managementError } from './remoteSelection'

export function BotSuggestionsPanel(props: { botId: string; remote: string; disabled: boolean; onChange: () => void }) {
  const list = createPollingResource(
    () => JSON.stringify([props.botId, props.remote]),
    (signal) => botsClient.getSuggestions(props.botId, props.remote, signal),
  )
  const [busy, setBusy] = createSignal(false)
  const [error, setError] = createSignal<string>()
  const trusted = () => {
    const data = list.data()
    return data && originAllowsActions(data.origin, props.remote) ? data : undefined
  }

  const decide = async (id: string, decision: 'accept' | 'dismiss', run = false) => {
    if (busy() || props.disabled || list.error()) return
    setBusy(true)
    setError(undefined)
    try {
      await botsClient.decideSuggestion(id, decision, run, props.remote)
      await list.refresh()
      props.onChange()
    } catch (failure) {
      setError(managementError(failure))
    } finally {
      setBusy(false)
    }
  }

  return <section class="panel bot-management" aria-label="Bot suggestions">
    <h2>Suggestions</h2>
    <Show when={list.loading() && !list.data()}><p role="status">Loading suggestions…</p></Show>
    <Show when={list.error() || error()}><p role="alert">{error() ?? managementError(list.error())}</p></Show>
    <Show when={list.data() && !trusted()}><p role="alert">Suggestion origin unverified.</p></Show>
    <Show when={trusted()?.suggestions.length === 0}><p>No open suggestions.</p></Show>
    <ul class="bots-rows"><For each={trusted()?.suggestions}>{(suggestion) => <li class="bots-row bot-management">
      <strong>{suggestion.title}</strong>
      <Show when={suggestion.detail}><p>{suggestion.detail}</p></Show>
      <Show when={!list.error() && (!suggestion.origin || originAllowsActions(suggestion.origin, props.remote))}>
        <div class="bot-actions">
          <ActionButton type="button" disabled={busy() || props.disabled} onClick={() => void decide(suggestion.suggestionId, 'accept')}>Accept</ActionButton>
          <Show when={suggestion.action}>
            <ActionButton type="button" disabled={busy() || props.disabled} onClick={() => void decide(suggestion.suggestionId, 'accept', true)}>Accept and run</ActionButton>
          </Show>
          <ActionButton type="button" disabled={busy() || props.disabled} onClick={() => void decide(suggestion.suggestionId, 'dismiss')}>Dismiss</ActionButton>
        </div>
      </Show>
    </li>}</For></ul>
  </section>
}
