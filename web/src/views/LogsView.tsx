import { For, Show, createResource, createSignal } from 'solid-js'
import { api } from '../api'
import type { ExecutionsResponse, InstancesResponse } from '../contracts'
import { EmptyState, PageHeader } from '../components/Primitives'

export function LogsView() {
  const [selected, setSelected] = createSignal('')
  const [instances] = createResource(() => api.get<InstancesResponse>('/api/v1/instances'))
  const [executions] = createResource(selected, (id) => api.get<ExecutionsResponse>(`/api/v1/instances/${encodeURIComponent(id)}/executions`))
  return <section class="page"><PageHeader eyebrow="OBSERVABILITY" title="Run logs" description="Execution timelines and diagnostics resolved from Riela's session store." />
    <div class="filter-row"><label><span>Instance</span><select value={selected()} onChange={(event) => setSelected(event.currentTarget.value)}><option value="">Choose an instance</option><For each={instances()?.items}>{(item) => <option value={item.id}>{item.name}</option>}</For></select></label></div>
    <Show when={!selected()}><EmptyState title="Choose an instance" detail="Select an instance to inspect its persisted run history." /></Show>
    <Show when={selected() && executions()?.items.length === 0}><EmptyState title="No persisted runs found" detail={executions()?.diagnostic ?? 'This instance has no available execution timeline.'} /></Show>
    <div class="timeline"><For each={executions()?.items}>{(execution) => <pre>{JSON.stringify(execution, null, 2)}</pre>}</For></div>
  </section>
}
