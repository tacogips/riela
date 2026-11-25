import { For, Show, createResource, createSignal } from 'solid-js'
import { ActionButton } from '../components/ActionButton'
import { drivers } from '../bots/BotForm'
import { originAllowsActions, statusLabel } from '../bots/boardView'
import { botsClient } from '../bots/client'
import { RemoteSwitcher } from '../bots/RemoteSwitcher'
import { createRemoteSelection, managementError, readRemoteTargets } from '../bots/remoteSelection'
import { optionChips, probeAgeLabel } from './modelsView.ts'
import '../bots/bots.css'

export function ModelsView(props: { profileKey: string }) {
  const remote = createRemoteSelection(() => props.profileKey)
  const context = () => {
    if (remote.registry.loading && !remote.snapshot() && !remote.registry.error) return undefined
    return JSON.stringify(remote.targets())
  }
  return <section class="bots-page" aria-label="Models">
    <header class="bots-header">
      <h1>Models</h1>
      <RemoteSwitcher remote={remote} />
    </header>
    <Show when={context()} keyed fallback={<p role="status">Loading hosts…</p>}>{(key) =>
      <ProviderList targets={JSON.parse(key) as string[]} selection={remote.selection()} />
    }</Show>
  </section>
}

function ProviderList(props: { targets: string[]; selection: string }) {
  const [list, { refetch }] = createResource(() => readRemoteTargets(props.targets, (remote) => botsClient.getProviders(remote)))
  const [adding, setAdding] = createSignal(false)
  const [busy, setBusy] = createSignal(false)
  const [error, setError] = createSignal<string>()
  const change = async (operation: () => Promise<unknown>) => {
    if (busy()) return
    setBusy(true)
    setError(undefined)
    try {
      await operation()
      await refetch()
    } catch (failure) {
      setError(managementError(failure))
    } finally {
      setBusy(false)
    }
  }

  return <>
    <div class="bot-actions">
      <ActionButton type="button" disabled={busy() || list.loading} onClick={() => void refetch()}>Reload</ActionButton>
      <Show when={props.selection !== '*' && list() && !list()!.failures.length}>
        <ActionButton type="button" aria-expanded={adding()} onClick={() => setAdding(!adding())}>Add provider</ActionButton>
      </Show>
    </div>
    <Show when={adding()}>
      <form class="panel bots-form" onSubmit={(event) => {
        event.preventDefault()
        const fields = new FormData(event.currentTarget)
        const instanceId = String(fields.get('instanceId') ?? '').trim()
        const driver = String(fields.get('driver') ?? '')
        const label = String(fields.get('label') ?? '').trim() || undefined
        const account = String(fields.get('account') ?? '').trim() || undefined
        const customModels = [...new Set(String(fields.get('models') ?? '').split(/[,\n]/).map((id) => id.trim()).filter(Boolean))]
        if (list()?.values.flat().some((provider) => provider.instanceId === instanceId)) {
          setError('provider_instance_exists')
          return
        }
        if (instanceId) void change(async () => {
          await botsClient.saveProvider({ instanceId, driver, label, account, customModels }, props.selection)
          setAdding(false)
        })
      }}>
        <label>Instance ID<input name="instanceId" required /></label>
        <label>Driver<select name="driver"><For each={drivers}>{([id, label]) => <option value={id}>{label}</option>}</For></select></label>
        <label>Label<input name="label" /></label>
        <label>Account<input name="account" /></label>
        <label>Custom model IDs<textarea name="models" rows={2} placeholder="One ID per line" /></label>
        <ActionButton type="submit" disabled={busy() || list.loading}>Save provider</ActionButton>
      </form>
    </Show>
    <Show when={error()}>{(code) => <p role="alert">{code()}</p>}</Show>
    <For each={list()?.failures}>{(failure) => <p role="alert">{failure.remote} · {failure.code}</p>}</For>
    <Show when={list.loading && !list()}><p role="status">Loading providers…</p></Show>
    <For each={list()?.values.flat()}>{(provider) =>
      <article class="panel bot-management">
        <header class="bots-header">
          <div>
            <h2>{provider.label}</h2>
            <div class="bots-meta">
              <span>{provider.driver}</span>
              <Show when={provider.account}><span>{provider.account}</span></Show>
              <Show when={provider.origin.remote !== 'local'}><span>{provider.origin.serverName ?? provider.origin.remote}</span></Show>
              <Show when={!provider.origin.verified}><span>Unverified</span></Show>
            </div>
          </div>
          <Show when={originAllowsActions(provider.origin)}>
            <div class="bot-actions">
              <ActionButton type="button" disabled={busy() || list.loading} onClick={() =>
                void change(() => botsClient.refreshProvider(provider.instanceId, provider.origin.remote))}>Refresh</ActionButton>
              <Show when={!provider.builtIn}>
                <ActionButton type="button" disabled={busy() || list.loading} onClick={() =>
                  void change(() => botsClient.removeProvider(provider.instanceId, provider.origin.remote))}>Remove</ActionButton>
              </Show>
            </div>
          </Show>
        </header>
        <div class="bots-meta">
          <span>{statusLabel(provider.availability ?? 'unknown')}</span>
          <span>Auth {statusLabel(provider.authentication ?? 'unknown')}</span>
          <Show when={provider.version}><span>{provider.version}</span></Show>
          <span>{probeAgeLabel(provider.probedAt)}</span>
        </div>
        <ul class="bots-rows"><For each={provider.models}>{(model) =>
          <li class="bots-row">
            <strong>{model.id}</strong>
            <Show when={model.label && model.label !== model.id}><span> · {model.label}</span></Show>
            <div class="bots-meta">
              <For each={model.sources}>{(source) => <span class="bot-chip">{statusLabel(source)}</span>}</For>
              <For each={optionChips(model)}>{(option) => <span class="bot-chip" title={option.label}>{option.value}</span>}</For>
            </div>
          </li>
        }</For></ul>
      </article>
    }</For>
  </>
}
