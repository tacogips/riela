import { For, Show } from 'solid-js'
import { api } from '../api'
import { listConsoleInstances } from '../console/client'
import type { Execution, ExecutionsResponse } from '../contracts'
import { EmptyState, ErrorBanner, LoadingState, PageHeader } from '../components/Primitives'
import { createPollingResource, pollingStatusLabel } from '../polling'

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export function LogsView(props: {
  profileKey: string
  scoped?: boolean
  selectedInstanceId: string
  onSelectInstance: (id: string) => void
  onOpenRun: (execution: Execution) => void
}) {
  const instances = createPollingResource(
    () => props.profileKey,
    (signal) => listConsoleInstances(signal),
  )
  const executions = createPollingResource(
    () => props.selectedInstanceId ? `${props.profileKey}:${props.selectedInstanceId}` : undefined,
    (signal) => api.get<ExecutionsResponse>(
      `/api/v1/instances/${encodeURIComponent(props.selectedInstanceId)}/executions`,
      signal,
    ),
  )

  return <section class="page"><PageHeader eyebrow="OBSERVABILITY" title="Run logs" description="Execution timelines and diagnostics resolved from Riela's session store." actions={<div class="refresh-actions"><span role="status">{pollingStatusLabel(executions.status())}</span><button class="secondary" disabled={!props.selectedInstanceId} onClick={() => void executions.refresh()}>Refresh</button></div>} />
    <Show when={instances.loading() && !instances.data()}><LoadingState label="実行設定を読み込み中…" /></Show>
    <Show when={instances.error()}><ErrorBanner message={errorMessage(instances.error())} /></Show>
    <Show when={!instances.loading() && !instances.error() && instances.data()?.items.length === 0}><EmptyState title="実行設定がありません" detail="ワークフローを追加すると、標準設定で実行できます。" /></Show>
    <Show when={!props.scoped && (instances.data()?.items.length ?? 0) > 0}><div class="filter-row"><label for="run-instance"><span>実行設定</span></label><select id="run-instance" value={props.selectedInstanceId} onChange={(event) => props.onSelectInstance(event.currentTarget.value)}><option value="">実行設定を選択</option><For each={instances.data()?.items}>{(item) => <option value={item.id}>{item.name}</option>}</For></select></div></Show>
    <Show when={!props.selectedInstanceId && !instances.loading() && !instances.error() && (instances.data()?.items.length ?? 0) > 0}><EmptyState title="実行設定を選択" detail="実行設定を選ぶと実行履歴を確認できます。" /></Show>
    <Show when={props.selectedInstanceId && executions.loading() && !executions.data()}><LoadingState label="Loading persisted runs…" /></Show>
    <Show when={executions.error()}><ErrorBanner message={errorMessage(executions.error())} /></Show>
    <Show when={props.selectedInstanceId && !executions.loading() && !executions.error() && executions.data()?.items.length === 0}><EmptyState title="No persisted runs" detail="この実行設定にはまだ実行履歴がありません。" /></Show>
    <Show when={executions.data()?.truncated}><p class="truncation-notice" role="status">Showing the latest 100 runs.</p></Show>
    <div class="timeline" aria-busy={executions.loading()}><For each={executions.data()?.items}>{(execution) => <button class="execution-row execution-open" aria-label={`Open run ${execution.sessionId}`} onClick={() => props.onOpenRun(execution)}><span class={`status-dot ${execution.status}`} aria-hidden="true" /><div><strong>{execution.sessionId}</strong><span>{execution.workflowId} · Updated {new Date(execution.updatedAt).toLocaleString()}</span><span>{execution.currentStepId ? `Current step: ${execution.currentStepId}` : 'No active step'}{execution.activeStepIds.length ? ` · ${execution.activeStepIds.length} active` : ''}</span></div><span class={`status-chip ${execution.status}`}>{execution.status}</span></button>}</For></div>
    <Show when={(executions.data()?.diagnostics.length ?? 0) > 0}><div class="diagnostics"><h2>Diagnostics</h2><For each={executions.data()?.diagnostics}>{(diagnostic) => <p>{diagnostic}</p>}</For></div></Show>
  </section>
}
