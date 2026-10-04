import { For, Show, createMemo, createResource, createSignal } from 'solid-js'
import { ActionButton } from '../components/ActionButton'
import { EmptyState, ErrorBanner, LoadingState } from '../components/Primitives'
import { APIError, api, requireExpectedProfile } from '../api'
import { configurationClient } from '../config/client'
import type { WorkflowSources } from '../contracts'
import { deleteMutableWorkflow, getEditorWorkflow, listMutableWorkflows, setMutableWorkflowActivation } from '../workflows/client'
import { WorkflowStudio } from '../workflows/WorkflowStudio'
import { searchWorkflows } from '../workflows/search'
import type { RegistryWorkflow } from '../workflows/types'
import { listConsoleInstances } from '../console/client'
import { createPollingResource } from '../polling'

export function WorkflowsView(props: { profileKey: string; profileName: string; onInspect: (sourceId: string) => void }) {
  const instances = createPollingResource(() => props.profileKey, async signal =>
    requireExpectedProfile(await listConsoleInstances(signal), props.profileName))
  const [sources, { refetch }] = createResource(() => props.profileKey,
    async () => requireExpectedProfile(await api.get<WorkflowSources>('/api/v1/workflows/sources'), props.profileName))
  const [registry, { refetch: refreshRegistry }] = createResource(() => props.profileKey, listMutableWorkflows)
  const [search, setSearch] = createSignal('')
  const [studio, setStudio] = createSignal<{ workflow?: RegistryWorkflow }>()
  const [importing, setImporting] = createSignal(false)
  const [path, setPath] = createSignal('')
  const [busy, setBusy] = createSignal(false)
  const [error, setError] = createSignal('')
  const [message, setMessage] = createSignal('')
  const rows = createMemo(() => searchWorkflows([
    ...(sources.error ? [] : sources()?.discovered ?? []).map(source => ({ ...source, kind: 'source' as const })),
    ...(registry.error ? [] : registry() ?? []).filter(workflow => workflow.mutable).map(workflow => ({ ...workflow, kind: 'mutable' as const })),
    ...[...new Map((instances.data()?.items ?? []).filter(item => item.status === 'needsSource').map(item => [item.sourceId, item])).values()]
      .map(item => ({ id: item.sourceId, name: item.name, workflowId: item.workflowId, description: 'Missing source', scope: item.source, kind: 'source' as const })),
  ], search()))
  const refresh = () => {
    void Promise.resolve(refetch()).catch(() => {})
    void Promise.resolve(refreshRegistry()).catch(() => {})
    void instances.refresh()
  }
  const openMutable = async (workflow: RegistryWorkflow) => {
    setBusy(true); setError('')
    try { setStudio({ workflow: await getEditorWorkflow(workflow) }) }
    catch (failure) { setError(String(failure)) }
    finally { setBusy(false) }
  }
  const manageMutable = async (workflow: RegistryWorkflow, remove: boolean) => {
    if (remove && !window.confirm(`Delete ${workflow.name}?`)) return
    setBusy(true); setError(''); setMessage('')
    try {
      if (remove) await deleteMutableWorkflow(workflow)
      else await setMutableWorkflowActivation(workflow, workflow.activationState !== 'ACTIVE')
      setMessage(remove ? 'Workflow deleted.' : workflow.activationState === 'ACTIVE' ? 'Workflow deactivated.' : 'Workflow activated.')
      await refreshRegistry()
    } catch (failure) { setError(String(failure)) }
    finally { setBusy(false) }
  }
  const addDirectory = async () => {
    const current = sources(); if (!current) return
    setBusy(true); setError('')
    try {
      await configurationClient.addWorkflowDirectory({ profile: props.profileName, revision: current.revision }, path())
      setImporting(false); setPath(''); await refetch()
    } catch (failure) { setError(failure instanceof APIError && failure.status === 409 ? 'Changed elsewhere — refresh before adding this directory.' : String(failure)) }
    finally { setBusy(false) }
  }
  return <Show when={!studio()} fallback={<WorkflowStudio profileKey={props.profileKey} newWorkflow={!studio()?.workflow}
    initialWorkflow={studio()?.workflow} onClose={() => { setStudio(undefined); refresh() }} />}>
    <section class="page workflow-list-page">
      <div class="workflow-list-toolbar">
        <label class="grow"><span class="action-button-caption">ワークフローを正規表現で検索</span><input type="search" placeholder="検索 (正規表現)"
          value={search()} aria-invalid={!!rows().error} aria-describedby={rows().error ? 'workflow-search-error' : undefined}
          onInput={event => setSearch(event.currentTarget.value)} /></label>
        <span class="source-label">{rows().items.length}</span>
        <ActionButton class="secondary" onClick={refresh}>Refresh</ActionButton>
        <ActionButton class="secondary" onClick={() => setImporting(value => !value)}>Import directory</ActionButton>
        <ActionButton onClick={() => setStudio({})}>新規ワークフローを作成</ActionButton>
      </div>
      <Show when={rows().error}><p id="workflow-search-error" class="field-error" role="alert">{rows().error}</p></Show>
      <Show when={error()}><ErrorBanner message={error()} /></Show>
      <Show when={message()}><p role="status">{message()}</p></Show>
      <Show when={importing()}><form class="add-source" onSubmit={event => { event.preventDefault(); void addDirectory() }}>
        <label class="grow"><span>Workflow directory</span><input required value={path()} placeholder="/absolute/path/to/workflows" onInput={event => setPath(event.currentTarget.value)} /></label>
        <ActionButton type="button" class="secondary" onClick={() => setImporting(false)}>Cancel</ActionButton>
        <ActionButton type="submit" disabled={busy() || !path().trim()}>Add directory</ActionButton>
      </form></Show>
      <div class="workflow-list-pane" role="region" aria-label="ワークフロー一覧" tabindex="0">
        <Show when={sources.loading || registry.loading || (instances.loading() && !instances.data())}><LoadingState label="Loading workflows…" /></Show>
        <Show when={sources.error || registry.error || instances.error()}><ErrorBanner message={String(sources.error ?? registry.error ?? instances.error())} /></Show>
        <For each={rows().items}>{item => <div class="workflow-source-row"><button class="list-row selectable-row" disabled={busy()}
          aria-label={item.kind === 'source' ? `ワークフローを開く ${item.name}` : `グラフを編集 ${item.name}`}
          onClick={() => item.kind === 'source' ? props.onInspect(item.id) : void openMutable(item)}>
          <span class="row-icon">W</span><div><strong>{item.name}</strong><span>{item.workflowId} · {item.scope}</span></div>
        </button><Show when={item.kind === 'mutable' ? item : undefined}>{workflow => {
          return <div class="header-actions">
            <ActionButton class="secondary" disabled={busy()} onClick={() => void manageMutable(workflow(), false)}>{workflow().activationState === 'ACTIVE' ? 'Deactivate' : 'Activate'}</ActionButton>
            <ActionButton class="danger" disabled={busy()} onClick={() => void manageMutable(workflow(), true)}>Delete</ActionButton>
          </div>
        }}</Show></div>}</For>
        <Show when={!sources.loading && !registry.loading && !sources.error && !registry.error && !rows().error && rows().items.length === 0}>
          <EmptyState title={search() ? '一致するワークフローがありません' : 'ワークフローがありません'} detail={search() ? '検索条件を変更してください。' : '＋から作成できます。'} />
        </Show>
      </div>
    </section>
  </Show>
}
