import { For, Show, createEffect, createMemo, createSignal, on, onCleanup, onMount } from 'solid-js'
import { api, requireExpectedProfile } from '../api'
import type { OpsOverviewResponse, OpsRunSummary, OpsWorkflowStep } from '../contracts'
import { ErrorBanner, LoadingState } from '../components/Primitives'
import { createPollingResource, pollingStatusLabel } from '../polling'
import { backEdgePath, edgePath, layoutFan, layoutRing, ringBounds } from './layout'
import { seededCluster } from './scene'
import { OpsScene } from './OpsScene'
import { RingNode, edgeLabelAnchor, truncateMiddle } from './OpsGlyphs'
import {
  DEFAULT_LENS,
  applyLens,
  buildWorkflowHubs,
  carouselIndex,
  lensScopes,
  searchHubs,
  type WorkflowHubVM,
} from './overview'
import { hubColor, kindStyle, statusStyle } from './palette'

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

type DeckSelection =
  | { kind: 'workflow'; sourceId: string }
  | { kind: 'step'; sourceId: string; stepId: string }

const LIVE_STATUSES = new Set(['running', 'created'])

export function OpsWorkflowsView(props: {
  profileKey: string
  profileName: string
  onOpenRun: (run: OpsRunSummary) => void
}) {
  const overview = createPollingResource(
    () => props.profileKey,
    async (signal) => requireExpectedProfile(
      await api.get<OpsOverviewResponse>('/api/v1/ops/overview', signal),
      props.profileName,
    ),
  )
  const [lens, setLens] = createSignal(DEFAULT_LENS)
  const [query, setQuery] = createSignal('')
  const [focusedSourceId, setFocusedSourceId] = createSignal('')
  const [selection, setSelection] = createSignal<DeckSelection>()

  createEffect(on(() => props.profileKey, () => {
    setLens(DEFAULT_LENS)
    setQuery('')
    setFocusedSourceId('')
    setSelection(undefined)
  }, { defer: true }))

  const hubs = createMemo(() => {
    const data = overview.data()
    return data ? buildWorkflowHubs(data) : []
  })
  const visibleHubs = createMemo(() => searchHubs(applyLens(hubs(), lens()), query()))
  const focusedHub = createMemo(() =>
    visibleHubs().find((hub) => hub.workflow.sourceId === focusedSourceId())
      ?? hubs().find((hub) => hub.workflow.sourceId === focusedSourceId()))
  const selectedHub = createMemo(() => {
    const current = selection()
    return current ? hubs().find((hub) => hub.workflow.sourceId === current.sourceId) : undefined
  })
  const selectedStep = createMemo(() => {
    const current = selection()
    if (current?.kind !== 'step') return undefined
    return selectedHub()?.workflow.steps.find((step) => step.id === current.stepId)
  })

  const focusHub = (hub: WorkflowHubVM) => {
    setFocusedSourceId(hub.workflow.sourceId)
    setSelection({ kind: 'workflow', sourceId: hub.workflow.sourceId })
  }
  const exitFocus = () => {
    setFocusedSourceId('')
    setSelection(undefined)
  }
  const cycleFocus = (delta: number) => {
    const deck = visibleHubs()
    if (deck.length === 0) return
    const currentIndex = deck.findIndex((hub) => hub.workflow.sourceId === focusedSourceId())
    const nextHub = deck[carouselIndex(currentIndex < 0 ? 0 : currentIndex, currentIndex < 0 ? 0 : delta, deck.length)]!
    focusHub(nextHub)
  }

  onMount(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      if (selection() && selection()?.kind === 'step') setSelection({ kind: 'workflow', sourceId: selection()!.sourceId })
      else if (selection()) setSelection(undefined)
      else if (focusedSourceId()) exitFocus()
    }
    window.addEventListener('keydown', onKeyDown)
    onCleanup(() => window.removeEventListener('keydown', onKeyDown))
  })

  const recentRuns = createMemo(() => (overview.data()?.runs ?? []).slice(0, 12))
  const liveRunForFocus = createMemo(() => focusedHub()?.runs.find((run) => LIVE_STATUSES.has(run.status)))
  const totalSteps = createMemo(() => hubs().reduce((total, hub) => total + hub.workflow.steps.length, 0))
  const totalLive = createMemo(() => hubs().reduce((total, hub) => total + hub.liveRunCount, 0))

  return (
    <section class="ops-shell" aria-label="Workflow command deck">
      <header class="ops-topline">
        <div class="ops-topline-title">
          <span class="eyebrow">{'// CONTROL PLANE'}</span>
          <strong>Command deck<span class="ops-cursor" aria-hidden="true" /></strong>
        </div>
        <div class="ops-topline-meta">
          <span role="status">{pollingStatusLabel(overview.status())}</span>
          <span class="status-chip">{props.profileName || 'riela'}</span>
          <button class="secondary" onClick={() => void overview.refresh()}>Refresh</button>
        </div>
      </header>
      <div class="ops-main">
        <Show when={overview.loading() && !overview.data()}>
          <LoadingState label="Charting the deck…" />
        </Show>
        <Show when={overview.error()}>
          <div style="padding: 18px"><ErrorBanner message={errorMessage(overview.error())} /></div>
        </Show>
        <Show when={overview.data()}>
          <Show
            when={focusedHub()}
            fallback={
              <ConstellationScene
                hubs={visibleHubs()}
                profileName={props.profileName}
                totalSteps={totalSteps()}
                totalLive={totalLive()}
                onFocus={focusHub}
              />
            }
          >
            {(hub) => (
              <FocusScene
                hub={hub()}
                liveRun={liveRunForFocus()}
                selectedStepId={selection()?.kind === 'step' ? (selection() as { stepId: string }).stepId : undefined}
                onSelectStep={(stepId) => setSelection({ kind: 'step', sourceId: hub().workflow.sourceId, stepId })}
                onSelectHub={() => setSelection({ kind: 'workflow', sourceId: hub().workflow.sourceId })}
              />
            )}
          </Show>

          <Show when={focusedHub()}>
            <div class="ops-back">
              <button class="ops-hud-button" onClick={exitFocus}>← Deck</button>
            </div>
          </Show>
          <Show when={overview.data()?.workflowsTruncated || overview.data()?.runsTruncated}>
            <span class="ops-status-note" role="status">PARTIAL VIEW — some workflows or runs were truncated</span>
          </Show>

          <div class="ops-carousel" role="group" aria-label="Workflow carousel">
            <button aria-label="Previous workflow" onClick={() => cycleFocus(-1)}>‹</button>
            <span class="ops-carousel-label">{focusedHub()?.workflow.name ?? `All systems · ${visibleHubs().length}`}</span>
            <button aria-label="Next workflow" onClick={() => cycleFocus(1)}>›</button>
            <Show when={focusedHub()}>
              <button aria-label="Exit workflow focus" onClick={exitFocus}>×</button>
            </Show>
          </div>

          <aside class="ops-rail" aria-label="Deck panels">
            <div class="ops-rail-panel">
              <h2>Lens</h2>
              <label>
                <span>Find</span>
                <input
                  placeholder="query the deck…"
                  value={query()}
                  onInput={(event) => setQuery(event.currentTarget.value)}
                />
              </label>
              <label>
                <span>Scope</span>
                <select value={lens().scope} onChange={(event) => setLens({ ...lens(), scope: event.currentTarget.value })}>
                  <option value="all">all</option>
                  <For each={lensScopes(hubs())}>{(scope) => <option value={scope}>{scope}</option>}</For>
                </select>
              </label>
              <label>
                <span>Source</span>
                <select value={lens().sourceKind} onChange={(event) => setLens({ ...lens(), sourceKind: event.currentTarget.value })}>
                  <option value="all">all</option>
                  <option value="directory">directory</option>
                  <option value="package">package</option>
                </select>
              </label>
              <label class="ops-check">
                <input
                  type="checkbox"
                  checked={lens().liveOnly}
                  onChange={(event) => setLens({ ...lens(), liveOnly: event.currentTarget.checked })}
                />
                <span>live runs only</span>
              </label>
            </div>
            <div class="ops-rail-panel">
              <h2>Legend</h2>
              <div class="ops-legend-row" style="color:#7de5e5"><span class="ops-swatch">◉</span>agent step</div>
              <div class="ops-legend-row" style="color:#f08f7a"><span class="ops-swatch">✦</span>add-on step</div>
              <div class="ops-legend-row" style="color:#c9a7e8"><span class="ops-swatch">⑂</span>judge step</div>
              <div class="ops-legend-row" style="color:#8fd6a5"><span class="ops-swatch">▷</span>input / output</div>
              <div class="ops-legend-row" style="color:#e8c46b"><span class="ops-swatch">♜</span>manager</div>
              <div class="ops-legend-row" style="color:#7d9db5"><span class="ops-swatch-line" />transition</div>
              <div class="ops-legend-row" style="color:#e8c46b"><span class="ops-swatch-line dashed" />loop-back</div>
              <div class="ops-legend-row" style="color:#f2d268"><span class="ops-swatch">◍</span>live run</div>
            </div>
            <div class="ops-rail-panel">
              <h2>Directory · {visibleHubs().length}</h2>
              <Show when={visibleHubs().length === 0}><p class="ops-rail-empty">No workflows match the lens.</p></Show>
              <For each={visibleHubs()}>{(hub) => (
                <button
                  class="ops-directory-row"
                  aria-pressed={hub.workflow.sourceId === focusedSourceId()}
                  onClick={() => focusHub(hub)}
                >
                  <span classList={{ 'ops-dot': true, live: hub.liveRunCount > 0, failed: hub.liveRunCount === 0 && hub.failedRunCount > 0 }} />
                  <span class="grow">{hub.workflow.name}</span>
                  <small>{hub.workflow.steps.length}</small>
                </button>
              )}</For>
            </div>
            <div class="ops-rail-panel">
              <h2>Recent runs</h2>
              <Show when={recentRuns().length === 0}><p class="ops-rail-empty">No persisted runs yet.</p></Show>
              <For each={recentRuns()}>{(run) => (
                <button class="ops-directory-row" onClick={() => props.onOpenRun(run)}>
                  <span classList={{ 'ops-dot': true, live: LIVE_STATUSES.has(run.status), failed: run.status === 'failed', completed: run.status === 'completed' }} />
                  <span class="grow">{truncateMiddle(run.sessionId, 20)}</span>
                  <small>{run.workflowId.slice(0, 10)}</small>
                </button>
              )}</For>
            </div>
          </aside>

          <Show when={selection()}>
            <DeckDetailPanel
              selection={selection()!}
              hub={selectedHub()}
              step={selectedStep()}
              onClose={() => setSelection(undefined)}
              onFocus={() => { const hub = selectedHub(); if (hub) focusHub(hub) }}
              onSelectStep={(stepId) => {
                const current = selection()
                if (current) setSelection({ kind: 'step', sourceId: current.sourceId, stepId })
              }}
              onOpenRun={props.onOpenRun}
            />
          </Show>
        </Show>
      </div>
    </section>
  )
}

