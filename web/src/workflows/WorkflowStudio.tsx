import { ActionButton } from '../components/ActionButton'
import { rielaFetch } from '../transport'
import { Show, createSignal, onMount } from 'solid-js'
import { getEditorWorkflow, registerMutableWorkflow, updateMutableWorkflow, setMutableWorkflowActivation } from './client'
import { graphDocument, newGraph, type GraphDocument } from './graph'
import { WorkflowGraphEditor } from './WorkflowGraphEditor'
import { layoutKey } from './layout'
import type { RegistryWorkflow } from './types'
import type { RegistryMutationPayload } from './types'
import { APIError, api } from '../api'

/** Copies an imported (read-only) workflow into the app registry so it can be edited and run. */
async function createEditableCopy(sourceId: string): Promise<RegistryWorkflow> {
  const response = await rielaFetch(`/api/v1/workflows/sources/${encodeURIComponent(sourceId)}/editable-copy`, {
    method: 'POST', credentials: 'same-origin', headers: { ...api.noteHeaders(), 'Content-Type': 'application/json' }, body: '{}',
  })
  const result = await response.json() as RegistryMutationPayload & { error?: { message: string } }
  if (!response.ok || !result.accepted || !result.workflow) throw new Error(result.error?.message ?? result.errors?.[0]?.message ?? 'Could not copy workflow.')
  return getEditorWorkflow(result.workflow)
}

/**
 * Hosts the graph editor for a new workflow, an existing mutable workflow, or an
 * editable copy of an imported workflow. Every mode edits on the graph; closing
 * always returns to the caller.
 */
export function WorkflowStudio(props: { profileKey: string; copySource?: { id: string; name: string }; initialWorkflow?: RegistryWorkflow; onClose: () => void }) {
  const [editing, setEditing] = createSignal<{ definition: GraphDocument; key: string } | undefined>(
    props.initialWorkflow ? { definition: graphDocument(props.initialWorkflow.definition), key: props.initialWorkflow.originId }
      : props.copySource ? undefined : { definition: newGraph(), key: crypto.randomUUID() },
  )
  const [busy, setBusy] = createSignal(false)
  const [target, setTarget] = createSignal<RegistryWorkflow | undefined>(props.initialWorkflow)
  const [savedDefinition, setSavedDefinition] = createSignal(props.initialWorkflow ? JSON.stringify(graphDocument(props.initialWorkflow.definition)) : '')
  const [savedDocument, setSavedDocument] = createSignal<GraphDocument | undefined>(props.initialWorkflow ? graphDocument(props.initialWorkflow.definition) : undefined)
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
  onMount(() => {
    const source = props.copySource
    if (!source) return
    setMessage(`Creating an editable copy of ${source.name}…`)
    void run(async () => {
      const copied = await createEditableCopy(source.id)
      setEditing({ definition: adoptSaved(copied), key: copied.originId })
      setMessage(`Editing a copy of ${source.name}.`)
    })
  })
  const save = (definition: GraphDocument) => void run(async () => {
    const current = editing()!
    const registering = !target()
    const result = target()
      ? await updateMutableWorkflow(target()!, definition)
      : await registerMutableWorkflow(definition)
    if (!result.workflow) throw new Error('Save was accepted without a workflow identity. Reopen the workflow to inspect the registry.')
    setTarget(result.workflow)
    setReloadRequired(true)
    const oldKey = layoutKey(props.profileKey, current.key)
    const newKey = layoutKey(props.profileKey, result.workflow.originId)
    if (registering) {
      try { const layout = localStorage.getItem(oldKey); if (layout) localStorage.setItem(newKey, layout) } catch { /* Editor reports storage failures. */ }
    }
    setMessage('Workflow saved. Reloading its current revision…')
    adoptSaved(await getEditorWorkflow(result.workflow))
    setMessage('Workflow saved.')
  })
  return <div class="page">
    <Show when={error()}><p class="field-error" role="alert">{error()}</p></Show>
    <Show when={(conflict() || reloadRequired()) && target()}><p>Draft kept.</p>
      <ActionButton disabled={busy()} onClick={() => {
        if (!window.confirm('Discard this draft and reload the saved workflow?')) return
        void run(async () => {
          const fresh = await getEditorWorkflow(target()!)
          setEditing({ definition: adoptSaved(fresh), key: fresh.originId })
        })
      }}>Reload saved workflow</ActionButton>
    </Show>
    <Show when={message()}><p role="status">{message()}</p></Show>
    <Show when={editing()} keyed fallback={<Show when={!busy()}><ActionButton class="secondary" onClick={props.onClose}>Back to workflows</ActionButton></Show>}>{(current) => <WorkflowGraphEditor initial={current.definition}
      target={target()} canonicalDefinition={savedDocument()} savedDefinition={savedDefinition()} onNodeSaved={(workflow) => {
        adoptSaved(workflow); setMessage('Node settings saved.')
      }} onActivate={() => void run(async () => {
        const current = target(); if (!current) return
        const result = await setMutableWorkflowActivation(current, true)
        if (result.workflow) {
          setTarget(result.workflow); setReloadRequired(true)
          adoptSaved(await getEditorWorkflow(result.workflow))
        }
      })}
      layoutStorageKey={layoutKey(props.profileKey, target()?.originId ?? current.key)} saving={busy()} blocked={reloadRequired()} onSave={save} onClose={props.onClose} />}</Show>
  </div>
}
