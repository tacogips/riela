import { For, Show, createMemo, createResource, createSignal } from 'solid-js'
import { api } from '../api'
import type {
  OpsOverviewResponse,
  RunDetailGate,
  RunDetailLog,
  RunDetailResponse,
} from '../contracts'
import { ErrorBanner, LoadingState } from '../components/Primitives'
import { createPollingResource, pollingStatusLabel } from '../polling'
import { backEdgePath, edgePath } from './layout'
import { OpsScene } from './OpsScene'
import { RingNode, truncateMiddle } from './OpsGlyphs'
import { buildRunGraph, type RunGraphStep, type RunGraphVM } from './runGraph'
import { kindStyle, statusStyle } from './palette'

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export function OpsRunView(props: {
  profileKey: string
  instanceId: string
  sessionId: string
  workflowId: string
  onBack: () => void
}) {
  const detail = createPollingResource(
    () => `ops:${props.profileKey}:${props.instanceId}:${props.sessionId}`,
    (signal) => api.get<RunDetailResponse>(
      props.instanceId
        ? `/api/v1/instances/${encodeURIComponent(props.instanceId)}/executions/${encodeURIComponent(props.sessionId)}`
        : `/api/v1/executions/${encodeURIComponent(props.sessionId)}`,
      signal,
    ),
  )
  const [overview] = createResource(
    () => props.profileKey,
    () => api.get<OpsOverviewResponse>('/api/v1/ops/overview'),
  )
  const definition = createMemo(() => {
    const workflowId = detail.data()?.session.workflowId ?? props.workflowId
    return overview()?.workflows.find((workflow) => workflow.workflowId === workflowId)
  })
  const graph = createMemo(() => {
    const run = detail.data()
    return run ? buildRunGraph(run, definition()) : undefined
  })
  const [selectedStepId, setSelectedStepId] = createSignal('')
  const selectedStep = createMemo(() =>
    graph()?.steps.find((step) => step.stepId === selectedStepId()))
  const gatesByStep = createMemo(() => {
    const gates = new Map<string, RunDetailGate[]>()
    for (const gate of detail.data()?.gates ?? []) {
      const group = gates.get(gate.stepId) ?? []
      group.push(gate)
      gates.set(gate.stepId, group)
    }
    return gates
  })
  const sessionStatus = createMemo(() => detail.data()?.session.status)

  return (
    <section class="ops-shell" aria-label="Run command deck">
      <header class="ops-topline">
        <div class="ops-topline-title">
          <span class="eyebrow">{'// RUN TELEMETRY'}</span>
          <strong>{truncateMiddle(props.sessionId, 34)}<span class="ops-cursor" aria-hidden="true" /></strong>
        </div>
        <div class="ops-topline-meta">
          <span role="status">{pollingStatusLabel(detail.status())}</span>
          <Show when={sessionStatus()}>
            <span class="status-chip" style={{ color: statusStyle(sessionStatus()).color, 'border-color': statusStyle(sessionStatus()).color }}>
              {sessionStatus()}
            </span>
          </Show>
          <button class="secondary" onClick={props.onBack}>← Command deck</button>
          <button class="secondary" onClick={() => void detail.refresh()}>Refresh</button>
        </div>
      </header>
      <div class="ops-main">
        <Show when={detail.loading() && !detail.data()}>
          <LoadingState label="Reconstructing the run…" />
        </Show>
        <Show when={detail.error()}>
          <div style="padding: 18px"><ErrorBanner message={errorMessage(detail.error())} /></div>
        </Show>
        <Show when={detail.data() && graph()}>{(runGraph) => (
          <>
            <OpsScene
              bounds={runGraph().layout.bounds}
              fitKey={`run:${props.sessionId}:${runGraph().layout.nodes.length}`}
              label={`Execution map for run ${props.sessionId}`}
            >
              <RunScene
                graph={runGraph()}
                detail={detail.data()!}
                gatesByStep={gatesByStep()}
                selectedStepId={selectedStepId()}
                onSelectStep={setSelectedStepId}
              />
            </OpsScene>

            <Show when={detail.data()?.truncated}>
              <span class="ops-status-note" role="status">PARTIAL VIEW — persisted evidence was truncated</span>
            </Show>

            <aside class="ops-rail" aria-label="Run panels">
              <div class="ops-rail-panel">
                <h2>Session</h2>
                <dl class="ops-detail-meta">
                  <div><dt>workflow</dt><dd>{detail.data()?.session.workflowId}</dd></div>
                  <div><dt>status</dt><dd>{detail.data()?.session.status}</dd></div>
                  <div><dt>current</dt><dd>{detail.data()?.session.currentStepId ?? '—'}</dd></div>
                  <div><dt>updated</dt><dd>{new Date(detail.data()!.session.updatedAt).toLocaleTimeString()}</dd></div>
                  <div><dt>steps</dt><dd>{detail.data()?.stepsTotalCount}</dd></div>
                  <div><dt>gates</dt><dd>{detail.data()?.gatesTotalCount}</dd></div>
                </dl>
                <Show when={detail.data()?.recovery}>{(recovery) => (
                  <p style="margin-top: 8px">recovery · {recovery().entryMode}{recovery().parentSessionId ? ` · parent ${truncateMiddle(recovery().parentSessionId!, 16)}` : ''}</p>
                )}</Show>
              </div>
              <div class="ops-rail-panel">
                <h2>Legend</h2>
                <div class="ops-legend-row" style="color:#f2d268"><span class="ops-swatch">◍</span>running / current</div>
                <div class="ops-legend-row" style="color:#45d0a3"><span class="ops-swatch">◉</span>completed</div>
                <div class="ops-legend-row" style="color:#f4737f"><span class="ops-swatch">◉</span>failed</div>
                <div class="ops-legend-row" style="color:#5c7186"><span class="ops-swatch">◌</span>planned, not run</div>
                <div class="ops-legend-row" style="color:#7de5e5"><span class="ops-swatch-line" />traveled route</div>
                <div class="ops-legend-row" style="color:#44607a"><span class="ops-swatch-line dashed" />planned route</div>
                <div class="ops-legend-row" style="color:#c9a7e8"><span class="ops-swatch">◆</span>gate evidence</div>
              </div>
              <div class="ops-rail-panel">
                <h2>Steps · {runGraph().steps.length}</h2>
                <For each={runGraph().steps}>{(step) => (
                  <button
                    class="ops-directory-row"
                    aria-pressed={selectedStepId() === step.stepId}
                    onClick={() => setSelectedStepId(step.stepId)}
                  >
                    <span classList={{ 'ops-dot': true, live: step.status === 'running' || step.isCurrent, failed: step.status === 'failed', completed: step.status === 'completed' }} />
                    <span class="grow">{truncateMiddle(step.stepId, 20)}</span>
                    <small>{step.attempts > 0 ? `×${step.attempts}` : 'planned'}</small>
                  </button>
                )}</For>
              </div>
              <Show when={(detail.data()?.diagnostics.length ?? 0) > 0}>
                <div class="ops-rail-panel">
                  <h2>Diagnostics</h2>
                  <For each={detail.data()?.diagnostics}>{(diagnostic) => <p class="ops-rail-empty">{diagnostic.summary}</p>}</For>
                </div>
              </Show>
            </aside>

            <Show when={selectedStep()}>{(step) => (
              <RunStepDetailPanel
                step={step()}
                logs={detail.data()?.logs ?? []}
                gates={gatesByStep().get(step().stepId) ?? []}
                onClose={() => setSelectedStepId('')}
              />
            )}</Show>
          </>
        )}</Show>
      </div>
    </section>
  )
}

