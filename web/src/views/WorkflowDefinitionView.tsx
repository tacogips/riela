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

export function WorkflowDefinitionView(props: { profileKey: string; sourceId: string; onBack: () => void }) {
  const [resource, { refetch }] = createResource(
    () => ({ profileKey: props.profileKey, sourceId: props.sourceId }),
    async (key) => ({ ...key, detail: await api.get<WorkflowDefinitionResponse>(
      `/api/v1/workflows/sources/${encodeURIComponent(key.sourceId)}/definition`) }),
  )
  const current = createMemo(() => {
    const loaded = resource()
    return !resource.loading && !resource.error
      && discoveredDefinitionMatchesSelection(props.profileKey, props.sourceId, loaded) ? loaded?.detail : undefined
  })
  const [selectedId, setSelectedId] = createSignal('')
  return <section class="page workflow-definition-page">
    <PageHeader eyebrow="WORKFLOW DEFINITION" title={current()?.name ?? 'Workflow definition'}
      description={current()?.definition.description ?? 'Inspect the workflow’s nodes and connections.'}
      actions={<><button class="secondary" onClick={props.onBack}>Back to workflows</button>
        <button class="secondary" onClick={() => void refetch()}>Refresh definition</button></>} />
    <Show when={resource.loading}><LoadingState label="Loading workflow graph…" /></Show>
    <Show when={resource.error}><ErrorBanner message={String(resource.error)} /></Show>
    <Show when={current()} keyed>{(workflow) => {
      const graph = definitionGraph(workflow)
      const selected = () => graph.nodes.find(node => node.id === selectedId())
      const nodeById = new Map(graph.nodes.map(node => [node.id, node]))
      return <>
        <div class="definition-summary"><span>{workflow.sourceKind} · {workflow.scope}</span>
          <span>{workflow.definition.steps.length} steps · {workflow.definition.nodes.length} nodes · {graph.edges.length} connections</span></div>
        <div class="definition-network-layout">
          <div class="definition-network-stage">
            <OpsScene bounds={graph.bounds} fitKey={`${workflow.sourceId}:${workflow.definitionRevision}`}
              label={`Workflow graph ${workflow.name}`} interactive fitPadding={35}>
              <defs><marker id="definition-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" /></marker></defs>
              <For each={graph.edges}>{edge => {
                const from = nodeById.get(edge.from)!
                const to = nodeById.get(edge.to)!
                return <g class="definition-connection" aria-label={`${from.title} to ${to.title}${edge.label ? `: ${edge.label}` : ''}`}>
                  <path d={definitionEdgePath(from, to)} marker-end="url(#definition-arrow)" />
                  <Show when={edge.label}><text x={(from.x + to.x) / 2 + 12} y={(from.y + to.y) / 2 - 8}>{edge.label}</text></Show>
                </g>
              }}</For>
              <For each={graph.nodes}>{node => <g classList={{ 'definition-network-node': true, selected: selectedId() === node.id, external: node.kind === 'external', unused: node.kind === 'unused' }}
                transform={`translate(${node.x}, ${node.y})`} data-canvas-interactive role="button" tabindex="0"
                aria-label={`Inspect node ${node.title}`} aria-pressed={selectedId() === node.id}
                onClick={() => setSelectedId(node.id)}
                onKeyDown={event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); setSelectedId(node.id) } }}>
                <title>{node.title} · {node.nodeId} · {node.caption}</title>
                <rect x="-130" y="-62" width="260" height="124" rx="14" />
                <text x="-112" y="-34" class="definition-node-eyebrow">{node.entry ? 'ENTRY' : node.kind === 'step' ? 'STEP' : node.kind.toUpperCase()}</text>
                <text x="-112" y="-7" class="definition-node-title">{node.title.length > 26 ? `${node.title.slice(0, 25)}…` : node.title}</text>
                <text x="-112" y="18">{node.nodeId.length > 30 ? `${node.nodeId.slice(0, 29)}…` : node.nodeId}</text>
                <text x="-112" y="43">{node.caption}</text>
              </g>}</For>
            </OpsScene>
            <Show when={!graph.nodes.length}><div class="definition-empty">This workflow has no nodes.</div></Show>
            <div class="definition-network-hint">Select a node to inspect · drag the background to pan · scroll to zoom</div>
          </div>
          <aside class="panel definition-node-inspector" aria-label="Node details">
            <Show when={selected()} fallback={<><h2>Node details</h2><p>Select a node in the graph to inspect its connections.</p></>}>{node => <>
              <h2>{node().title}</h2><p>{node().caption}</p>
              <dl><dt>Node</dt><dd>{node().nodeId}</dd><dt>Entry step</dt><dd>{node().entry ? 'Yes' : 'No'}</dd></dl>
              <h3>Outgoing connections</h3>
              <Show when={!graph.edges.some(edge => edge.from === node().id)}><p>No outgoing connections.</p></Show>
              <For each={graph.edges.filter(edge => edge.from === node().id)}>{edge =>
                <button class="secondary" onClick={() => setSelectedId(edge.to)}>{nodeById.get(edge.to)?.title}{edge.label ? ` · ${edge.label}` : ''}</button>
              }</For>
            </>}</Show>
          </aside>
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