function ConstellationScene(props: {
  hubs: WorkflowHubVM[]
  profileName: string
  totalSteps: number
  totalLive: number
  onFocus: (hub: WorkflowHubVM) => void
}) {
  const positions = createMemo(() => layoutRing(props.hubs.length))
  const bounds = createMemo(() => ringBounds(positions()))
  return (
    <OpsScene
      bounds={bounds()}
      fitKey={`constellation:${props.hubs.length}`}
      label="Workflow constellation"
    >
      <CoreCluster profileName={props.profileName} workflowCount={props.hubs.length} totalSteps={props.totalSteps} totalLive={props.totalLive} />
      <For each={props.hubs}>{(hub, index) => {
        const position = () => positions()[index()]!
        const color = () => hubColor(index())
        return (
          <g>
            <line
              class="ops-edge"
              x1={Math.cos(position().angle) * 195}
              y1={Math.sin(position().angle) * 195}
              x2={position().x - Math.cos(position().angle) * 46}
              y2={position().y - Math.sin(position().angle) * 46}
              stroke={color()}
              stroke-width="1"
              stroke-dasharray="2 7"
              opacity="0.55"
            />
            <HubSatellites hub={hub} x={position().x} y={position().y} angle={position().angle} color={color()} />
            <RingNode
              x={position().x}
              y={position().y}
              radius={30}
              color={color()}
              glyph="⌘"
              label={truncateMiddle(hub.workflow.name, 24)}
              sublabel={`${hub.workflow.steps.length} steps · ${hub.liveRunCount} live${hub.failedRunCount ? ` · ${hub.failedRunCount} failed` : ''}`}
              pulse={hub.liveRunCount > 0}
              badge={hub.liveRunCount > 0 ? String(hub.liveRunCount) : undefined}
              onClick={() => props.onFocus(hub)}
              ariaLabel={`Focus workflow ${hub.workflow.name}`}
            />
          </g>
        )
      }}</For>
    </OpsScene>
  )
}

