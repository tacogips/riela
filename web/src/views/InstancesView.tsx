import { For, Show, createMemo, createResource, createSignal } from 'solid-js'
import { APIError, api } from '../api'
import type { Instance, InstanceResponse, InstancesResponse } from '../contracts'
import { EmptyState, ErrorBanner, PageHeader } from '../components/Primitives'

function pairsText(values: Record<string, string>): string {
  return Object.entries(values).map(([key, value]) => `${key}=${value}`).join('\n')
}

function parsePairs(value: string): Record<string, string> {
  return Object.fromEntries(value.split('\n').map((line) => line.trim()).filter(Boolean).map((line) => {
    const index = line.indexOf('=')
    if (index < 1) throw new Error(`Expected KEY=VALUE, received “${line}”`)
    return [line.slice(0, index), line.slice(index + 1)]
  }))
}

export function InstancesView() {
  const [instances, { refetch }] = createResource(() => api.get<InstancesResponse>('/api/v1/instances'))
  const [selectedId, setSelectedId] = createSignal<string>()
  const selected = createMemo(() => instances()?.items.find((item) => item.id === selectedId()))

  return <section class="page"><PageHeader eyebrow="RUNTIME" title="Workflow instances" description="Live state and persisted configuration for this profile." actions={<button class="secondary" onClick={() => void refetch()}>Refresh</button>} />
    <Show when={instances.error}><ErrorBanner message={String(instances.error)} /></Show>
    <Show when={instances()?.items.length === 0}><EmptyState title="No instances yet" detail="Add a workflow in the native Instances window, then refresh this page." /></Show>
    <div class="instance-grid">
      <For each={instances()?.items}>{(instance) => <button classList={{ 'instance-card': true, selected: selectedId() === instance.id }} onClick={() => setSelectedId(instance.id)}>
        <div class="card-heading"><span class={`status-dot ${instance.status}`} /><div><strong>{instance.name}</strong><span>{instance.workflowId}</span></div><span class="status-chip">{instance.status}</span></div>
        <p>{instance.statusDetail}</p>
        <div class="card-meta"><span>{instance.eventSources.length} event sources</span><span>{instance.nodePatchCount} node patches</span></div>
      </button>}</For>
    </div>
    <Show when={selected()}>{(instance) => <InstanceEditor instance={instance()} onSaved={() => void refetch()} />}</Show>
  </section>
}

function InstanceEditor(props: { instance: Instance; onSaved: () => void }) {
  const [workingDirectory, setWorkingDirectory] = createSignal(props.instance.workingDirectory ?? '')
  const [environmentFilePath, setEnvironmentFilePath] = createSignal(props.instance.environmentFilePath ?? '')
  const [environment, setEnvironment] = createSignal(pairsText(props.instance.environmentVariables))
  const [variables, setVariables] = createSignal(JSON.stringify(props.instance.workflowVariables, null, 2))
  const [saving, setSaving] = createSignal(false)
  const [message, setMessage] = createSignal('')

  const save = async () => {
    setSaving(true); setMessage('')
    try {
      await api.mutate<InstanceResponse>(`/api/v1/instances/${encodeURIComponent(props.instance.id)}/configuration`, 'PUT', {
        workingDirectory: workingDirectory(),
        environmentFilePath: environmentFilePath(),
        environmentVariables: parsePairs(environment()),
        workflowVariables: JSON.parse(variables()) as Record<string, unknown>,
      })
      setMessage('Saved. Active instances restart with the new configuration.')
      props.onSaved()
    } catch (error) {
      setMessage(error instanceof APIError && error.status === 409 ? 'This instance changed elsewhere. Refresh before saving again.' : String(error))
    } finally { setSaving(false) }
  }

  return <div class="editor-panel"><div class="section-title"><div><span class="eyebrow">CONFIGURATION</span><h2>{props.instance.name}</h2></div><span class="source-label">{props.instance.source}</span></div>
    <div class="form-grid"><label><span>Working directory</span><input value={workingDirectory()} onInput={(event) => setWorkingDirectory(event.currentTarget.value)} /></label><label><span>Environment file</span><input value={environmentFilePath()} onInput={(event) => setEnvironmentFilePath(event.currentTarget.value)} /></label></div>
    <div class="form-grid"><label><span>Environment variables</span><small>One KEY=VALUE pair per line.</small><textarea rows="7" value={environment()} onInput={(event) => setEnvironment(event.currentTarget.value)} /></label><label><span>Workflow variables</span><small>JSON object passed to each run.</small><textarea rows="7" value={variables()} onInput={(event) => setVariables(event.currentTarget.value)} /></label></div>
    <div class="save-row"><span>{message()}</span><button disabled={saving()} onClick={() => void save()}>{saving() ? 'Saving…' : 'Save changes'}</button></div>
  </div>
}
