import { For, Show, createEffect, createMemo, createSignal } from 'solid-js'
import { APIError, api, requireExpectedProfile } from '../api'
import type { Instance, InstanceResponse, InstancesResponse } from '../contracts'
import { EmptyState, ErrorBanner, LoadingState, MutationMessage, PageHeader } from '../components/Primitives'
import { createPollingResource, pollingStatusLabel } from '../polling'
import { validateJSONObject } from '../workflows/validation'

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function statusLabel(status: Instance['status']): string {
  return status === 'needsSource' ? 'Needs source' : status
}

export function instanceSelectionForProfile(
  previousProfileKey: string | undefined,
  nextProfileKey: string,
  selectedId: string | undefined,
): string | undefined {
  return previousProfileKey !== undefined && previousProfileKey !== nextProfileKey
    ? undefined
    : selectedId
}

export interface InstanceEditorSnapshot {
  workingDirectory: string
  environmentFilePath: string
  variables: string
  expectedRevision: number
}

export function instanceEditorSnapshot(
  instance: Instance,
  expectedRevision: number,
): InstanceEditorSnapshot {
  return {
    workingDirectory: instance.workingDirectory ?? '',
    environmentFilePath: instance.environmentFilePath ?? '',
    variables: JSON.stringify(instance.workflowVariables, null, 2),
    expectedRevision,
  }
}

export function instanceEditorIdentity(profileKey: string, instanceId: string): string {
  return `${profileKey}\u{1f}${instanceId}`
}

export function InstancesView(props: { profileKey: string; profileName: string }) {
  const instances = createPollingResource(
    () => props.profileKey,
    async (signal) => requireExpectedProfile(
      await api.get<InstancesResponse>('/api/v1/instances', signal),
      props.profileName,
    ),
  )
  const [selectedId, setSelectedId] = createSignal<string>()
  const selectedEditorIdentity = createMemo(() => selectedId()
    ? instanceEditorIdentity(props.profileKey, selectedId()!)
    : undefined)
  let previousProfileKey: string | undefined
  createEffect(() => {
    const nextProfileKey = props.profileKey
    setSelectedId((current) => instanceSelectionForProfile(previousProfileKey, nextProfileKey, current))
    previousProfileKey = nextProfileKey
  })

  return <section class="page"><PageHeader eyebrow="RUNTIME" title="Workflow instances" description="Live state and persisted configuration for this profile." actions={<div class="refresh-actions"><span role="status">{pollingStatusLabel(instances.status())}</span><button class="secondary" onClick={() => void instances.refresh()}>Refresh</button></div>} />
    <Show when={instances.loading() && !instances.data()}><LoadingState label="Loading workflow instances…" /></Show>
    <Show when={instances.error()}><ErrorBanner message={errorMessage(instances.error())} /></Show>
    <Show when={!instances.loading() && !instances.error() && instances.data()?.items.length === 0}><EmptyState title="No instances yet" detail="Add a workflow in the native Instances window, then refresh this page." /></Show>
    <div class="instance-grid" aria-busy={instances.loading()}>
      <For each={instances.data()?.items}>{(instance) => {
        const missingCount = () => instance.requiredEnvironment.filter((requirement) => !requirement.present).length
        return <button classList={{ 'instance-card': true, selected: selectedId() === instance.id }} aria-pressed={selectedId() === instance.id} onClick={() => setSelectedId(instance.id)}>
          <div class="card-heading"><span class={`status-dot ${instance.status}`} aria-hidden="true" /><div><strong>{instance.name}</strong><span>{instance.workflowId}</span></div><span class={`status-chip ${instance.status}`}>{statusLabel(instance.status)}</span></div>
          <p>{instance.statusDetail}</p>
          <div class="card-badges"><span>{instance.sourceKind}</span><span>{instance.enabledAtLaunch ? 'Enabled at launch' : 'Disabled at launch'}</span><Show when={missingCount() > 0}><span class="warning-badge">Missing env: {missingCount()}</span></Show></div>
          <div class="card-meta"><span>{instance.eventSources.length} event sources</span><span>{instance.nodePatchCount} node patches</span></div>
        </button>
      }}</For>
    </div>
    <Show when={selectedEditorIdentity()} keyed>{(_editorIdentity) => <Show
      when={instances.data()?.items.find((item) => item.id === selectedId())}
    >{(instance) =>
      <Show when={instance().status !== 'needsSource'} fallback={<MissingSourceDetail instance={instance()} />}>
        <InstanceEditor
          instance={instance}
          profileName={props.profileName}
          revision={() => instances.data()?.revision ?? 0}
          onRefresh={instances.refresh}
        />
      </Show>
    }</Show>}</Show>
  </section>
}

