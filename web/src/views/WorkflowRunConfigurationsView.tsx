import { ActionButton } from '../components/ActionButton'
import { For, Show, createMemo, createSignal, onCleanup } from 'solid-js'
import { api, requireExpectedProfile } from '../api'
import { listConsoleInstances } from '../console/client'
import type { Execution, WorkflowSources } from '../contracts'
import { ErrorBanner, LoadingState, PageHeader } from '../components/Primitives'
import { createPollingResource } from '../polling'
import { InstanceEditor, MissingSourceDetail } from './InstancesView'
import { LogsView } from './LogsView'
import { WorkflowDefinitionView } from './WorkflowDefinitionView'
import './workflow-workspace.css'

const configurationStatus = (status: string): string => ({ running: 'Running', starting: 'Starting', reloading: 'Reloading', stopping: 'Stopping', stopped: 'Stopped', failed: 'Failed', needsSource: 'Source missing' })[status] ?? status

export type ConfigurationTab = 'settings' | 'history' | 'definition'

export function WorkflowRunConfigurationsView(props: {
  profileKey: string
  profileName: string
  sourceId: string
  selectedId: string
  tab: ConfigurationTab
  onSelect: (id: string, tab: ConfigurationTab) => void
  onBack: () => void
  onOpenRun: (run: Execution) => void
}) {
  const instances = createPollingResource(() => `${props.profileKey}:${props.sourceId}`, async signal =>
    requireExpectedProfile(await listConsoleInstances(signal), props.profileName))
  const sources = createPollingResource(() => props.profileKey, async signal =>
    requireExpectedProfile(await api.get<WorkflowSources>('/api/v1/workflows/sources', signal), props.profileName))
  const source = createMemo(() => sources.data()?.discovered.find(item => item.id === props.sourceId))
  const configurations = createMemo(() => (instances.data()?.items ?? [])
    .filter(item => item.sourceId === props.sourceId)
    .sort((a, b) => Number(b.isDefault) - Number(a.isDefault) || a.name.localeCompare(b.name)))
  const selected = createMemo(() => configurations().find(item => item.id === props.selectedId))
  let disposed = false
  onCleanup(() => { disposed = true })
  const [adding, setAdding] = createSignal(false)
  const [name, setName] = createSignal('')
  const [saving, setSaving] = createSignal(false)
  const [error, setError] = createSignal('')

  const add = async () => {
    if (!name().trim() || saving()) return
    setSaving(true); setError('')
    try {
      const response = requireExpectedProfile(await api.mutate<{ profile: string; revision: number; identity: string }>(
        '/api/v1/instances', 'POST',
        { sourceId: props.sourceId, name: name().trim(), expectedProfile: props.profileName },
        instances.data()?.revision,
      ), props.profileName)
      if (disposed) return
      await instances.refresh()
      if (disposed) return
      setAdding(false); setName('')
      props.onSelect(response.identity, 'settings')
    } catch (failure) { setError(failure instanceof Error ? failure.message : String(failure)) }
    finally { setSaving(false) }
  }

  return <section class="page workflow-workspace-page">
    <PageHeader eyebrow="WORKFLOW" title={source()?.name ?? configurations()[0]?.workflowId ?? 'Workflow'}
      actions={<><ActionButton class="secondary" onClick={props.onBack}>Back to workflows</ActionButton><ActionButton class="secondary" onClick={() => { void instances.refresh(); void sources.refresh() }}>Refresh configurations</ActionButton></>} />
    <Show when={instances.loading() && !instances.data()}><LoadingState label="Loading run configurations…" /></Show>
    <Show when={instances.error() || sources.error()}><ErrorBanner message={String(instances.error() ?? sources.error())} /></Show>
    <div class="workflow-workspace">
      <div class="workflow-graph-pane" aria-label="Workflow graph">
        <WorkflowDefinitionView embedded profileKey={props.profileKey} sourceId={props.sourceId} onBack={props.onBack} />
      </div>
      <aside class="workflow-configurations-pane" aria-label="Run configurations">
    <div class="configuration-list-section">
      <div class="section-title"><h2>Run configurations</h2><ActionButton disabled={!source() || saving()} onClick={() => setAdding(true)}>Add run configuration</ActionButton></div>
      <ul class="configuration-list" aria-label="Run configuration list"><For each={configurations()}>{item =>
        <li><button classList={{ 'configuration-list-row': true, selected: selected()?.id === item.id }}
          aria-pressed={selected()?.id === item.id} onClick={() => props.onSelect(item.id, 'settings')}>
          <span class={`status-dot ${item.status}`} aria-hidden="true" />
          <strong>{item.isDefault ? 'Default' : item.name}</strong>
          <span class="configuration-state">{configurationStatus(item.status)}</span>
          <Show when={item.requiredEnvironment.some(requirement => !requirement.present)}><span class="warning-badge">Set the required environment variables</span></Show>
        </button></li>
      }</For></ul>
      <Show when={adding()}><form class="add-source" onSubmit={event => { event.preventDefault(); void add() }}>
        <label class="grow"><span>Run configuration name</span><input value={name()} onInput={event => setName(event.currentTarget.value)} autofocus /></label>
        <ActionButton type="button" class="secondary" disabled={saving()} onClick={() => setAdding(false)}>Cancel</ActionButton>
        <ActionButton type="submit" disabled={!name().trim() || saving()}>{saving() ? 'Adding…' : 'Add'}</ActionButton>
      </form></Show>
      <Show when={error()}><ErrorBanner message={error()} /><ActionButton class="secondary" onClick={() => void instances.refresh()}>Reload latest configuration</ActionButton></Show>
    </div>
    <Show when={selected()} fallback={<p class="surface-notice">Select a run configuration.</p>}>{item => <>
      <nav class="filter-row" aria-label="Run configuration view">
        <ActionButton class="secondary" aria-pressed={props.tab !== 'history'} onClick={() => props.onSelect(item().id, 'settings')}>Settings & run</ActionButton>
        <ActionButton class="secondary" aria-pressed={props.tab === 'history'} onClick={() => props.onSelect(item().id, 'history')}>History</ActionButton>
      </nav>
      <Show when={props.tab !== 'history'}><Show when={item().status !== 'needsSource'} fallback={<MissingSourceDetail instance={item()} />}>
        <Show when={`${props.profileKey}:${item().id}`} keyed>{(_identity) => <InstanceEditor instance={item}
          profileName={props.profileName} revision={() => instances.data()?.revision ?? 0} onRefresh={instances.refresh} />}</Show>
      </Show></Show>
      <Show when={props.tab === 'history'}><LogsView scoped profileKey={props.profileKey} selectedInstanceId={item().id}
        onSelectInstance={id => props.onSelect(id, 'history')} onOpenRun={props.onOpenRun} /></Show>

    </>}</Show>
      </aside>
    </div>
  </section>
}
