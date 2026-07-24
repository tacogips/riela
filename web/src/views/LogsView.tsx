import { For, Show, createResource, createSignal } from 'solid-js'
import { api } from '../api'
import type { ExecutionsResponse, InstancesResponse } from '../contracts'
import { EmptyState, ErrorBanner, LoadingState, PageHeader } from '../components/Primitives'

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export function LogsView() {
  const [selected, setSelected] = createSignal('')
  const [instances] = createResource(() => api.get<InstancesResponse>('/api/v1/instances'))
  const [executions] = createResource(
    () => selected() || undefined,
    (id) => api.get<ExecutionsResponse>(`/api/v1/instances/${encodeURIComponent(id)}/executions`),
  )
  return <section class="page"><PageHeader eyebrow="OBSERVABILITY" title="Run logs" description="Execution timelines and diagnostics resolved from Riela's session store." />
    <Show when={instances.loading}><LoadingState label="Loading instances…" /></Show>
    <Show when={instances.error}><ErrorBanner message={errorMessage(instances.error)} /></Show>
    <Show when={!instances.loading && !instances.error && instances()?.items.length === 0}><EmptyState title="No instances available" detail="Add a workflow instance in the native app before inspecting runs." /></Show>
    <Show when={(instances()?.items.length ?? 0) > 0}><div class="filter-row"><label for="run-instance"><span>Instance</span><select id="run-instance" value={selected()} onChange={(event) => setSelected(event.currentTarget.value)}><option value="">Choose an instance</option><For each={instances()?.items}>{(item) => <option value={item.id}>{item.name}</option>}</For></select></label></div></Show>
    <Show when={!selected() && !instances.loading && !instances.error && (instances()?.items.length ?? 0) > 0}><EmptyState title="Choose an instance" detail="Select an instance to inspect its persisted run history." /></Show>
    <Show when={selected() && executions.loading}><LoadingState label="Loading persisted runs…" /></Show>
    <Show when={executions.error}><ErrorBanner message={errorMessage(executions.error)} /></Show>
    <Show when={selected() && !executions.loading && !executions.error && executions()?.items.length === 0}><EmptyState title="No persisted runs" detail="This instance has no available execution timeline." /></Show>
    <Show when={executions()?.truncated}><p class="truncation-notice" role="status">Showing the latest 100 runs.</p></Show>
    <div class="timeline" aria-busy={executions.loading}><For each={executions()?.items}>{(execution) => <article class="execution-row"><span class={`status-dot ${execution.status}`} aria-hidden="true" /><div><strong>{execution.sessionId}</strong><span>{execution.workflowId} · Updated {new Date(execution.updatedAt).toLocaleString()}</span><span>{execution.currentStepId ? `Current step: ${execution.currentStepId}` : 'No active step'}{execution.activeStepIds.length ? ` · ${execution.activeStepIds.length} active` : ''}</span></div><span class={`status-chip ${execution.status}`}>{execution.status}</span></article>}</For></div>
    <Show when={(executions()?.diagnostics.length ?? 0) > 0}><div class="diagnostics"><h2>Diagnostics</h2><For each={executions()?.diagnostics}>{(diagnostic) => <p>{diagnostic}</p>}</For></div></Show>
  </section>
}