function CoreCluster(props: { profileName: string; workflowCount: number; totalSteps: number; totalLive: number }) {
  return (
    <g aria-hidden="true">
      <circle r="178" fill="none" stroke="#1d3444" stroke-width="1" />
      <circle r="150" fill="rgba(18, 40, 58, .18)" stroke="none" />
      <ClusterDots seed={props.profileName || 'riela'} />
      <text class="ops-hub-title" y="-8">{(props.profileName || 'RIELA').toUpperCase()}</text>
      <text class="ops-core-stat" y="14">{props.workflowCount} WORKFLOWS · {props.totalSteps} STEPS</text>
      <text class="ops-core-stat" y="30" fill={props.totalLive > 0 ? '#f2d268' : undefined}>{props.totalLive} LIVE RUNS</text>
    </g>
  )
}

const clusterPoints = (seed: string) => seededCluster(seed, 130, 132).filter((point) => Math.hypot(point.x, point.y) > 34)

function ClusterDots(props: { seed: string }) {
  return (
    <g opacity="0.75">
      <For each={clusterPoints(props.seed)}>{(point) => (
        <circle cx={point.x} cy={point.y} r={point.radius} fill="#e8956f" opacity="0.5" />
      )}</For>
    </g>
  )
}

function HubSatellites(props: { hub: WorkflowHubVM; x: number; y: number; angle: number; color: string }) {
  const satellites = () => props.hub.workflow.steps.slice(0, 9)
  return (
    <g opacity="0.8">
      <For each={satellites()}>{(_, index) => {
        const count = satellites().length
        const spread = Math.PI * 0.9
        const angle = props.angle - spread / 2 + (count <= 1 ? spread / 2 : (index() * spread) / (count - 1))
        const satelliteX = props.x + Math.cos(angle) * 68
        const satelliteY = props.y + Math.sin(angle) * 68
        return (
          <g>
            <line class="ops-edge" x1={props.x + Math.cos(angle) * 33} y1={props.y + Math.sin(angle) * 33} x2={satelliteX} y2={satelliteY} stroke={props.color} stroke-width="0.6" opacity="0.5" />
            <circle cx={satelliteX} cy={satelliteY} r="3.2" fill="#060d15" stroke={props.color} stroke-width="1" />
          </g>
        )
      }}</For>
    </g>
  )
}

