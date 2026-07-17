import { For, Show, createResource, createSignal } from 'solid-js'
import { api } from '../api'
import type { WorkflowSources } from '../contracts'
import { EmptyState, ErrorBanner, PageHeader } from '../components/Primitives'

export function WorkflowsView() {
  const [sources, { refetch }] = createResource(() => api.get<WorkflowSources>('/api/v1/workflows/sources'))
  const [path, setPath] = createSignal('')
  const [error, setError] = createSignal('')
  const add = async () => {
    setError('')
    try { await api.mutate('/api/v1/workflows/sources/directories', 'POST', { path: path() }); setPath(''); void refetch() }
    catch (reason) { setError(String(reason)) }
  }
  return <section class="page"><PageHeader eyebrow="DISCOVERY" title="Workflow sources" description="Directories, repositories, and discovered workflow definitions." />
    <Show when={error()}><ErrorBanner message={error()} /></Show>
    <div class="add-source"><input placeholder="/absolute/path/to/workflows" value={path()} onInput={(event) => setPath(event.currentTarget.value)} /><button disabled={!path().trim()} onClick={() => void add()}>Add directory</button></div>
    <div class="two-column"><div class="panel"><div class="section-title"><h2>Configured sources</h2><span>{(sources()?.directories.length ?? 0) + (sources()?.repositories.length ?? 0)}</span></div><For each={sources()?.directories}>{(item) => <div class="list-row"><span class="row-icon">D</span><div><strong>{item.split('/').at(-1)}</strong><span>{item}</span></div></div>}</For><For each={sources()?.repositories}>{(item) => <div class="list-row"><span class="row-icon">G</span><div><strong>{item.id}</strong><span>{item.source}</span></div></div>}</For></div>
      <div class="panel"><div class="section-title"><h2>Discovered workflows</h2><span>{sources()?.discovered.length ?? 0}</span></div><Show when={sources()?.discovered.length === 0}><EmptyState title="Nothing discovered" detail="Add a source directory to discover workflows." /></Show><For each={sources()?.discovered}>{(item) => <div class="list-row"><span class="row-icon">W</span><div><strong>{item.name}</strong><span>{item.workflowId} · {item.scope}</span></div></div>}</For></div></div>
  </section>
}
