import { For, Show, createEffect, createMemo, createResource, createSignal, on } from 'solid-js'
import { ActionButton } from '../components/ActionButton'
import { ConfirmationDialog } from '../components/ConfirmationDialog'
import { ErrorBanner, LoadingState } from '../components/Primitives'
import { rielaFetch } from '../transport'

interface KeyRecord {
  id: string; name: string; purpose: 'client' | 'worker'; workerID?: string
  createdAt: string; expiresAt?: string; revokedAt?: string
}
interface Snapshot { profile: string; requireClientKey: boolean; keys: KeyRecord[] }
type PendingAction =
  | { kind: 'issue'; profile: string; name: string; purpose: 'client' | 'worker'; workerID?: string; expiresAt?: string }
  | { kind: 'policy'; profile: string; required: boolean }
  | { kind: 'revoke'; profile: string; key: KeyRecord }
const path = '/api/v1/settings/api-keys'
async function request<T>(method = 'GET', body?: object): Promise<T> {
  const response = await rielaFetch(path, {
    method, headers: { 'Content-Type': 'application/json' },
    ...(body ? { body: JSON.stringify(body) } : {}),
  })
  if (!response.ok) throw new Error(await response.text())
  return response.json() as Promise<T>
}

export function APIKeySettings(props: { profileKey: string }) {
  const [snapshot, { refetch }] = createResource(() => props.profileKey, () => request<Snapshot>())
  const [name, setName] = createSignal('')
  const [purpose, setPurpose] = createSignal<'client' | 'worker'>('client')
  const [workerID, setWorkerID] = createSignal('')
  const [expiration, setExpiration] = createSignal('')
  const [token, setToken] = createSignal('')
  const [selectedID, setSelectedID] = createSignal('')
  const [pending, setPending] = createSignal<PendingAction>()
  const [saving, setSaving] = createSignal(false)
  const [error, setError] = createSignal('')
  const [message, setMessage] = createSignal('')
  const selected = createMemo(() => snapshot()?.keys.find((key) => key.id === selectedID()))
  createEffect(on(() => props.profileKey, () => {
    setToken(''); setWorkerID(''); setSelectedID(''); setPending(undefined); setError(''); setMessage('')
  }))
  const mutate = async (action: () => Promise<void>) => {
    setSaving(true); setError(''); setMessage('')
    try { await action(); await refetch() }
    catch (failure) { setError(failure instanceof Error ? failure.message : String(failure)) }
    finally { setSaving(false) }
  }
  const beginIssue = () => {
    const current = snapshot()
    if (!current) return
    const expiresAt = expiration() ? new Date(expiration()) : undefined
    if (expiresAt && (!Number.isFinite(expiresAt.getTime()) || expiresAt.getTime() <= Date.now())) {
      setError('Choose a future expiration date, or leave it blank.'); return
    }
    setPending({ kind: 'issue', profile: current.profile, name: name().trim(), purpose: purpose(),
      ...(purpose() === 'worker' ? { workerID: workerID().trim() } : {}),
      ...(expiresAt ? { expiresAt: expiresAt.toISOString().replace(/\.\d{3}Z$/, 'Z') } : {}),
    })
  }
  const confirm = () => {
    const action = pending()
    if (!action) return
    setPending(undefined)
    void mutate(async () => {
      if (action.kind === 'issue') {
        setToken('')
        const issued = await request<{ token: string }>('POST', {
          expectedProfile: action.profile, name: action.name, purpose: action.purpose,
          workerID: action.workerID, expiresAt: action.expiresAt,
        })
        setToken(issued.token); setName(''); setMessage('API key issued.')
      } else if (action.kind === 'policy') {
        await request('PUT', { expectedProfile: action.profile, requireClientKey: action.required })
        setMessage('Client authentication policy saved.')
      } else {
        await request('DELETE', { expectedProfile: action.profile, id: action.key.id })
        setSelectedID(''); setMessage('API key revoked.')
      }
    })
  }
  const status = (key: KeyRecord) => key.revokedAt ? 'Revoked'
    : key.expiresAt && Date.parse(key.expiresAt) <= Date.now() ? 'Expired' : 'Active'
  return <section class="panel settings-panel api-key-panel">
    <div class="section-title"><h2>API Keys</h2></div>
    <Show when={snapshot.error || error()}><ErrorBanner message={error() || String(snapshot.error)} /></Show>
    <Show when={snapshot.loading && !snapshot()}><LoadingState label="Loading API keys…" /></Show>
    <Show when={snapshot()}>{(value) => <>
      <label class="check-row"><input type="checkbox" checked={value().requireClientKey} disabled={saving()}
        onChange={(event) => {
          const required = event.currentTarget.checked
          event.currentTarget.checked = value().requireClientKey
          setPending({ kind: 'policy', profile: value().profile, required })
        }} /> Require an API key for client requests</label>
      <form onSubmit={(event) => { event.preventDefault(); beginIssue() }}>
        <fieldset disabled={saving()} class="worker-settings-fields"><div class="form-grid">
          <label><span>Key name</span><input required maxlength="128" value={name()} onInput={(event) => setName(event.currentTarget.value)} /></label>
          <label><span>Purpose</span><select aria-label="Purpose" value={purpose()} onChange={(event) => setPurpose(event.currentTarget.value as 'client' | 'worker')}><option value="client">Client API</option><option value="worker">Worker → controller</option></select></label>
          <Show when={purpose() === 'worker'}><label><span>Configured worker ID</span><input required value={workerID()} onInput={(event) => setWorkerID(event.currentTarget.value)} /></label></Show>
          <label><span>Expires at (blank means no expiry)</span><input type="datetime-local" value={expiration()} onInput={(event) => setExpiration(event.currentTarget.value)} /></label>
        </div><div class="save-row"><ActionButton type="submit">Issue API key</ActionButton></div></fieldset>
      </form>
      <Show when={token()}><div class="confirmation-box"><label><span>Issued API key</span><input readonly value={token()} /></label><div class="button-row"><ActionButton class="secondary" onClick={() => void mutate(async () => { await navigator.clipboard.writeText(token()); setMessage('API key copied.') })}>Copy key</ActionButton><ActionButton class="secondary" onClick={() => setToken('')}>Dismiss key</ActionButton></div></div></Show>
      <Show when={value().keys.length} fallback={<p class="key-list-empty">No API keys.</p>}>
        <fieldset class="api-key-list"><legend>Issued keys</legend>
          <For each={value().keys}>{(key) => <label class="api-key-row">
            <input type="radio" name="selected-api-key" aria-label={key.name} checked={selectedID() === key.id}
              disabled={saving() || !!key.revokedAt} onChange={() => setSelectedID(key.id)} />
            <div><strong>{key.name}</strong><span>{key.purpose === 'worker' ? `Worker: ${key.workerID}` : 'Client API'} · {status(key)}</span><span>Created: {new Date(key.createdAt).toLocaleString()} · Expires: {key.expiresAt ? new Date(key.expiresAt).toLocaleString() : 'Never'}</span></div>
          </label>}</For>
        </fieldset>
        <div class="api-key-danger-zone"><span>{selected()?.name ?? 'Select a key to revoke'}</span>
          <ActionButton class="danger" disabled={saving() || !selected() || !!selected()?.revokedAt}
            onClick={() => { const key = selected(); if (key) setPending({ kind: 'revoke', profile: value().profile, key }) }}>Revoke key</ActionButton>
        </div>
      </Show>
    </>}</Show>
    <Show when={message()}><p role="status">{message()}</p></Show>
    <Show when={pending()}>{(action) => <ConfirmationDialog
      title={action().kind === 'issue' ? 'Issue API key?' : action().kind === 'policy' ? 'Change client authentication?' : 'Revoke API key?'}
      confirmLabel={action().kind === 'issue' ? 'Issue key' : action().kind === 'policy' ? 'Apply change' : 'Revoke key'}
      danger={action().kind === 'revoke' || (action().kind === 'policy' && !(action() as Extract<PendingAction, { kind: 'policy' }>).required)}
      onCancel={() => setPending(undefined)} onConfirm={confirm}>
      <APIKeyConfirmationContent action={action()} />
    </ConfirmationDialog>}</Show>
  </section>
}

function APIKeyConfirmationContent(props: { action: PendingAction }) {
  const action = props.action
  if (action.kind === 'issue') {
    return <><p>Create <strong>{action.name}</strong> for {action.purpose === 'worker' ? `worker ${action.workerID}` : 'client API access'}?</p><p>Expires: {action.expiresAt ? new Date(action.expiresAt).toLocaleString() : 'Never'}.</p><p>The key works immediately and survives app restarts. Copy and save it when shown; its secret cannot be recovered later.</p></>
  }
  if (action.kind === 'policy') {
    return <><p>{action.required ? 'Clients will need a valid API key for every request.' : 'Clients will be allowed to connect without an API key.'}</p><p>Workers still need a valid worker key. This setting applies immediately and survives app restarts.</p></>
  }
  return <><p>Revoke <strong>{action.key.name}</strong>?</p><p>Clients or workers using this key will lose access immediately. This cannot be undone.</p></>
}