function FocusScene(props: {
  hub: WorkflowHubVM
  liveRun: OpsRunSummary | undefined
  selectedStepId: string | undefined
  onSelectStep: (stepId: string) => void
  onSelectHub: () => void
}) {
  const fan = createMemo(() => layoutFan(props.hub.workflow.steps, props.hub.workflow.entryStepId))
  const nodeById = createMemo(() => new Map(fan().nodes.map((node) => [node.id, node])))
  const stepById = createMemo(() => new Map(props.hub.workflow.steps.map((step) => [step.id, step])))
  const graphNodeById = createMemo(() => new Map(props.hub.workflow.nodes.map((node) => [node.id, node])))
  const transitionFor = (fromStepId: string, toStepId: string) =>
    stepById().get(fromStepId)?.transitions.find((transition) => transition.toStepId === toStepId)
  const activeStepIds = createMemo(() => new Set([
    ...(props.liveRun?.activeStepIds ?? []),
    ...(props.liveRun?.currentStepId ? [props.liveRun.currentStepId] : []),
  ]))
  return (
    <OpsScene
      bounds={fan().bounds}
      fitKey={`focus:${props.hub.workflow.sourceId}:${fan().nodes.length}`}
      label={`Workflow map for ${props.hub.workflow.name}`}
    >
      <For each={fan().edges}>{(edge) => {
        const from = nodeById().get(edge.fromStepId)!
        const to = nodeById().get(edge.toStepId)!
        const transition = transitionFor(edge.fromStepId, edge.toStepId)
        const anchor = edgeLabelAnchor(from.x, from.y, to.x, to.y)
        return (
          <g>
            <path
              class="ops-edge"
              d={edge.back ? backEdgePath(from.x, from.y, to.x, to.y) : edgePath(from.x, from.y - 26, to.x, to.y + 40)}
              stroke={edge.back ? '#e8c46b' : '#7d9db5'}
              stroke-width={edge.back ? 1 : 1.3}
              stroke-dasharray={edge.back || transition?.fanoutJoinStepId ? '5 5' : undefined}
              opacity={edge.back ? 0.6 : 0.75}
            />
            <Show when={!edge.back && (transition?.label || transition?.fanoutJoinStepId)}>
              <text class="ops-edge-label" x={anchor.x} y={anchor.y}>
                {transition?.fanoutJoinStepId ? `⧉ fanout${transition.label ? ` · ${transition.label}` : ''}` : transition?.label}
              </text>
            </Show>
          </g>
        )
      }}</For>
      <line class="ops-edge" x1="0" y1="-44" x2={nodeById().get(fan().nodes.find((node) => node.tier === 0)?.id ?? '')?.x ?? 0} y2={(nodeById().get(fan().nodes.find((node) => node.tier === 0)?.id ?? '')?.y ?? -100) + 40} stroke="#7de5e5" stroke-width="1.1" opacity="0.6" stroke-dasharray="2 6" />
      <For each={fan().nodes}>{(node) => {
        const step = stepById().get(node.id)
        const graphNode = graphNodeById().get(node.id)
        const style = kindStyle(graphNode?.kind ?? null, graphNode?.addon ?? null, step?.role ?? (props.hub.workflow.managerStepId === node.id ? 'manager' : null))
        const isEntry = props.hub.workflow.entryStepId === node.id
        return (
          <RingNode
            x={node.x}
            y={node.y}
            radius={26}
            color={style.color}
            glyph={style.glyph}
            label={truncateMiddle(node.id, 24)}
            sublabel={`${style.label}${isEntry ? ' · entry' : ''}${graphNode?.addon ? ` · ${truncateMiddle(graphNode.addon, 20)}` : ''}`}
            pulse={activeStepIds().has(node.id)}
            selected={props.selectedStepId === node.id}
            onClick={() => props.onSelectStep(node.id)}
            ariaLabel={`Inspect step ${node.id}`}
          />
        )
      }}</For>
      <RingNode
        x={0}
        y={0}
        radius={34}
        color="#7de5e5"
        glyph="⌘"
        label={truncateMiddle(props.hub.workflow.name, 28)}
        sublabel={props.liveRun ? `live · ${statusStyle(props.liveRun.status).label}` : `${props.hub.runs.length} recent runs`}
        pulse={Boolean(props.liveRun)}
        onClick={props.onSelectHub}
        ariaLabel={`Inspect workflow ${props.hub.workflow.name}`}
      />
    </OpsScene>
  )
}

