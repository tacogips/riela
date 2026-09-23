import { For, Show, createMemo, createResource, createSignal } from 'solid-js'
import { api } from '../api'
import type { WorkflowDefinitionResponse } from '../contracts'
import { ErrorBanner, LoadingState, PageHeader } from '../components/Primitives'
import { OpsScene } from '../ops/OpsScene'
import { definitionEdgePath, definitionGraph } from '../workflows/definitionGraph'
import '../workflows/definition.css'

export interface DiscoveredDefinitionResource {
  profileKey: string
  sourceId: string
  detail: WorkflowDefinitionResponse
}

export function discoveredDefinitionMatchesSelection(
  profileKey: string,
  selectedSourceId: string,
  resource: DiscoveredDefinitionResource | undefined,
): boolean {
  return Boolean(
    resource
      && resource.profileKey === profileKey
      && resource.sourceId === selectedSourceId,
  )
}

export function WorkflowDefinitionView(props: { profileKey: string; sourceId: string; onBack: () => void; embedded?: boolean }) {
  const [resource, { refetch }] = createResource(
    () => ({ profileKey: props.profileKey, sourceId: props.sourceId }),
    async (key) => ({ ...key, detail: await api.get<WorkflowDefinitionResponse>(
      `/api/v1/workflows/sources/${encodeURIComponent(key.sourceId)}/definition`) }),
  )
  const current = createMemo(() => {
    if (resource.loading || resource.error) return undefined
    const loaded = resource()
    return discoveredDefinitionMatchesSelection(props.profileKey, props.sourceId, loaded) ? loaded?.detail : undefined
  })
  const [selectedId, setSelectedId] = createSignal('')
  return <section classList={{ page: !props.embedded, 'workflow-definition-page': true, 'workflow-definition-embedded': props.embedded }}>
    <Show when={!props.embedded}><PageHeader eyebrow="WORKFLOW DEFINITION" title={current()?.name ?? 'Workflow definition'}
      description={current()?.definition.description ?? 'Inspect the workflow’s nodes and connections.'}
      actions={<><button class="secondary" onClick={props.onBack}>Back to workflows</button>
        <button class="secondary" onClick={() => void refetch()}>Refresh definition</button></>} /></Show>
    <Show when={props.embedded}><div class="graph-toolbar"><span>ワークフローグラフ</span><button class="secondary" onClick={() => void refetch()}>Refresh definition</button></div></Show>
    <Show when={resource.loading}><LoadingState label="Loading workflow graph…" /></Show>
    <Show when={resource.error}><ErrorBanner message={String(resource.error)} /></Show>
    <Show when={current()} keyed>{(workflow) => {
      const graph = definitionGraph(workflow)
      const selected = () => graph.nodes.find(node => node.id === selectedId())
      const [positions, setPositions] = createSignal<Record<string, { x: number; y: number }>>({})
      const [scale, setScale] = createSignal(1)
      const placedNode = (id: string) => {
        const node = graph.nodes.find(item => item.id === id)!
        return { ...node, ...(positions()[id] ?? {}) }
      }
      const bounds = createMemo(() => {
        const nodes = graph.nodes.map(node => placedNode(node.id))
        return nodes.length ? { minX: Math.min(...nodes.map(node => node.x)) - 170, maxX: Math.max(...nodes.map(node => node.x)) + 170,
          minY: Math.min(...nodes.map(node => node.y)) - 100, maxY: Math.max(...nodes.map(node => node.y)) + 100 } : graph.bounds
      })
      let drag: { id: string; pointer: number; x: number; y: number } | undefined
      const nodeById = new Map(graph.nodes.map(node => [node.id, node]))
      return <>
        <div class="definition-summary"><span>{workflow.sourceKind} · {workflow.scope}</span>
          <span>{workflow.definition.steps.length} steps · {workflow.definition.nodes.length} nodes · {graph.edges.length} connections</span></div>
        <div class="definition-network-layout">
          <div class="definition-network-stage">
            <OpsScene bounds={bounds()} onCameraChange={camera => setScale(camera.scale)} fitKey={`${workflow.sourceId}:${workflow.definitionRevision}`}
              label={`Workflow graph ${workflow.name}`} interactive fitPadding={35}>
              <defs><marker id="definition-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" /></marker></defs>
              <For each={graph.edges}>{edge => {
                const from = () => placedNode(edge.from)
                const to = () => placedNode(edge.to)
                return <g class="definition-connection" aria-label={`${from().title} to ${to().title}${edge.label ? `: ${edge.label}` : ''}`}>
                  <path d={definitionEdgePath(from(), to())} marker-end="url(#definition-arrow)" />
                  <Show when={edge.label}><text x={(from().x + to().x) / 2 + 12} y={(from().y + to().y) / 2 - 8}>{edge.label}</text></Show>
                </g>
              }}</For>
              <For each={graph.nodes}>{node => <g classList={{ 'definition-network-node': true, selected: selectedId() === node.id, external: node.kind === 'external', unused: node.kind === 'unused' }}
                transform={`translate(${placedNode(node.id).x}, ${placedNode(node.id).y})`} data-canvas-interactive role="button" tabindex="0"
                aria-label={`Inspect node ${node.title}`} aria-pressed={selectedId() === node.id}
                onPointerDown={event => {
                  if (event.button !== 0) return
                  event.stopPropagation()
                  event.currentTarget.setPointerCapture(event.pointerId)
                  drag = { id: node.id, pointer: event.pointerId, x: event.clientX, y: event.clientY }
                }}
                onPointerMove={event => {
                  if (!drag || drag.id !== node.id || drag.pointer !== event.pointerId) return
                  const current = placedNode(node.id)
                  setPositions(previous => ({ ...previous, [node.id]: {
                    x: current.x + (event.clientX - drag!.x) / scale(), y: current.y + (event.clientY - drag!.y) / scale(),
                  } }))
                  drag.x = event.clientX; drag.y = event.clientY
                }}
                onPointerUp={() => { drag = undefined }} onPointerCancel={() => { drag = undefined }}
                onClick={() => setSelectedId(node.id)}
                onKeyDown={event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); setSelectedId(node.id) } }}>
                <title>{node.title} · {node.nodeId} · {node.caption}</title>
                <rect x="-130" y="-62" width="260" height="124" rx="10" />
                <circle class="definition-port" cx="0" cy="-62" r="5" />
                <circle class="definition-port" cx="0" cy="62" r="5" />
                <text x="-112" y="-34" class="definition-node-eyebrow">{node.entry ? 'ENTRY' : node.kind === 'step' ? 'STEP' : node.kind.toUpperCase()}</text>
                <text x="-112" y="-7" class="definition-node-title">{node.title.length > 26 ? `${node.title.slice(0, 25)}…` : node.title}</text>
                <text x="-112" y="18">{node.nodeId.length > 30 ? `${node.nodeId.slice(0, 29)}…` : node.nodeId}</text>
                <text x="-112" y="43">{node.caption}</text>
              </g>}</For>
            </OpsScene>
            <Show when={!graph.nodes.length}><div class="definition-empty">This workflow has no nodes.</div></Show>
            <div class="definition-network-hint">Drag nodes to arrange · drag the background to pan · scroll to zoom</div>
          </div>
          <Show when={!props.embedded || selected()}><aside class="panel definition-node-inspector" aria-label="Node details">
            <Show when={props.embedded}><button class="secondary" onClick={() => setSelectedId('')}>閉じる</button></Show>
            <Show when={selected()} fallback={<><h2>Node details</h2><p>Select a node in the graph to inspect its connections.</p></>}>{node => <>
              <h2>{node().title}</h2><p>{node().caption}</p>
              <dl><dt>Node</dt><dd>{node().nodeId}</dd><dt>Entry step</dt><dd>{node().entry ? 'Yes' : 'No'}</dd></dl>
              <h3>Outgoing connections</h3>
              <Show when={!graph.edges.some(edge => edge.from === node().id)}><p>No outgoing connections.</p></Show>
              <For each={graph.edges.filter(edge => edge.from === node().id)}>{edge =>
                <button class="secondary" onClick={() => setSelectedId(edge.to)}>{nodeById.get(edge.to)?.title}{edge.label ? ` · ${edge.label}` : ''}</button>
              }</For>
            </>}</Show>
          </aside></Show>
        </div>
        <Show when={workflow.truncated}><p class="truncation-notice" role="status">This graph shows a bounded portion of the definition. Some nodes or connections are omitted.</p></Show>
        <Show when={workflow.diagnostics.length || workflow.diagnosticsTruncated}><div class="diagnostics"><h2>Validation diagnostics</h2>
          <For each={workflow.diagnostics}>{item => <p>{item.summary}{item.truncated ? ' (truncated)' : ''}</p>}</For>
          <Show when={workflow.diagnosticsTruncated}><p>Showing {workflow.diagnostics.length} of {workflow.diagnosticsTotalCount} diagnostics.</p></Show>
        </div></Show>
      </>
    }}</Show>
  </section>
}
