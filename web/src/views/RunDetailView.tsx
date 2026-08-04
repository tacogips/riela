import { For, Show } from 'solid-js'
import { api } from '../api'
import type { RunDetailLog, RunDetailResponse, RunDetailStep } from '../contracts'
import { EmptyState, ErrorBanner, LoadingState, PageHeader } from '../components/Primitives'
import { createPollingResource, pollingStatusLabel } from '../polling'

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export function RunDetailView(props: {
  profileKey: string
  instanceId: string
  sessionId: string
  workflowId: string
  onBack: () => void
}) {
  const detail = createPollingResource(
    () => `${props.profileKey}:${props.instanceId}:${props.workflowId}:${props.sessionId}`,
    (signal) => api.get<RunDetailResponse>(
      props.instanceId
        ? `/api/v1/instances/${encodeURIComponent(props.instanceId)}/executions/${encodeURIComponent(props.sessionId)}`
        : `/api/v1/executions/${encodeURIComponent(props.sessionId)}`,
      signal,
    ),
  )

  const additionalRoutingLogs = () => routingLogsWithoutVisibleExecution(
    detail.data()?.logs ?? [],
    detail.data()?.steps ?? [],
  )

  return <section class="page"><PageHeader eyebrow="RUN DETAIL" title={props.sessionId} description={`${props.workflowId} · persisted execution evidence`} actions={<div class="refresh-actions"><span role="status">{pollingStatusLabel(detail.status())}</span><button class="secondary" onClick={props.onBack}>Back to Run logs</button><button class="secondary" onClick={() => void detail.refresh()}>Refresh</button></div>} />
    <Show when={detail.loading() && !detail.data()}><LoadingState label="Loading run detail…" /></Show>
    <Show when={detail.error()}><ErrorBanner message={errorMessage(detail.error())} /></Show>
    <Show when={detail.data()}>{(run) => <>
      <div class="run-summary"><span class={`status-chip ${run().session.status}`}>{run().session.status}</span><span>Updated {new Date(run().session.updatedAt).toLocaleString()}</span><span>{run().session.currentStepId ? `Current step: ${run().session.currentStepId}` : 'No active step'}</span></div>
      <Show when={run().truncated}><p class="truncation-notice" role="status">Some persisted evidence was truncated for safe display.</p></Show>
      <div class="panel"><div class="section-title"><h2>Step executions</h2><span>{run().steps.length} of {run().stepsTotalCount}</span></div>
        <Show when={run().steps.length === 0}><EmptyState title="No step executions" detail="This run has no persisted step records." /></Show>
        <For each={run().steps}>{(step) => {
          const logs = () => logsForStepExecution(run().logs, step)
          return <article class="run-step">
            <header><div><strong>{step.stepId}</strong><span>{step.nodeId} · attempt {step.attempt}</span></div><span class={`status-chip ${step.status}`}>{step.status}</span></header>
            <dl><div><dt>Execution</dt><dd>{step.executionId}</dd></div><div><dt>Backend</dt><dd>{step.backend ?? 'default'}</dd></div><div><dt>Started</dt><dd>{new Date(step.startedAt).toLocaleString()}</dd></div><div><dt>Duration</dt><dd>{step.durationMs === null ? 'In progress' : `${Math.round(step.durationMs)} ms`}</dd></div></dl>
            <Show when={step.failureReason}><p class="field-error">{step.failureReason}</p></Show>
            <div class="event-list"><h3>Backend events</h3><Show when={step.events.length === 0}><p>No persisted event summaries.</p></Show><For each={step.events}>{(event) => <div><span>{event.sequence}</span><strong>{event.eventType}</strong><span>{event.channel ?? 'event'}{event.toolName ? ` · ${event.toolName}` : ''}</span><time>{new Date(event.at).toLocaleTimeString()}</time></div>}</For><Show when={step.eventsTruncated}><p class="truncation-notice">Showing {step.events.length} of {step.eventTotalCount} events.</p></Show></div>
            <div class="event-list"><h3>Step logs and routing</h3><Show when={logs().length === 0}><p>No persisted step log records.</p></Show><For each={logs()}>{(log) => <div><span>{log.createdOrder ?? '—'}</span><strong>{log.status}</strong><span>{log.fromStepId ?? 'session'} → {log.toStepId ?? 'session'} · {log.deliveryKind ?? log.direction}</span><time>{log.createdAt ? new Date(log.createdAt).toLocaleTimeString() : ''}</time></div>}</For></div>
          </article>
        }}</For>
      </div>
      <Show when={additionalRoutingLogs().length > 0}><div class="panel"><div class="section-title"><h2>Additional routing records</h2><span>{additionalRoutingLogs().length}</span></div><p class="subtle">These records do not identify a visible source execution.</p><div class="event-list"><For each={additionalRoutingLogs()}>{(log) => <div><span>{log.createdOrder ?? '—'}</span><strong>{log.status}</strong><span>{log.fromStepId ?? 'session'} → {log.toStepId ?? 'session'} · {log.deliveryKind ?? log.direction}</span><time>{log.createdAt ? new Date(log.createdAt).toLocaleTimeString() : ''}</time></div>}</For></div></div></Show>
      <Show when={run().logsTruncated}><p class="truncation-notice">Showing {run().logs.length} of {run().logsTotalCount} routing records.</p></Show>
      <div class="two-column run-evidence"><div class="panel"><div class="section-title"><h2>Gate and loop evidence</h2><span>{run().gates.length} of {run().gatesTotalCount}</span></div><Show when={run().gates.length === 0}><p class="subtle">No gate evidence recorded.</p></Show><For each={run().gates}>{(gate) => <div class="evidence-row"><strong>{gate.gateId}</strong><span>{gate.stepId} · {gate.decision}</span><span>{gate.blockingFindingCount} blocking findings</span><For each={gate.findings}>{(finding) => <span>{finding.severity}: {finding.summary}</span>}</For><Show when={gate.findingsTruncated}><span>Showing {gate.findings.length} of {gate.findingsTotalCount} findings.</span></Show></div>}</For></div>
        <div class="panel"><div class="section-title"><h2>Recovery lineage</h2></div><Show when={run().recovery} fallback={<p class="subtle">No recovery lineage recorded.</p>}>{(recovery) => <div class="evidence-row"><strong>{recovery().entryMode}</strong><span>Parent: {recovery().parentSessionId ?? 'none'}</span><span>Children: {recovery().childSessionIds.map((child) => child.value).join(', ') || 'none'}</span><Show when={recovery().childSessionIdsTruncated}><span>Showing {recovery().childSessionIds.length} of {recovery().childSessionIdsTotalCount} children.</span></Show><Show when={recovery().reason}><span>{recovery().reason}</span></Show></div>}</Show></div></div>
      <Show when={run().diagnostics.length > 0}><div class="diagnostics"><h2>Diagnostics</h2><For each={run().diagnostics}>{(diagnostic) => <p>{diagnostic.summary}</p>}</For><Show when={run().diagnosticsTruncated}><p class="truncation-notice">Showing {run().diagnostics.length} of {run().diagnosticsTotalCount} diagnostics.</p></Show></div></Show>
    </>}</Show>
  </section>
}

export function logsForStepExecution(
  logs: RunDetailLog[],
  step: RunDetailStep,
): RunDetailLog[] {
  return logs.filter((log) => log.sourceStepExecutionId === step.executionId)
}

export function routingLogsWithoutVisibleExecution(
  logs: RunDetailLog[],
  steps: RunDetailStep[],
): RunDetailLog[] {
  const visibleExecutionIds = new Set(steps.map((step) => step.executionId))
  return logs.filter((log) =>
    !log.sourceStepExecutionId || !visibleExecutionIds.has(log.sourceStepExecutionId))
}
