import { ActionButton } from '../components/ActionButton'
import { Index, Show, createEffect, createResource, createSignal } from 'solid-js'
import { api } from '../api'
import { rielaFetch } from '../transport'
import { ErrorBanner } from '../components/Primitives'

interface Worker { id: string; groups: string[]; maxCapacity: number }
interface Controller { host: string; port: number; storePath: string; workers: Worker[] }
interface Snapshot {
  profile: string
  configuration: Controller
  savedConfiguration: Controller | null
  status: string
}

async function loadSettings(): Promise<Snapshot> {
  const response = await rielaFetch('/api/v1/settings/workers', { headers: api.noteHeaders() })
  const value = await response.json()
  if (!response.ok) throw new Error(value.message ?? 'Cannot load worker settings.')
  return value as Snapshot
}

export function WorkerSettings(props: { profileKey: string }) {
  const [snapshot, { refetch }] = createResource(() => props.profileKey, loadSettings)
  const [draft, setDraft] = createSignal<Controller>()
  const [saving, setSaving] = createSignal(false)
  const [message, setMessage] = createSignal('')
  const [failed, setFailed] = createSignal(false)
  createEffect(() => { const value = snapshot(); if (value) setDraft(structuredClone(value.configuration)) })
  const updateWorker = (index: number, update: Partial<Worker>) => setDraft((value) => value && ({
    ...value, workers: value.workers.map((worker, position) => position === index ? { ...worker, ...update } : worker),
  }))
  const save = async () => {
    const current = snapshot(), configuration = draft()
    if (!current || !configuration) return
    setSaving(true); setMessage(''); setFailed(false)
    try {
      const response = await rielaFetch('/api/v1/settings/workers', {
        method: 'PUT', headers: { ...api.noteHeaders(), 'Content-Type': 'application/json' },
        body: JSON.stringify({ expectedProfile: current.profile, expectedConfiguration: current.savedConfiguration, configuration }),
      })
      const result = await response.json()
      if (!response.ok) throw new Error(result.message ?? 'Cannot save worker settings.')
      setMessage(result.message); await refetch()
    } catch (error) { setFailed(true); setMessage(error instanceof Error ? error.message : String(error)) }
    finally { setSaving(false) }
  }
  return <section class="panel settings-panel">
    <div class="section-title"><div><h2>Worker Controller</h2><p>Authorize remote workers and configure their connection to this profile.</p></div><ActionButton class="secondary" disabled={saving()} onClick={() => void refetch()}>Refresh workers</ActionButton></div>
    <Show when={snapshot.error}><ErrorBanner message={String(snapshot.error)} /></Show>
    <Show when={draft()}>{(value) => <form onSubmit={(event) => { event.preventDefault(); void save() }}>
      <p role="status">{snapshot()?.status}</p>
      <fieldset disabled={saving()} class="worker-settings-fields">
        <div class="form-grid">
          <label><span>Listen address</span><input required value={value().host} onInput={(event) => setDraft({ ...value(), host: event.currentTarget.value })} /></label>
          <label><span>Controller port</span><input required type="number" min="1" max="65535" value={value().port} onInput={(event) => setDraft({ ...value(), port: Number(event.currentTarget.value) })} /></label>
          <label><span>Queue storage</span><input required value={value().storePath} onInput={(event) => setDraft({ ...value(), storePath: event.currentTarget.value })} /></label>
        </div>
        <h3>Authorized workers</h3>
        <Index each={value().workers}>{(worker, index) => <div class="form-grid">
          <label><span>Worker ID</span><input required value={worker().id} onInput={(event) => updateWorker(index, { id: event.currentTarget.value })} /></label>
          <label><span>Groups (comma-separated)</span><input value={worker().groups.join(', ')} onChange={(event) => updateWorker(index, { groups: [...new Set(event.currentTarget.value.split(',').map((group) => group.trim()).filter(Boolean))] })} /></label>
          <label><span>Capacity</span><input required type="number" min="1" max="1024" value={worker().maxCapacity} onInput={(event) => updateWorker(index, { maxCapacity: Number(event.currentTarget.value) })} /></label>
          <ActionButton type="button" class="secondary" onClick={() => setDraft({ ...value(), workers: value().workers.filter((_, position) => position !== index) })}>Remove worker</ActionButton>
        </div>}</Index>
        <div class="save-row"><ActionButton type="button" class="secondary" onClick={() => {
          let suffix = value().workers.length + 1
          while (value().workers.some((worker) => worker.id === `worker-${suffix}`)) suffix++
          setDraft({ ...value(), workers: [...value().workers, { id: `worker-${suffix}`, groups: [], maxCapacity: 1 }] })
        }}>Add worker</ActionButton></div>
        <p>Save your workers here, then issue a worker key in API Keys. Store the issued key on its worker in a private file.</p>
        <div class="save-row"><ActionButton type="submit">{saving() ? 'Saving…' : 'Save and restart controller'}</ActionButton></div>
      </fieldset>
    </form>}</Show>
    <Show when={message()}><p role="status" classList={{ 'error-banner': failed() }}>{message()}</p></Show>
  </section>
}