function RunScene(props: {
  graph: RunGraphVM
  detail: RunDetailResponse
  gatesByStep: Map<string, RunDetailGate[]>
  selectedStepId: string
  onSelectStep: (stepId: string) => void
}) {
  const nodeById = createMemo(() => new Map(props.graph.layout.nodes.map((node) => [node.id, node])))
  const stepById = createMemo(() => new Map(props.graph.steps.map((step) => [step.stepId, step])))
  const runEdge = (fromStepId: string, toStepId: string) =>
    props.graph.edges.find((edge) => edge.fromStepId === fromStepId && edge.toStepId === toStepId)
  const sessionStyle = () => statusStyle(props.detail.session.status)
  return (
    <>
      <For each={props.graph.layout.edges}>{(edge) => {
        const from = nodeById().get(edge.fromStepId)!
        const to = nodeById().get(edge.toStepId)!
        const meta = runEdge(edge.fromStepId, edge.toStepId)
        const traveled = meta?.traveled ?? false
        return (
          <path
            classList={{ 'ops-edge': true, 'ops-flow': traveled && (stepById().get(edge.toStepId)?.status === 'running' || stepById().get(edge.toStepId)?.isCurrent) }}
            d={edge.back ? backEdgePath(from.x, from.y, to.x, to.y) : edgePath(from.x, from.y - 26, to.x, to.y + 40)}
            stroke={traveled ? '#7de5e5' : edge.back ? '#8a7440' : '#44607a'}
            stroke-width={traveled ? 1.7 : 1}
            stroke-dasharray={traveled ? undefined : '5 5'}
            opacity={traveled ? 0.9 : 0.55}
          />
        )
      }}</For>
      <Show when={props.graph.entryStepId ? nodeById().get(props.graph.entryStepId) : undefined}>{(entry) => (
        <line class="ops-edge" x1="0" y1="-44" x2={entry().x} y2={entry().y + 40} stroke={sessionStyle().color} stroke-width="1.2" opacity="0.65" stroke-dasharray="2 6" />
      )}</Show>
      <For each={props.graph.layout.nodes}>{(node) => {
        const step = stepById().get(node.id)!
        const executed = step.attempts > 0
        const style = executed || step.isCurrent
          ? statusStyle(step.isCurrent && step.status !== 'failed' ? 'running' : step.status)
          : undefined
        const kind = kindStyle(step.kind, step.addon, step.role)
        const gates = props.gatesByStep.get(node.id) ?? []
        const blocking = gates.reduce((total, gate) => total + gate.blockingFindingCount, 0)
        return (
          <g>
            <RingNode
              x={node.x}
              y={node.y}
              radius={26}
              color={style?.color ?? '#3d566c'}
              glyph={kind.glyph}
              label={truncateMiddle(node.id, 24)}
              sublabel={executed
                ? `${step.status}${step.attempts > 1 ? ` · ${step.attempts} attempts` : ''}`
                : 'planned'}
              pulse={style?.pulse ?? false}
              selected={props.selectedStepId === node.id}
              dimmed={!executed && !step.isCurrent}
              badge={step.attempts > 1 ? `×${step.attempts}` : undefined}
              onClick={() => props.onSelectStep(node.id)}
              ariaLabel={`Inspect step ${node.id}`}
            />
            <Show when={gates.length > 0}>
              <g transform={`translate(${node.x + 36} ${node.y - 30})`} class="ops-node" role="button" aria-label={`Gate evidence for ${node.id}`} onClick={(event) => { event.stopPropagation(); props.onSelectStep(node.id) }}>
                <path d="M 0 -8 L 8 0 L 0 8 L -8 0 Z" fill="#0a0f18" stroke={blocking > 0 ? '#f4737f' : '#c9a7e8'} stroke-width="1.4" filter="url(#ops-glow)" />
                <text class="ops-node-sublabel" y="20" fill={blocking > 0 ? '#f4a0a8' : undefined}>{gates.length}</text>
              </g>
            </Show>
          </g>
        )
      }}</For>
      <RingNode
        x={0}
        y={0}
        radius={34}
        color={sessionStyle().color}
        glyph="◍"
        label={truncateMiddle(props.detail.session.sessionId, 30)}
        sublabel={`${props.detail.session.workflowId} · ${props.detail.session.status}`}
        pulse={sessionStyle().pulse}
      />
    </>
  )
}

