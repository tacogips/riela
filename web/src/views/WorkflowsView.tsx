import { For, Show, createResource, createSignal } from 'solid-js'
import { APIError, api } from '../api'
import type { WorkflowSources } from '../contracts'
import { EmptyState, ErrorBanner, LoadingState, MutationMessage, PageHeader } from '../components/Primitives'

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export function WorkflowsView() {
  const [sources, { refetch }] = createResource(() => api.get<WorkflowSources>('/api/v1/workflows/sources'))
  const [path, setPath] = createSignal('')
  const [message, setMessage] = createSignal('')
  const [mutationError, setMutationError] = createSignal(false)
  const [conflict, setConflict] = createSignal(false)
  const [saving, setSaving] = createSignal(false)
  const add = async () => {
    setMessage(''); setMutationError(false); setConflict(false); setSaving(true)
    try {
      await api.mutate('/api/v1/workflows/sources/directories', 'POST', { path: path() })
      setPath(''); setMessage('Workflow directory added.'); void refetch()
    } catch (error) {
      const isConflict = error instanceof APIError && error.status === 409
      setConflict(isConflict); setMutationError(true)
      setMessage(isConflict ? 'Changed elsewhere — refresh before adding this directory.' : errorMessage(error))
    } finally { setSaving(false) }
  }
  const configuredCount = () => (sources()?.directories.length ?? 0) + (sources()?.projectDirectories.length ?? 0) + (sources()?.repositories.length ?? 0)
  return <section class="page"><PageHeader eyebrow="DISCOVERY" title="Workflow sources" description="Directories, repositories, and discovered workflow definitions." />
    <div class="surface-notice"><strong>Package actions live elsewhere</strong><span>Import, update, and remove packages in the native app’s Install Workflow pane or with the Riela CLI.</span></div>
    <Show when={sources.loading}><LoadingState label="Loading workflow sources…" /></Show>
    <Show when={sources.error}><ErrorBanner message={errorMessage(sources.error)} /></Show>
    <Show when={message()}><MutationMessage message={message()} isError={mutationError()} onRefresh={conflict() ? () => void refetch() : undefined} /></Show>
    <div class="add-source"><label class="grow" for="workflow-directory"><span>Additional workflow directory</span><input id="workflow-directory" placeholder="/absolute/path/to/workflows" value={path()} onInput={(event) => setPath(event.currentTarget.value)} /></label><button disabled={!path().trim() || saving()} onClick={() => void add()}>{saving() ? 'Adding…' : 'Add directory'}</button></div>
    <Show when={!sources.loading && !sources.error}><div class="two-column"><div class="panel"><div class="section-title"><h2>Configured sources</h2><span>{configuredCount()}</span></div><Show when={configuredCount() === 0}><EmptyState title="No sources configured" detail="Add a directory or use the native app to install a package." /></Show><For each={[...(sources()?.directories ?? []), ...(sources()?.projectDirectories ?? [])]}>{(item) => <div class="list-row"><span class="row-icon">D</span><div><strong>{item.split('/').at(-1)}</strong><span>{item} · directory</span></div></div>}</For><For each={sources()?.repositories}>{(item) => <div class="list-row"><span class="row-icon">G</span><div><strong>{item.id}</strong><span>{item.source} · repository</span></div></div>}</For></div>
      <div class="panel"><div class="section-title"><h2>Discovered workflows</h2><span>{sources()?.discovered.length ?? 0}</span></div><Show when={sources()?.discovered.length === 0}><EmptyState title="Nothing discovered" detail="Add a source directory to discover workflows." /></Show><For each={sources()?.discovered}>{(item) => <div class="list-row"><span class="row-icon">W</span><div><strong>{item.name}</strong><span>{item.workflowId} · {item.scope} · {item.sourceKind}</span></div></div>}</For></div></div></Show>
  </section>
}
