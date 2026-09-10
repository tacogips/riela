import { For, Show, createEffect, createMemo, createSignal } from 'solid-js'
import { OpsScene } from '../ops/OpsScene'
import { addStep, connectSteps, graphDocument, graphProblems, isLocalTransition, removeStep, type GraphDocument } from './graph'
import './editor.css'
import { readLayout, writeLayout, type GraphLayout } from './layout'
import { WorkflowAgentChat } from './WorkflowAgentChat'
import { WorkflowRunInspector } from './WorkflowRunInspector'
import { WorkflowRunControls } from './WorkflowRunControls'
import { WorkflowFileNodeSettings } from './WorkflowFileNodeSettings'
import type { RegistryWorkflow } from './types'

type Point = { x: number; y: number }

export function WorkflowGraphEditor(props: {
  initial: GraphDocument
  target?: RegistryWorkflow
  savedDefinition?: string
  canonicalDefinition?: GraphDocument
  onActivate: () => void
  onNodeSaved: (workflow: RegistryWorkflow) => void
  layoutStorageKey: string
  saving: boolean
  blocked?: boolean
  onSave: (definition: GraphDocument) => void
  onClose: () => void
}) {
  const [doc, setDoc] = createSignal(props.initial)
  const [generating, setGenerating] = createSignal(false)
  const [launchedSession, setLaunchedSession] = createSignal('')
  const [stepStatuses, setStepStatuses] = createSignal<Record<string, string>>({})
  const locked = () => props.saving || props.blocked || generating()
  const [undo, setUndo] = createSignal<GraphDocument[]>([])
  const [redo, setRedo] = createSignal<GraphDocument[]>([])
  createEffect(() => {
    const canonical = props.canonicalDefinition
    if (canonical) { setDoc(canonical); setUndo([]); setRedo([]) }
  })
  const [selected, setSelected] = createSignal('')
  const [connecting, setConnecting] = createSignal('')
  const [error, setError] = createSignal('')
  const layout = readLayout(localStorage, props.layoutStorageKey)
  const [positions, setPositions] = createSignal<Record<string, Point>>(layout.positions)
  const [layoutError, setLayoutError] = createSignal(false)
  const persistLayout = (patch: Partial<GraphLayout>) => {
    Object.assign(layout, patch)
    setLayoutError(!writeLayout(localStorage, props.layoutStorageKey, layout))
  }
  const [advanced, setAdvanced] = createSignal(false)
  const [json, setJSON] = createSignal('')
  const step = createMemo(() => doc().steps.find((item) => item.id === selected()))
  const node = createMemo(() => doc().nodes.find((item) => item.id === step()?.nodeId))
  const problems = createMemo(() => graphProblems(doc()))
  const point = (id: string): Point => positions()[id] ?? {
    x: (Math.max(0, doc().steps.findIndex((item) => item.id === id)) % 3) * 300,
    y: Math.floor(Math.max(0, doc().steps.findIndex((item) => item.id === id)) / 3) * 200,
  }
  const bounds = createMemo(() => {
    const points = doc().steps.length ? doc().steps.map((item) => point(item.id)) : [{ x: 0, y: 0 }]
    return { minX: Math.min(...points.map((p) => p.x)) - 12, minY: Math.min(...points.map((p) => p.y)) - 12,
      maxX: Math.max(...points.map((p) => p.x + 240)) + 12, maxY: Math.max(...points.map((p) => p.y + 130)) + 12 }
  })
  const change = (next: GraphDocument) => {
    if (locked()) return
    setUndo((items) => [...items.slice(-99), doc()]); setRedo([]); setDoc(next); setError('')
  }
  const attempt = (operation: () => void) => {
    try { operation(); setError('') } catch (failure) { setError(failure instanceof Error ? failure.message : String(failure)) }
  }
  const history = (back: boolean) => {
    const source = back ? undo() : redo()
    const previous = source.at(-1)
    if (!previous) return
    if (back) { setUndo(source.slice(0, -1)); setRedo([...redo(), doc()]) }
    else { setRedo(source.slice(0, -1)); setUndo([...undo(), doc()]) }
    setDoc(previous); setError('')
  }
  const updateNodeConfig = (field: string, value: string) => {
    const current = node()
    if (!current) return
    const addon = current.addon as Record<string, unknown> | undefined
    if (!addon) return
    const config = (addon.config ?? {}) as Record<string, unknown>
    change({ ...doc(), nodes: doc().nodes.map((item) => item.id === current.id
      ? { ...item, addon: { ...addon, config: { ...config, [field]: value } } } : item) })
  }
  const configText = (field: string) => {
    const addon = node()?.addon as { config?: Record<string, unknown> } | undefined
    return typeof addon?.config?.[field] === 'string' ? addon.config[field] as string : ''
  }
  let drag: { id: string; start: Point; pointer: Point } | undefined
  const svgPoint = (event: PointerEvent): Point => {
    const element = event.currentTarget as SVGElement
    const matrix = (element.parentElement as unknown as SVGGraphicsElement).getScreenCTM()
    const p = new DOMPoint(event.clientX, event.clientY).matrixTransform(matrix?.inverse())
    return { x: p.x, y: p.y }
  }

  return <section class="workflow-editor" aria-label="Workflow graph editor">
    <fieldset disabled={locked()} class="editor-controls">
    <header class="editor-toolbar">
      <strong>Workflow studio</strong>
      <button class="secondary" onClick={() => { if (undo().length === 0 || window.confirm('Discard unsaved workflow changes?')) props.onClose() }}>Back to graph</button>
      <button disabled={props.saving} onClick={() => { const next = addStep(doc()); change(next); setSelected(next.steps.at(-1)!.id) }}>Add agent step</button>
      <button class="secondary" disabled={!undo().length || props.saving} onClick={() => history(true)}>Undo</button>
      <button class="secondary" disabled={!redo().length || props.saving} onClick={() => history(false)}>Redo</button>
      <button class="secondary" onClick={() => { setJSON(JSON.stringify(doc(), null, 2)); setAdvanced(!advanced()) }}>Workflow JSON</button>
      <button disabled={props.saving || problems().length > 0} onClick={() => props.onSave(doc())}>{props.saving ? 'Saving…' : 'Save workflow'}</button>
    </header>
    <Show when={error()}><p class="field-error" role="alert">{error()}</p></Show>
    <Show when={layoutError()}><p role="status">Browser storage is unavailable. Layout changes will last only for this session.</p></Show>
    <div class="editor-body">
      <div class="editor-stage">
        <OpsScene bounds={bounds()} fitPadding={24} fitKey={`editor:${props.initial.workflowId}:${doc().steps.length}`} label={`Editable workflow ${doc().workflowId}`}
          initialCamera={layout.camera} onCameraChange={(camera) => persistLayout({ camera })}>
          <For each={doc().steps}>{(source) => <For each={source.transitions}>{(edge) => {
            const start = () => point(source.id)
            const end = () => isLocalTransition(doc(), edge) ? point(edge.toStepId) : { x: start().x + 360, y: start().y }
            return <g><path class="editor-edge" d={`M ${start().x + 240} ${start().y + 65} C ${start().x + 290} ${start().y + 65}, ${end().x - 50} ${end().y + 65}, ${end().x} ${end().y + 65}`} />
              <text class="editor-edge-label" x={(start().x + 240 + end().x) / 2} y={(start().y + end().y) / 2 + 52}>{String(edge.label ?? 'always')}{isLocalTransition(doc(), edge) ? '' : ` → ${String(edge.toWorkflowId)}/${edge.toStepId}`}</text></g>
          }}</For>}</For>
          <For each={doc().steps}>{(item) => <g data-canvas-interactive="true" transform={`translate(${point(item.id).x},${point(item.id).y})`}
            onPointerDown={(event) => {
              if (event.button !== 0 || (event.target as Element).closest('[data-port]')) return
              setSelected(item.id)
              drag = { id: item.id, start: point(item.id), pointer: svgPoint(event) }
              event.currentTarget.setPointerCapture(event.pointerId)
            }}
            onPointerMove={(event) => {
              if (drag?.id !== item.id) return
              const p = svgPoint(event)
              setPositions({ ...positions(), [item.id]: { x: drag.start.x + p.x - drag.pointer.x, y: drag.start.y + p.y - drag.pointer.y } })
            }}
            onPointerUp={() => { drag = undefined; persistLayout({ positions: positions() }) }} onPointerCancel={() => { drag = undefined; persistLayout({ positions: positions() }) }}>
            <rect classList={{ 'editor-node': true, selected: selected() === item.id }} width="240" height="130" rx="12" />
            <text x="18" y="30" class="editor-node-title">{item.id}</text>
            <text x="18" y="57" class="editor-node-caption">{item.nodeId}</text>
            <text x="18" y="83" class="editor-node-caption">{String(item.role ?? 'worker')}{doc().entryStepId === item.id ? ' · entry' : ''}{stepStatuses()[item.id] ? ` · ${stepStatuses()[item.id]}` : ''}</text>
            <foreignObject x="12" y="94" width="214" height="32"><button class="editor-select" onClick={() => setSelected(item.id)}>Edit {item.id}</button></foreignObject>
            <g data-port="true" role="button" tabindex="0" aria-label={`Connect to ${item.id}`} onClick={() => {
              if (connecting()) attempt(() => { change(connectSteps(doc(), connecting(), item.id)); setConnecting('') })
            }} onKeyDown={(event) => { if (event.key === 'Enter' && connecting()) attempt(() => { change(connectSteps(doc(), connecting(), item.id)); setConnecting('') }) }}>
              <circle class="editor-port" cx="0" cy="65" r="9" />
            </g>
            <g data-port="true" role="button" tabindex="0" aria-label={`Connect from ${item.id}`} onClick={() => setConnecting(item.id)}
              onKeyDown={(event) => { if (event.key === 'Enter') setConnecting(item.id) }}>
              <circle class="editor-port output" cx="240" cy="65" r="9" />
            </g>
          </g>}</For>
        </OpsScene>
        <div class="editor-hint" role="status">{connecting() ? `Connecting from ${connecting()} — choose an input port` : 'Drag nodes to arrange · drag background to pan · scroll to zoom'}</div>
        <Show when={connecting()}><button class="editor-cancel-link secondary" onClick={() => setConnecting('')}>Cancel connection</button></Show>
      </div>
      <aside class="editor-inspector">
        <label>Workflow ID<input value={doc().workflowId} disabled={props.saving || Boolean(props.target)} onChange={(event) => change({ ...doc(), workflowId: event.currentTarget.value })} /></label>
        <label>Description<textarea value={String(doc().description ?? '')} onChange={(event) => change({ ...doc(), description: event.currentTarget.value })} /></label>
        <label>Entry step<select aria-label="Entry step" value={doc().entryStepId} onChange={(event) => change({ ...doc(), entryStepId: event.currentTarget.value })}>
          <option value="" selected={!doc().entryStepId}>Choose entry</option><For each={doc().steps}>{(item) => <option value={item.id} selected={doc().entryStepId === item.id}>{item.id}</option>}</For>
        </select></label>
        <Show when={step()}>{(item) => <>
          <h3>{item().id}</h3>
          <Show when={typeof node()?.nodeFile === 'string'}>
            <WorkflowFileNodeSettings target={props.target} nodeId={item().nodeId}
              disabled={Boolean(locked()) || JSON.stringify(doc()) !== props.savedDefinition} onSaved={props.onNodeSaved} />
          </Show>
          <label>Role<select value={String(item().role ?? 'worker')} onChange={(event) => change({ ...doc(), steps: doc().steps.map((current) => current.id === item().id ? { ...current, role: event.currentTarget.value } : current) })}>
            <option value="worker">Worker</option><option value="manager">Manager</option>
          </select></label>
          <Show when={typeof (node()?.addon as Record<string, unknown> | undefined)?.name === 'string'}>
            <p>Prompt/model edits replace only those fields. Other protected settings are retained. Saving starts a new Undo history.</p>
            <Show when={['promptTemplate', 'model'].some((field) => {
              const value = (node()?.addon as { config?: Record<string, unknown> })?.config?.[field]
              return value !== undefined && typeof value !== 'string'
            })}><p role="status">A protected prompt or model is hidden. Leave its field untouched to retain it, or type a replacement.</p></Show>
            <label>Prompt<textarea rows="6" value={configText('promptTemplate')} onChange={(event) => updateNodeConfig('promptTemplate', event.currentTarget.value)} /></label>
            <label>Model<input value={configText('model')} onChange={(event) => updateNodeConfig('model', event.currentTarget.value)} /></label>
          </Show>
          <label>Node definition<textarea rows="7" value={JSON.stringify(node(), null, 2)} onChange={(event) => attempt(() => {
            const replacement = JSON.parse(event.currentTarget.value) as Record<string, unknown>
            if (replacement.id !== item().nodeId) throw new Error('Keep the referenced node ID unchanged.')
            change(graphDocument({ ...doc(), nodes: doc().nodes.map((current) => current.id === item().nodeId ? replacement : current) }))
          })} /></label>
          <h4>Connections</h4>
          <For each={item().transitions}>{(edge, index) => <div class="editor-connection"><span>→ {edge.toStepId}</span><button class="secondary" aria-label={`Disconnect ${item().id} to ${edge.toStepId}`} onClick={() => change({ ...doc(), steps: doc().steps.map((current) => current.id === item().id ? { ...current, transitions: current.transitions?.filter((_, n) => n !== index()) } : current) })}>Remove</button></div>}</For>
          <button class="danger" disabled={props.saving} onClick={() => attempt(() => { change(removeStep(doc(), item().id)); setSelected('') })}>Delete step</button>
        </>}</Show>
        <For each={problems()}>{(problem) => <p class="field-error">{problem}</p>}</For>
      </aside>
    </div>
    <Show when={advanced()}><div class="editor-json"><label>Complete workflow definition<textarea rows="16" value={json()} onInput={(event) => setJSON(event.currentTarget.value)} /></label><button onClick={() => attempt(() => { change(graphDocument(JSON.parse(json()))); setAdvanced(false) })}>Apply JSON to graph</button></div></Show>
    </fieldset>
    <WorkflowAgentChat definition={doc()} disabled={props.saving || Boolean(props.blocked)} onActive={setGenerating}
      onStart={() => { setUndo((items) => [...items.slice(-99), doc()]); setRedo([]) }}
      onDefinition={setDoc} />
    <WorkflowRunControls target={props.target} disabled={locked() || JSON.stringify(doc()) !== props.savedDefinition}
      onSession={setLaunchedSession} onActivate={props.onActivate} />
    <WorkflowRunInspector workflowId={doc().workflowId} launchedSessionId={launchedSession()} selectedStepId={selected()} onSelectStep={setSelected} onStepStatuses={setStepStatuses} />
  </section>
}