function RunStepDetailPanel(props: {
  step: RunGraphStep
  logs: RunDetailLog[]
  gates: RunDetailGate[]
  onClose: () => void
}) {
  const executionIds = createMemo(() => new Set(props.step.executions.map((execution) => execution.executionId)))
  const routing = createMemo(() => props.logs.filter((log) =>
    (log.sourceStepExecutionId && executionIds().has(log.sourceStepExecutionId))
    || log.fromStepId === props.step.stepId
    || log.toStepId === props.step.stepId))
  return (
    <div class="ops-detail" role="dialog" aria-label={`Step ${props.step.stepId} detail`}>
      <div class="ops-detail-header">
        <div>
          <span class="eyebrow">{'// STEP TELEMETRY'}</span>
          <h2>{props.step.stepId}</h2>
        </div>
        <button class="ops-detail-close ops-hud-button" aria-label="Close detail" onClick={props.onClose}>×</button>
      </div>
      <div class="ops-detail-body">
        <div class="ops-chip-row">
          <span classList={{ 'ops-chip': true, active: props.step.status === 'running' || props.step.isCurrent, failed: props.step.status === 'failed' }}>
            {props.step.isCurrent ? 'current' : props.step.status ?? 'planned'}
          </span>
          <Show when={props.step.role}><span class="ops-chip">{props.step.role}</span></Show>
          <Show when={!props.step.planned}><span class="ops-chip">unplanned</span></Show>
          <Show when={props.step.addon}><span class="ops-chip">{props.step.addon}</span></Show>
        </div>
        <Show when={props.step.description}><h3>Brief</h3><p>{props.step.description}</p></Show>
        <h3>Signature</h3>
        <dl class="ops-detail-meta">
          <div><dt>node</dt><dd>{props.step.nodeId ?? '—'}</dd></div>
          <div><dt>attempts</dt><dd>{props.step.attempts}</dd></div>
        </dl>
        <h3>Executions</h3>
        <Show when={props.step.executions.length === 0}><p>Not executed yet.</p></Show>
        <For each={[...props.step.executions].reverse()}>{(execution) => (
          <div class="ops-exec-row">
            <header>
              <span>attempt {execution.attempt} · {execution.status}</span>
              <span>{execution.durationMs === null ? 'in flight' : `${Math.round(execution.durationMs)} ms`}</span>
            </header>
            <ul>
              <li><span class="ops-seq">◈</span><span>{execution.backend ?? 'default backend'} · {new Date(execution.startedAt).toLocaleTimeString()}</span></li>
              <For each={execution.events}>{(event) => (
                <li><span class="ops-seq">{event.sequence}</span><span>{event.eventType}{event.toolName ? ` · ${event.toolName}` : ''}{event.channel ? ` · ${event.channel}` : ''}</span></li>
              )}</For>
            </ul>
            <Show when={execution.eventsTruncated}><p class="ops-failure" style="color:#d6ba68">showing {execution.events.length} of {execution.eventTotalCount} events</p></Show>
            <Show when={execution.failureReason}><p class="ops-failure">{execution.failureReason}</p></Show>
          </div>
        )}</For>
        <h3>Routing</h3>
        <Show when={routing().length === 0}><p>No routing records touch this step.</p></Show>
        <For each={routing()}>{(log) => (
          <div class="ops-route-row">
            <span class="ops-route-glyph">{log.toStepId === props.step.stepId ? '←' : '→'}</span>
            <strong>{log.fromStepId ?? 'session'} → {log.toStepId ?? 'session'}</strong>
            <small>{log.status}{log.deliveryKind ? ` · ${log.deliveryKind}` : ''}</small>
          </div>
        )}</For>
        <Show when={props.gates.length > 0}>
          <h3>Gate evidence</h3>
          <For each={props.gates}>{(gate) => (
            <div class="ops-exec-row">
              <header><span>{gate.gateId}</span><span>{gate.decision}</span></header>
              <ul>
                <For each={gate.findings}>{(finding) => (
                  <li><span class="ops-seq">!</span><span>{finding.severity}: {finding.summary}</span></li>
                )}</For>
              </ul>
              <Show when={gate.findingsTruncated}><p class="ops-failure" style="color:#d6ba68">showing {gate.findings.length} of {gate.findingsTotalCount} findings</p></Show>
            </div>
          )}</For>
        </Show>
      </div>
    </div>
  )
}