function DeckDetailPanel(props: {
  selection: DeckSelection
  hub: WorkflowHubVM | undefined
  step: OpsWorkflowStep | undefined
  onClose: () => void
  onFocus: () => void
  onSelectStep: (stepId: string) => void
  onOpenRun: (run: OpsRunSummary) => void
}) {
  const fedBy = createMemo(() => props.hub?.workflow.steps.filter((step) =>
    step.transitions.some((transition) => transition.toStepId === props.step?.id)) ?? [])
  const graphNode = createMemo(() => props.hub?.workflow.nodes.find((node) => node.id === props.step?.id))
  return (
    <div class="ops-detail" role="dialog" aria-label="Selection detail">
      <div class="ops-detail-header">
        <div>
          <span class="eyebrow">{props.selection.kind === 'step' ? '// STEP' : '// WORKFLOW'}</span>
          <h2>{props.selection.kind === 'step' ? props.step?.id ?? '' : props.hub?.workflow.name ?? ''}</h2>
        </div>
        <button class="ops-detail-close ops-hud-button" aria-label="Close detail" onClick={props.onClose}>×</button>
      </div>
      <div class="ops-detail-body">
        <Show when={props.selection.kind === 'workflow' && props.hub}>{(hub) => <>
          <Show when={hub().workflow.description}><p>{hub().workflow.description}</p></Show>
          <h3>Signature</h3>
          <dl class="ops-detail-meta">
            <div><dt>workflow id</dt><dd>{hub().workflow.workflowId}</dd></div>
            <div><dt>scope</dt><dd>{hub().workflow.scope}</dd></div>
            <div><dt>source</dt><dd>{hub().workflow.sourceKind}</dd></div>
            <div><dt>entry</dt><dd>{hub().workflow.entryStepId}</dd></div>
            <div><dt>manager</dt><dd>{hub().workflow.managerStepId ?? '—'}</dd></div>
            <div><dt>steps</dt><dd>{hub().workflow.steps.length}{hub().workflow.stepsTruncated ? '+' : ''}</dd></div>
          </dl>
          <h3>Instances</h3>
          <Show when={hub().instances.length === 0}><p>No configured instances.</p></Show>
          <For each={hub().instances}>{(instance) => (
            <div class="ops-route-row">
              <span class="ops-route-glyph" style={{ color: statusStyle(instance.status === 'running' ? 'running' : undefined).color }}>●</span>
              <strong>{instance.name}</strong>
              <small>{instance.status}</small>
            </div>
          )}</For>
          <h3>Recent runs</h3>
          <Show when={hub().runs.length === 0}><p>No persisted runs.</p></Show>
          <For each={hub().runs.slice(0, 8)}>{(run) => (
            <div class="ops-route-row">
              <span class="ops-route-glyph" style={{ color: statusStyle(run.status).color }}>◍</span>
              <strong>{truncateMiddle(run.sessionId, 22)}</strong>
              <small>{run.status}</small>
              <button class="ops-route-open ops-hud-button" onClick={() => props.onOpenRun(run)}>open</button>
            </div>
          )}</For>
          <div class="ops-detail-actions">
            <button class="secondary" onClick={props.onFocus}>Focus map</button>
          </div>
        </>}</Show>

        <Show when={props.selection.kind === 'step' && props.step}>{(step) => <>
          <div class="ops-chip-row">
            <span class="ops-chip">{kindStyle(graphNode()?.kind ?? null, graphNode()?.addon ?? null, step().role).label}</span>
            <Show when={step().role}><span class="ops-chip">{step().role}</span></Show>
            <Show when={props.hub?.workflow.entryStepId === step().id}><span class="ops-chip active">entry</span></Show>
            <Show when={props.hub?.workflow.managerStepId === step().id}><span class="ops-chip active">manager</span></Show>
          </div>
          <Show when={step().description}><h3>Brief</h3><p>{step().description}</p></Show>
          <h3>Signature</h3>
          <dl class="ops-detail-meta">
            <div><dt>node</dt><dd>{step().nodeId}</dd></div>
            <div><dt>add-on</dt><dd>{graphNode()?.addon ?? '—'}</dd></div>
            <div><dt>kind</dt><dd>{graphNode()?.kind ?? 'agent'}</dd></div>
            <div><dt>workflow</dt><dd>{props.hub?.workflow.workflowId}</dd></div>
          </dl>
          <h3>Routes to</h3>
          <Show when={step().transitions.length === 0}><p>Terminal step.</p></Show>
          <For each={step().transitions}>{(transition) => (
            <div class="ops-route-row">
              <span class="ops-route-glyph">→</span>
              <strong>{transition.toStepId}</strong>
              <small>{transition.fanoutJoinStepId ? `fanout · join ${transition.fanoutJoinStepId}` : transition.label ?? ''}</small>
              <button class="ops-route-open ops-hud-button" onClick={() => props.onSelectStep(transition.toStepId)}>view</button>
            </div>
          )}</For>
          <h3>Fed by</h3>
          <Show when={fedBy().length === 0}><p>Nothing routes here{props.hub?.workflow.entryStepId === step().id ? ' — this is the entry point.' : '.'}</p></Show>
          <For each={fedBy()}>{(feeder) => (
            <div class="ops-route-row">
              <span class="ops-route-glyph">←</span>
              <strong>{feeder.id}</strong>
              <button class="ops-route-open ops-hud-button" onClick={() => props.onSelectStep(feeder.id)}>view</button>
            </div>
          )}</For>
        </>}</Show>
      </div>
    </div>
  )
}
