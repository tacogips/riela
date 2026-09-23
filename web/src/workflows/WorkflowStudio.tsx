import { rielaFetch } from '../transport'
import { For, Show, createResource, createSignal } from 'solid-js'
import { getEditorWorkflow, listMutableWorkflows, registerMutableWorkflow, updateMutableWorkflow, setMutableWorkflowActivation } from './client'
import { graphDocument, newGraph, type GraphDocument } from './graph'
import { WorkflowGraphEditor } from './WorkflowGraphEditor'
import { layoutKey } from './layout'
import type { RegistryWorkflow } from './types'
import type { RegistryMutationPayload } from './types'
import { APIError, api } from '../api'

export function WorkflowStudio(props: { profileKey: string; source?: { id: string; name: string }; onClose: () => void }) {
  const [registry, { refetch }] = createResource(listMutableWorkflows)
  const [editing, setEditing] = createSignal<{ definition: GraphDocument; target?: RegistryWorkflow; key: string }>()
  const [busy, setBusy] = createSignal(false)
  const [target, setTarget] = createSignal<RegistryWorkflow>()
  const [savedDefinition, setSavedDefinition] = createSignal('')
  const [savedDocument, setSavedDocument] = createSignal<GraphDocument>()
  const [reloadRequired, setReloadRequired] = createSignal(false)
  const adoptSaved = (workflow: RegistryWorkflow) => {
    const definition = graphDocument(workflow.definition)
    setTarget(workflow); setSavedDefinition(JSON.stringify(definition)); setSavedDocument(definition)
    setReloadRequired(false)
    return definition
  }
  const [message, setMessage] = createSignal('')
  const [error, setError] = createSignal('')
  const [conflict, setConflict] = createSignal(false)
  const run = async (operation: () => Promise<void>) => {
    setBusy(true); setError(''); setMessage(''); setConflict(false)
    try { await operation() } catch (failure) {
      setError(failure instanceof Error ? failure.message : String(failure))
      if (reloadRequired()) setMessage('Workflow is saved, but its current revision could not be loaded. Use Reload saved workflow.')
      setConflict(failure instanceof APIError && failure.status === 409)
    }
    finally { setBusy(false) }
  }
  const save = (definition: GraphDocument) => void run(async () => {
    const current = editing()!
    const registering = !target()
    const result = target()
      ? await updateMutableWorkflow(target()!, definition)
      : await registerMutableWorkflow(definition)
    if (!result.workflow) throw new Error('Save was accepted without a workflow identity. Reopen Workflow studio to inspect the registry.')
    setTarget(result.workflow)
    setReloadRequired(true)
    const oldKey = layoutKey(props.profileKey, current.key)
    const newKey = layoutKey(props.profileKey, result.workflow.originId)
    if (registering) {
      try { const layout = localStorage.getItem(oldKey); if (layout) localStorage.setItem(newKey, layout) } catch { /* Editor reports storage failures. */ }
    }
    setMessage('Workflow saved. Reloading its current revision…')
    adoptSaved(await getEditorWorkflow(result.workflow))
    setMessage('Workflow saved.'); void refetch()
  })
  return <div class="page">
    <Show when={error()}><p class="field-error" role="alert">{error()}</p></Show>
    <Show when={(conflict() || reloadRequired()) && target()}><p>Your draft is still open. Reload to discard the draft and use the latest saved revision.</p>
      <button disabled={busy()} onClick={() => {
        if (!window.confirm('Discard this draft and reload the saved workflow?')) return
        void run(async () => {
          const fresh = await getEditorWorkflow(target()!)
          const definition = adoptSaved(fresh)
          setEditing({ definition, target: fresh, key: fresh.originId })
        })
      }}>Reload saved workflow</button>
    </Show>
    <Show when={message()}><p role="status">{message()}</p></Show>
    <Show when={editing()} keyed fallback={<section class="panel">
      <div class="section-title"><h2>Workflow studio</h2><button class="secondary" onClick={props.onClose}>Back to command deck</button></div>
      <p>Create a workflow or edit an existing mutable workflow on the graph.</p>
      <button onClick={() => { setTarget(undefined); setSavedDocument(undefined); setSavedDefinition(''); setReloadRequired(false); setEditing({ definition: newGraph(), key: crypto.randomUUID() }) }}>New workflow</button>
      <Show when={props.source}>{(source) => <div>
        <p>{source().name}: create an editable copy with all node and prompt files. The copy starts deactivated.</p>
        <button disabled={busy()} onClick={() => void run(async () => {
          const response = await rielaFetch(`/api/v1/workflows/sources/${encodeURIComponent(source().id)}/editable-copy`, {
            method: 'POST', credentials: 'same-origin', headers: { ...api.noteHeaders(), 'Content-Type': 'application/json' }, body: '{}',
          })
          const result = await response.json() as RegistryMutationPayload & { error?: { message: string } }
          if (!response.ok || !result.accepted || !result.workflow) throw new Error(result.error?.message ?? result.errors?.[0]?.message ?? 'Could not copy workflow.')
          const copied = await getEditorWorkflow(result.workflow)
          setEditing({ definition: adoptSaved(copied), key: copied.originId })
        })}>Edit a copy of {source().name}</button>
      </div>}</Show>
      <Show when={registry.loading}><p>Loading workflows…</p></Show>
      <Show when={registry.error}><p role="alert">{String(registry.error)}</p><button onClick={() => void refetch()}>Retry</button></Show>
      <For each={registry()}>{(workflow) => <button class="list-row selectable-row" disabled={busy()} onClick={() => void run(async () => {
        const target = await getEditorWorkflow(workflow)
        setEditing({ definition: adoptSaved(target), target, key: target.originId })
      })}><strong>{workflow.name}</strong><span>{workflow.workflowId} · Edit graph</span></button>}</For>
    </section>}>{(current) => <WorkflowGraphEditor initial={current.definition}
      target={target()} canonicalDefinition={savedDocument()} savedDefinition={savedDefinition()} onNodeSaved={(workflow) => {
        adoptSaved(workflow); setMessage('Node settings saved.'); void refetch()
      }} onActivate={() => void run(async () => {
        const current = target(); if (!current) return
        const result = await setMutableWorkflowActivation(current, true)
        if (result.workflow) {
          setTarget(result.workflow); setReloadRequired(true)
          adoptSaved(await getEditorWorkflow(result.workflow))
        }
      })}
      layoutStorageKey={layoutKey(props.profileKey, target()?.originId ?? current.key)} saving={busy()} blocked={reloadRequired()} onSave={save} onClose={() => setEditing(undefined)} />}</Show>
  </div>
}
