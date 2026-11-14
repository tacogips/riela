import { For, Show, createMemo, createResource, createSignal } from 'solid-js'
import { APIError, api } from '../api'
import type { Instance, InstanceResponse, InstancesResponse } from '../contracts'
import { EmptyState, ErrorBanner, LoadingState, MutationMessage, PageHeader } from '../components/Primitives'

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function statusLabel(status: Instance['status']): string {
  return status === 'needsSource' ? 'Needs source' : status
}

export function InstancesView() {
  const [instances, { refetch }] = createResource(() => api.get<InstancesResponse>('/api/v1/instances'))
  const [selectedId, setSelectedId] = createSignal<string>()
  const selected = createMemo(() => instances()?.items.find((item) => item.id === selectedId()))

  return <section class="page"><PageHeader eyebrow="RUNTIME" title="Workflow instances" description="Live state and persisted configuration for this profile." actions={<button class="secondary" onClick={() => void refetch()}>Refresh</button>} />
    <Show when={instances.loading}><LoadingState label="Loading workflow instances…" /></Show>
    <Show when={instances.error}><ErrorBanner message={errorMessage(instances.error)} /></Show>
    <Show when={!instances.loading && !instances.error && instances()?.items.length === 0}><EmptyState title="No instances yet" detail="Add a workflow in the native Instances window, then refresh this page." /></Show>
    <div class="instance-grid" aria-busy={instances.loading}>
      <For each={instances()?.items}>{(instance) => {
        const missingCount = () => instance.requiredEnvironment.filter((requirement) => !requirement.present).length
        return <button classList={{ 'instance-card': true, selected: selectedId() === instance.id }} aria-pressed={selectedId() === instance.id} onClick={() => setSelectedId(instance.id)}>
          <div class="card-heading"><span class={`status-dot ${instance.status}`} aria-hidden="true" /><div><strong>{instance.name}</strong><span>{instance.workflowId}</span></div><span class={`status-chip ${instance.status}`}>{statusLabel(instance.status)}</span></div>
          <p>{instance.statusDetail}</p>
          <div class="card-badges"><span>{instance.sourceKind}</span><span>{instance.enabledAtLaunch ? 'Enabled at launch' : 'Disabled at launch'}</span><Show when={missingCount() > 0}><span class="warning-badge">Missing env: {missingCount()}</span></Show></div>
          <div class="card-meta"><span>{instance.eventSources.length} event sources</span><span>{instance.nodePatchCount} node patches</span></div>
        </button>
      }}</For>
    </div>
    <Show when={selected()}>{(instance) => <Show when={instance().status !== 'needsSource'} fallback={<MissingSourceDetail instance={instance()} />}><InstanceEditor instance={instance()} onRefresh={() => void refetch()} /></Show>}</Show>
  </section>
}

function MissingSourceDetail(props: { instance: Instance }) {
  return <div class="editor-panel" role="status"><div class="section-title"><div><span class="eyebrow">SOURCE REQUIRED</span><h2>{props.instance.name}</h2></div><span class="status-chip needsSource">Needs source</span></div>
    <div class="instance-affordance"><strong>This configured instance cannot find its workflow source.</strong><span>{props.instance.source}</span><span>Relink or remove it in the native Riela Instances window. Configuration and run history are unavailable until then.</span></div>
  </div>
}

