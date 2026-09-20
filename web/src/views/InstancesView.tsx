import { For, Show, createMemo, createSignal } from 'solid-js'
import { APIError, api, requireExpectedProfile } from '../api'
import { configurationClient } from '../config/client'
import type { Instance, InstanceResponse } from '../contracts'
import { MutationMessage } from '../components/Primitives'
import { validateJSONObject } from '../workflows/validation'

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
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

export function MissingSourceDetail(props: { instance: Instance }) {
  return <div class="editor-panel" role="status"><div class="section-title"><div><span class="eyebrow">SOURCE REQUIRED</span><h2>{props.instance.name}</h2></div><span class="status-chip needsSource">Needs source</span></div>
    <div class="instance-affordance"><strong>This run configuration cannot find its workflow source.</strong><span>{props.instance.source}</span><span>Relink or remove it in the native ワークフロー画面. Configuration and run history are unavailable until then.</span></div>
  </div>
}

export function InstanceEditor(props: {
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
  const defaultSource = JSON.stringify({ id: 'telegram-main', kind: 'telegram-gateway', config: {} }, null, 2)
  const defaultBinding = JSON.stringify({
    id: 'telegram-main-binding',
    sourceId: 'telegram-main',
    workflowName: initialInstance.workflowId,
  }, null, 2)
  const [eventSource, setEventSource] = createSignal(defaultSource)
  const [eventBinding, setEventBinding] = createSignal(defaultBinding)
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
      const response = await configurationClient.updateWorkflowInstance({
        profile: props.profileName,
        revision: expectedRevision(),
      }, {
        identity: props.instance().id,
        workingDirectory: workingDirectory(),
        environmentFilePath: environmentFilePath(),
        environmentVariableUpdates: updates,
        environmentVariablesToClear: environmentToClear(),
        workflowVariables: validation.value,
      })
      setExpectedRevision(response.revision)
      setMessage('Saved. Running configurations restart with the new configuration.')
      await props.onRefresh()
    } catch (error) {
      const isConflict = error instanceof APIError
        && (error.status === 409 || ['profile_conflict', 'revision_conflict'].includes(error.code))
      setConflict(isConflict); setSaveError(true)
      setMessage(isConflict ? 'Changed elsewhere — refresh before saving again.' : errorMessage(error))
    } finally { setSaving(false) }
  }

  const registerEventSource = async () => {
    const source = validateJSONObject(eventSource())
    const binding = validateJSONObject(eventBinding())
    if (!source.value || !binding.value) {
      setSaveError(true)
      setMessage(source.error ?? binding.error ?? 'Invalid event source configuration.')
      return
    }
    setSaving(true); setMessage(''); setSaveError(false); setConflict(false)
    try {
      const response = await configurationClient.registerEventSource({
        profile: props.profileName,
        revision: expectedRevision(),
      }, { identity: props.instance().id, source: source.value, binding: binding.value })
      setExpectedRevision(response.revision)
      setMessage('Event source registered. Running configurations restart automatically.')
      await props.onRefresh()
    } catch (error) {
      const isConflict = error instanceof APIError
        && (error.status === 409 || ['profile_conflict', 'revision_conflict'].includes(error.code))
      setConflict(isConflict); setSaveError(true)
      setMessage(isConflict ? 'Changed elsewhere — refresh before saving again.' : errorMessage(error))
    } finally { setSaving(false) }
  }

  const toggleClear = (name: string, checked: boolean) => {
    setEnvironmentToClear((current) => checked ? [...current, name] : current.filter((item) => item !== name))
  }

  const controlInstance = async (action: 'start' | 'stop' | 'restart' | 'enableAtLaunch' | 'disableAtLaunch') => {
    setSaving(true); setMessage(''); setSaveError(false)
    try {
      const response = await api.mutate<{ revision: number }>(
        `/api/v1/instances/${encodeURIComponent(props.instance().id)}/actions`, 'POST',
        { action, expectedProfile: props.profileName }, expectedRevision(),
      )
      setExpectedRevision(response.revision)
      setMessage('実行設定を更新しました。')
    } catch (error) {
      setSaveError(true); setMessage(errorMessage(error))
      setConflict(error instanceof APIError && error.status === 409)
    } finally {
      await props.onRefresh()
      setSaving(false)
    }
  }

  return <div class="editor-panel"><div class="section-title"><div><span class="eyebrow">CONFIGURATION</span><h2>{props.instance().name}</h2></div><span class="source-label">{props.instance().source} · {props.instance().sourceKind}</span></div>
    <div class="instance-affordance"><strong>{props.instance().active ? 'Active now' : 'Inactive now'} · {props.instance().enabledAtLaunch ? 'enabled at launch' : 'disabled at launch'}</strong>
        <div class="save-row instance-controls">
          <button disabled={saving() || props.instance().status === 'running'} onClick={() => void controlInstance('start')}>実行</button>
          <button class="secondary" disabled={saving() || props.instance().status === 'stopped'} onClick={() => void controlInstance('stop')}>停止</button>
          <button class="secondary" disabled={saving()} onClick={() => void controlInstance('restart')}>再実行</button>
          <button class="secondary" disabled={saving()} onClick={() => void controlInstance(props.instance().enabledAtLaunch ? 'disableAtLaunch' : 'enableAtLaunch')}>{props.instance().enabledAtLaunch ? 'Disable at launch' : 'Enable at launch'}</button>
        </div>
    </div>
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
    <div class="secret-editor"><h3>Register event source</h3><p>Source and binding JSON are validated and written under this workflow's .riela-events directory.</p><label><span>Source JSON</span><textarea rows="8" value={eventSource()} onInput={(event) => setEventSource(event.currentTarget.value)} /></label><label><span>Binding JSON</span><textarea rows="8" value={eventBinding()} onInput={(event) => setEventBinding(event.currentTarget.value)} /></label><div class="save-row"><button disabled={saving()} onClick={() => void registerEventSource()}>Register event source</button></div></div>
  </div>
}