function MissingSourceDetail(props: { instance: Instance }) {
  return <div class="editor-panel" role="status"><div class="section-title"><div><span class="eyebrow">SOURCE REQUIRED</span><h2>{props.instance.name}</h2></div><span class="status-chip needsSource">Needs source</span></div>
    <div class="instance-affordance"><strong>This configured instance cannot find its workflow source.</strong><span>{props.instance.source}</span><span>Relink or remove it in the native Riela Instances window. Configuration and run history are unavailable until then.</span></div>
  </div>
}

function InstanceEditor(props: {
  instance: () => Instance
  profileName: string
  revision: () => number
  onRefresh: () => Promise<void>
}) {
  const initialInstance = props.instance()
  const initialSnapshot = instanceEditorSnapshot(initialInstance, props.revision())
  const [workingDirectory, setWorkingDirectory] = createSignal(initialSnapshot.workingDirectory)
  const [environmentFilePath, setEnvironmentFilePath] = createSignal(initialSnapshot.environmentFilePath)
  const [environmentUpdates, setEnvironmentUpdates] = createSignal<Record<string, string>>({})
  const [environmentToClear, setEnvironmentToClear] = createSignal<string[]>([])
  const [newEnvironmentName, setNewEnvironmentName] = createSignal('')
  const [newEnvironmentValue, setNewEnvironmentValue] = createSignal('')
  const [variables, setVariables] = createSignal(initialSnapshot.variables)
  const [expectedRevision, setExpectedRevision] = createSignal(initialSnapshot.expectedRevision)
  const [saving, setSaving] = createSignal(false)
  const [message, setMessage] = createSignal('')
  const [saveError, setSaveError] = createSignal(false)
  const [conflict, setConflict] = createSignal(false)
  const variablesValidation = createMemo(() => validateJSONObject(variables()))

  const resetEditor = (instance: Instance, revision: number) => {
    const snapshot = instanceEditorSnapshot(instance, revision)
    setWorkingDirectory(snapshot.workingDirectory)
    setEnvironmentFilePath(snapshot.environmentFilePath)
    setEnvironmentUpdates({})
    setEnvironmentToClear([])
    setNewEnvironmentName('')
    setNewEnvironmentValue('')
    setVariables(snapshot.variables)
    setExpectedRevision(snapshot.expectedRevision)
  }

  const refreshAndRebase = async () => {
    try {
      const response = await api.get<InstanceResponse>(
        `/api/v1/instances/${encodeURIComponent(props.instance().id)}`,
      )
      const current = requireExpectedProfile(response, props.profileName)
      resetEditor(current.item, current.revision)
      await props.onRefresh()
      setMessage('')
      setSaveError(false)
      setConflict(false)
    } catch (error) {
      setSaveError(true)
      setMessage(errorMessage(error))
    }
  }

  const save = async () => {
    const validation = validateJSONObject(variables())
    if (!validation.value) {
      setSaveError(true)
      setMessage(validation.error ?? 'Invalid workflow variables.')
      return
    }
    setSaving(true); setMessage(''); setSaveError(false); setConflict(false)
    try {
      const updates = { ...environmentUpdates() }
      if (newEnvironmentName().trim() && newEnvironmentValue()) updates[newEnvironmentName().trim()] = newEnvironmentValue()
      const response = await api.mutate<InstanceResponse>(`/api/v1/instances/${encodeURIComponent(props.instance().id)}/configuration`, 'PUT', {
        expectedProfile: props.profileName,
        workingDirectory: workingDirectory(),
        environmentFilePath: environmentFilePath(),
        environmentVariableUpdates: updates,
        environmentVariablesToClear: environmentToClear(),
        workflowVariables: validation.value,
      }, expectedRevision())
      resetEditor(response.item, response.revision)
      setMessage('Saved. Active instances restart with the new configuration.')
      await props.onRefresh()
    } catch (error) {
      const isConflict = error instanceof APIError && error.status === 409
      setConflict(isConflict); setSaveError(true)
      setMessage(isConflict ? 'Changed elsewhere — refresh before saving again.' : errorMessage(error))
    } finally { setSaving(false) }
  }

  const toggleClear = (name: string, checked: boolean) => {
    setEnvironmentToClear((current) => checked ? [...current, name] : current.filter((item) => item !== name))
  }

  return <div class="editor-panel"><div class="section-title"><div><span class="eyebrow">CONFIGURATION</span><h2>{props.instance().name}</h2></div><span class="source-label">{props.instance().source} · {props.instance().sourceKind}</span></div>
    <div class="instance-affordance"><strong>{props.instance().active ? 'Active now' : 'Inactive now'} · {props.instance().enabledAtLaunch ? 'enabled at launch' : 'disabled at launch'}</strong><span>Start, stop, restart, and enablement are managed in the Riela menu-bar app.</span></div>
    <Show when={props.instance().requiredEnvironment.length > 0}><div class="requirements" aria-label="Required environment"><h3>Required environment</h3><For each={props.instance().requiredEnvironment}>{(requirement) => <div class="requirement-row"><span classList={{ 'presence-dot': true, present: requirement.present }} aria-hidden="true" /><div><strong>{requirement.name}</strong><span>{requirement.description ?? 'No description'} · {requirement.source}</span></div><span>{requirement.present ? 'Present' : 'Missing'}</span></div>}</For></div></Show>
    <div class="form-grid"><label><span>Working directory</span><input value={workingDirectory()} onInput={(event) => setWorkingDirectory(event.currentTarget.value)} /></label><label><span>Environment file</span><input value={environmentFilePath()} onInput={(event) => setEnvironmentFilePath(event.currentTarget.value)} /></label></div>
    <div class="secret-editor"><h3>Inline environment variables</h3><p>Stored values are never returned. Leave a replacement blank to keep it, or explicitly clear it.</p>
      <For each={props.instance().environmentVariables}>{(variable) => <div class="secret-row"><label><span>{variable.name} · {variable.masked}</span><input type="password" autocomplete="new-password" placeholder="Leave blank to keep current value" value={environmentUpdates()[variable.name] ?? ''} onInput={(event) => setEnvironmentUpdates((current) => ({ ...current, [variable.name]: event.currentTarget.value }))} /></label><label class="check-row clear-secret"><input type="checkbox" checked={environmentToClear().includes(variable.name)} onChange={(event) => toggleClear(variable.name, event.currentTarget.checked)} /><span>Clear</span></label></div>}</For>
      <div class="secret-row"><label><span>New variable name</span><input autocomplete="off" value={newEnvironmentName()} onInput={(event) => setNewEnvironmentName(event.currentTarget.value)} /></label><label><span>New write-only value</span><input type="password" autocomplete="new-password" value={newEnvironmentValue()} onInput={(event) => setNewEnvironmentValue(event.currentTarget.value)} /></label></div>
    </div>
    <label><span>Workflow variables</span><textarea aria-describedby="workflow-variables-hint workflow-variables-error" aria-invalid={Boolean(variablesValidation().error)} rows="7" value={variables()} onInput={(event) => setVariables(event.currentTarget.value)} /></label>
    <small id="workflow-variables-hint">JSON object passed to each run.</small>
    <Show when={variablesValidation().error}><p id="workflow-variables-error" class="field-error" role="alert">{variablesValidation().error}</p></Show>
    <div class="node-patches"><h3>Node patches</h3><Show when={Object.keys(props.instance().nodePatches).length === 0}><p>No node patches.</p></Show><For each={Object.entries(props.instance().nodePatches).sort(([left], [right]) => left.localeCompare(right))}>{([nodeId, patch]) => <div class="patch-row"><strong>{nodeId}</strong><span>Backend: {patch.executionBackend ?? 'default'}</span><span>Model: {patch.model ?? 'default'}</span><span>Effort: {patch.effort ?? 'default'}</span></div>}</For></div>
    <div class="save-row"><Show when={message()}><MutationMessage message={message()} isError={saveError()} onRefresh={conflict() ? () => void refreshAndRebase() : undefined} /></Show><button disabled={saving() || Boolean(variablesValidation().error)} onClick={() => void save()}>{saving() ? 'Saving…' : 'Save changes'}</button></div>
  </div>
}