function InstanceEditor(props: { instance: Instance; onRefresh: () => void }) {
  const [workingDirectory, setWorkingDirectory] = createSignal(props.instance.workingDirectory ?? '')
  const [environmentFilePath, setEnvironmentFilePath] = createSignal(props.instance.environmentFilePath ?? '')
  const [environmentUpdates, setEnvironmentUpdates] = createSignal<Record<string, string>>({})
  const [environmentToClear, setEnvironmentToClear] = createSignal<string[]>([])
  const [newEnvironmentName, setNewEnvironmentName] = createSignal('')
  const [newEnvironmentValue, setNewEnvironmentValue] = createSignal('')
  const [variables, setVariables] = createSignal(JSON.stringify(props.instance.workflowVariables, null, 2))
  const [saving, setSaving] = createSignal(false)
  const [message, setMessage] = createSignal('')
  const [saveError, setSaveError] = createSignal(false)
  const [conflict, setConflict] = createSignal(false)

  const save = async () => {
    setSaving(true); setMessage(''); setSaveError(false); setConflict(false)
    try {
      const updates = { ...environmentUpdates() }
      if (newEnvironmentName().trim() && newEnvironmentValue()) updates[newEnvironmentName().trim()] = newEnvironmentValue()
      await api.mutate<InstanceResponse>(`/api/v1/instances/${encodeURIComponent(props.instance.id)}/configuration`, 'PUT', {
        workingDirectory: workingDirectory(),
        environmentFilePath: environmentFilePath(),
        environmentVariableUpdates: updates,
        environmentVariablesToClear: environmentToClear(),
        workflowVariables: JSON.parse(variables()) as Record<string, unknown>,
      })
      setMessage('Saved. Active instances restart with the new configuration.')
      setEnvironmentUpdates({}); setEnvironmentToClear([]); setNewEnvironmentName(''); setNewEnvironmentValue('')
      props.onRefresh()
    } catch (error) {
      const isConflict = error instanceof APIError && error.status === 409
      setConflict(isConflict); setSaveError(true)
      setMessage(isConflict ? 'Changed elsewhere — refresh before saving again.' : errorMessage(error))
    } finally { setSaving(false) }
  }

  const toggleClear = (name: string, checked: boolean) => {
    setEnvironmentToClear((current) => checked ? [...current, name] : current.filter((item) => item !== name))
  }

  return <div class="editor-panel"><div class="section-title"><div><span class="eyebrow">CONFIGURATION</span><h2>{props.instance.name}</h2></div><span class="source-label">{props.instance.source} · {props.instance.sourceKind}</span></div>
    <div class="instance-affordance"><strong>{props.instance.active ? 'Active now' : 'Inactive now'} · {props.instance.enabledAtLaunch ? 'enabled at launch' : 'disabled at launch'}</strong><span>Start, stop, restart, and enablement are managed in the Riela menu-bar app.</span></div>
    <Show when={props.instance.requiredEnvironment.length > 0}><div class="requirements" aria-label="Required environment"><h3>Required environment</h3><For each={props.instance.requiredEnvironment}>{(requirement) => <div class="requirement-row"><span classList={{ 'presence-dot': true, present: requirement.present }} aria-hidden="true" /><div><strong>{requirement.name}</strong><span>{requirement.description ?? 'No description'} · {requirement.source}</span></div><span>{requirement.present ? 'Present' : 'Missing'}</span></div>}</For></div></Show>
    <div class="form-grid"><label><span>Working directory</span><input value={workingDirectory()} onInput={(event) => setWorkingDirectory(event.currentTarget.value)} /></label><label><span>Environment file</span><input value={environmentFilePath()} onInput={(event) => setEnvironmentFilePath(event.currentTarget.value)} /></label></div>
    <div class="secret-editor"><h3>Inline environment variables</h3><p>Stored values are never returned. Leave a replacement blank to keep it, or explicitly clear it.</p>
      <For each={props.instance.environmentVariables}>{(variable) => <div class="secret-row"><label><span>{variable.name} · {variable.masked}</span><input type="password" autocomplete="new-password" placeholder="Leave blank to keep current value" value={environmentUpdates()[variable.name] ?? ''} onInput={(event) => setEnvironmentUpdates((current) => ({ ...current, [variable.name]: event.currentTarget.value }))} /></label><label class="check-row clear-secret"><input type="checkbox" checked={environmentToClear().includes(variable.name)} onChange={(event) => toggleClear(variable.name, event.currentTarget.checked)} /><span>Clear</span></label></div>}</For>
      <div class="secret-row"><label><span>New variable name</span><input autocomplete="off" value={newEnvironmentName()} onInput={(event) => setNewEnvironmentName(event.currentTarget.value)} /></label><label><span>New write-only value</span><input type="password" autocomplete="new-password" value={newEnvironmentValue()} onInput={(event) => setNewEnvironmentValue(event.currentTarget.value)} /></label></div>
    </div>
    <label><span>Workflow variables</span><small>JSON object passed to each run.</small><textarea rows="7" value={variables()} onInput={(event) => setVariables(event.currentTarget.value)} /></label>
    <div class="save-row"><Show when={message()}><MutationMessage message={message()} isError={saveError()} onRefresh={conflict() ? props.onRefresh : undefined} /></Show><button disabled={saving()} onClick={() => void save()}>{saving() ? 'Saving…' : 'Save changes'}</button></div>
  </div>
}
