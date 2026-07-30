import { For, Show } from 'solid-js'
import { api } from '../api'
import type { Execution, ExecutionsResponse, InstancesResponse } from '../contracts'
import { EmptyState, ErrorBanner, LoadingState, PageHeader } from '../components/Primitives'
import { createPollingResource, pollingStatusLabel } from '../polling'

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export function LogsView(props: {
  profileKey: string
  selectedInstanceId: string
  onSelectInstance: (id: string) => void
  onOpenRun: (execution: Execution) => void
}) {
  const instances = createPollingResource(
    () => props.profileKey,
    (signal) => api.get<InstancesResponse>('/api/v1/instances', signal),
  )
  const executions = createPollingResource(
    () => props.selectedInstanceId ? `${props.profileKey}:${props.selectedInstanceId}` : undefined,
    (signal) => api.get<ExecutionsResponse>(
      `/api/v1/instances/${encodeURIComponent(props.selectedInstanceId)}/executions`,
      signal,
    ),
  )

  return <section class="page"><PageHeader eyebrow="OBSERVABILITY" title="Run logs" description="Execution timelines and diagnostics resolved from Riela's session store." actions={<div class="refresh-actions"><span role="status">{pollingStatusLabel(executions.status())}</span><button class="secondary" disabled={!props.selectedInstanceId} onClick={() => void executions.refresh()}>Refresh</button></div>} />
    <Show when={instances.loading() && !instances.data()}><LoadingState label="Loading instances…" /></Show>
    <Show when={instances.error()}><ErrorBanner message={errorMessage(instances.error())} /></Show>
    <Show when={!instances.loading() && !instances.error() && instances.data()?.items.length === 0}><EmptyState title="No instances available" detail="Add a workflow instance in the native app before inspecting runs." /></Show>
    <Show when={(instances.data()?.items.length ?? 0) > 0}><div class="filter-row"><label for="run-instance"><span>Instance</span></label><select id="run-instance" value={props.selectedInstanceId} onChange={(event) => props.onSelectInstance(event.currentTarget.value)}><option value="">Choose an instance</option><For each={instances.data()?.items}>{(item) => <option value={item.id}>{item.name}</option>}</For></select></div></Show>
    <Show when={!props.selectedInstanceId && !instances.loading() && !instances.error() && (instances.data()?.items.length ?? 0) > 0}><EmptyState title="Choose an instance" detail="Select an instance to inspect its persisted run history." /></Show>
    <Show when={props.selectedInstanceId && executions.loading() && !executions.data()}><LoadingState label="Loading persisted runs…" /></Show>
    <Show when={executions.error()}><ErrorBanner message={errorMessage(executions.error())} /></Show>
    <Show when={props.selectedInstanceId && !executions.loading() && !executions.error() && executions.data()?.items.length === 0}><EmptyState title="No persisted runs" detail="This instance has no available execution timeline." /></Show>
    <Show when={executions.data()?.truncated}><p class="truncation-notice" role="status">Showing the latest 100 runs.</p></Show>
    <div class="timeline" aria-busy={executions.loading()}><For each={executions.data()?.items}>{(execution) => <button class="execution-row execution-open" aria-label={`Open run ${execution.sessionId}`} onClick={() => props.onOpenRun(execution)}><span class={`status-dot ${execution.status}`} aria-hidden="true" /><div><strong>{execution.sessionId}</strong><span>{execution.workflowId} · Updated {new Date(execution.updatedAt).toLocaleString()}</span><span>{execution.currentStepId ? `Current step: ${execution.currentStepId}` : 'No active step'}{execution.activeStepIds.length ? ` · ${execution.activeStepIds.length} active` : ''}</span></div><span class={`status-chip ${execution.status}`}>{execution.status}</span></button>}</For></div>
    <Show when={(executions.data()?.diagnostics.length ?? 0) > 0}><div class="diagnostics"><h2>Diagnostics</h2><For each={executions.data()?.diagnostics}>{(diagnostic) => <p>{diagnostic}</p>}</For></div></Show>
  </section>
}
