import { For, Show, createEffect, createMemo, createResource, createSignal, on } from 'solid-js'
import { APIError, api, requireExpectedProfile } from '../api'
import type { WorkflowDefinitionResponse, WorkflowSources } from '../contracts'
import { EmptyState, ErrorBanner, LoadingState, MutationMessage, PageHeader } from '../components/Primitives'
import {
  deleteMutableWorkflow,
  getMutableWorkflow,
  listMutableWorkflows,
  registerMutableWorkflow,
  setMutableWorkflowActivation,
  updateMutableWorkflow,
} from '../workflows/client'
import type { RegistryWorkflow } from '../workflows/types'
import { validateJSONObject } from '../workflows/validation'

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export function mutableDetailMatchesSelection(
  selected: RegistryWorkflow | undefined,
  detail: RegistryWorkflow | undefined,
): boolean {
  return Boolean(
    selected
      && detail
      && selected.workflowId === detail.workflowId
      && selected.originId === detail.originId,
  )
}

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

export function sourcePathForProfileTransition(
  previousProfileKey: string | undefined,
  nextProfileKey: string,
  currentPath: string,
): string {
  return previousProfileKey !== undefined && previousProfileKey !== nextProfileKey
    ? ''
    : currentPath
}

export function WorkflowsView(props: { profileKey: string; profileName: string }) {
  const [sources, { refetch: refetchSources }] = createResource(
    () => props.profileKey,
    async () => requireExpectedProfile(
      await api.get<WorkflowSources>('/api/v1/workflows/sources'),
      props.profileName,
    ),
  )
  const [selectedSourceId, setSelectedSourceId] = createSignal('')
  const [definition, { refetch: refetchDefinition }] = createResource(
    () => selectedSourceId()
      ? { profileKey: props.profileKey, sourceId: selectedSourceId() }
      : undefined,
    async ({ profileKey, sourceId }): Promise<DiscoveredDefinitionResource> => ({
      profileKey,
      sourceId,
      detail: await api.get<WorkflowDefinitionResponse>(
        `/api/v1/workflows/sources/${encodeURIComponent(sourceId)}/definition`,
      ),
    }),
  )
  const [registry, { refetch: refetchRegistry }] = createResource(
    () => props.profileKey,
    listMutableWorkflows,
  )
  const [selectedMutable, setSelectedMutable] = createSignal<RegistryWorkflow>()
  const [mutableDetail, { refetch: refetchMutableDetail }] = createResource(
    () => {
      const workflow = selectedMutable()
      return workflow ? { profileKey: props.profileKey, workflow } : undefined
    },
    ({ workflow }) => getMutableWorkflow(workflow),
  )
  const [path, setPath] = createSignal('')
  const [message, setMessage] = createSignal('')
  const [mutationError, setMutationError] = createSignal(false)
  const [conflictTarget, setConflictTarget] = createSignal<'registry' | 'sources'>()
  const [saving, setSaving] = createSignal(false)
  const [registering, setRegistering] = createSignal(false)
  const [editor, setEditor] = createSignal('')
  const editorValidation = createMemo(() => validateJSONObject(editor()))
  const currentDefinition = createMemo(() => {
    if (definition.loading || definition.error) return undefined
    const resource = definition()
    return discoveredDefinitionMatchesSelection(
      props.profileKey,
      selectedSourceId(),
      resource,
    ) ? resource?.detail : undefined
  })
  const currentMutableDetail = createMemo(() => {
    if (mutableDetail.loading || mutableDetail.error) return undefined
    const detail = mutableDetail()
    return mutableDetailMatchesSelection(selectedMutable(), detail) ? detail : undefined
  })

  let previousProfileKey: string | undefined
  createEffect(on(() => props.profileKey, (nextProfileKey) => {
    setSelectedSourceId('')
    setSelectedMutable(undefined)
    setRegistering(false)
    setEditor('')
    setPath((current) => sourcePathForProfileTransition(previousProfileKey, nextProfileKey, current))
    setMessage('')
    setMutationError(false)
    setConflictTarget(undefined)
    previousProfileKey = nextProfileKey
  }))

  const refreshRegistry = async (clearEditor = false) => {
    await refetchRegistry()
    if (selectedMutable()) await refetchMutableDetail()
    if (clearEditor) {
      setRegistering(false)
      setEditor('')
    }
  }

  const reportRegistryMutation = async (operation: () => Promise<unknown>, success: string) => {
    setMessage(''); setMutationError(false); setConflictTarget(undefined); setSaving(true)
    try {
      await operation()
      setMessage(success)
      setRegistering(false)
      setEditor('')
      await refreshRegistry()
    } catch (error) {
      const isConflict = error instanceof APIError && (error.status === 409 || error.code === 'REGISTRY_CONFLICT')
      setConflictTarget(isConflict ? 'registry' : undefined)
      setMutationError(true)
      setMessage(isConflict ? 'Changed elsewhere — refresh the registry before trying again.' : errorMessage(error))
    } finally {
      setSaving(false)
    }
  }

  const add = async () => {
    setMessage(''); setMutationError(false); setConflictTarget(undefined); setSaving(true)
    try {
      requireExpectedProfile(
        await api.mutate<WorkflowSources>('/api/v1/workflows/sources/directories', 'POST', {
          path: path(),
          expectedProfile: props.profileName,
        }),
        props.profileName,
      )
      setPath('')
      setMessage('Workflow directory added.')
      await refetchSources()
    } catch (error) {
      const isConflict = error instanceof APIError && error.status === 409
      setConflictTarget(isConflict ? 'sources' : undefined)
      setMutationError(true)
      setMessage(isConflict ? 'Changed elsewhere — refresh before adding this directory.' : errorMessage(error))
    } finally {
      setSaving(false)
    }
  }

  const beginEdit = () => {
    const selected = currentMutableDetail()
    if (!selected?.definition) return
    setRegistering(false)
    setEditor(JSON.stringify(selected.definition, null, 2))
  }

  const beginRegistration = () => {
    setSelectedMutable(undefined)
    setRegistering(true)
    setEditor('{\n  "workflowId": "",\n  "defaults": {},\n  "nodes": [],\n  "steps": []\n}')
  }

  const saveDefinition = async () => {
    const value = editorValidation().value
    if (!value) return
    if (registering()) {
      await reportRegistryMutation(() => registerMutableWorkflow(value), 'Mutable workflow registered.')
    } else if (currentMutableDetail()) {
      await reportRegistryMutation(() => updateMutableWorkflow(currentMutableDetail()!, value), 'Mutable workflow updated.')
    }
  }

  const selectMutable = (workflow: RegistryWorkflow) => {
    setRegistering(false)
    setEditor('')
    setSelectedMutable(workflow)
  }

  const configuredCount = () => (sources()?.directories.length ?? 0) + (sources()?.projectDirectories.length ?? 0) + (sources()?.repositories.length ?? 0)

  return <section class="page"><PageHeader eyebrow="DISCOVERY" title="Workflows" description="Inspect discovered definitions and manage user-scoped mutable workflows." actions={<button class="secondary" onClick={() => { void refetchSources(); void refreshRegistry() }}>Refresh</button>} />
    <div class="surface-notice"><strong>Package actions live elsewhere</strong><span>Import, update, and remove packages in the native app’s Install Workflow pane or with the Riela CLI.</span></div>
    <Show when={sources.loading}><LoadingState label="Loading workflow sources…" /></Show>
    <Show when={sources.error}><ErrorBanner message={errorMessage(sources.error)} /></Show>
    <Show when={message()}><MutationMessage
      message={message()}
      isError={mutationError()}
      onRefresh={conflictTarget() === 'registry'
        ? () => void refreshRegistry(true)
        : conflictTarget() === 'sources'
          ? () => void refetchSources()
          : undefined}
    /></Show>
    <div class="add-source"><label class="grow" for="workflow-directory"><span>Additional workflow directory</span><input id="workflow-directory" placeholder="/absolute/path/to/workflows" value={path()} onInput={(event) => setPath(event.currentTarget.value)} /></label><button disabled={!path().trim() || saving()} onClick={() => void add()}>{saving() ? 'Adding…' : 'Add directory'}</button></div>
    <Show when={!sources.loading && !sources.error}><div class="two-column"><div class="panel"><div class="section-title"><h2>Configured sources</h2><span>{configuredCount()}</span></div><Show when={configuredCount() === 0}><EmptyState title="No sources configured" detail="Add a directory or use the native app to install a package." /></Show><For each={[...(sources()?.directories ?? []), ...(sources()?.projectDirectories ?? [])]}>{(item) => <div class="list-row"><span class="row-icon">D</span><div><strong>{item.split('/').at(-1)}</strong><span>{item} · directory</span></div></div>}</For><For each={sources()?.repositories}>{(item) => <div class="list-row"><span class="row-icon">G</span><div><strong>{item.id}</strong><span>{item.source} · repository</span></div></div>}</For></div>
      <div class="panel"><div class="section-title"><h2>Discovered workflows</h2><span>{sources()?.discovered.length ?? 0}</span></div><Show when={sources()?.discovered.length === 0}><EmptyState title="Nothing discovered" detail="Add a source directory to discover workflows." /></Show><For each={sources()?.discovered}>{(item) => <button class="list-row selectable-row" aria-label={`Inspect workflow ${item.name}`} aria-pressed={selectedSourceId() === item.id} onClick={() => setSelectedSourceId(item.id)}><span class="row-icon">W</span><div><strong>{item.name}</strong><span>{item.workflowId} · {item.scope} · {item.sourceKind}</span></div></button>}</For></div></div></Show>
    <Show when={selectedSourceId()}><div class="panel definition-inspector"><div class="section-title"><h2>Discovered definition</h2><button class="secondary" onClick={() => void refetchDefinition()}>Refresh definition</button></div><Show when={definition.loading}><LoadingState label="Loading workflow definition…" /></Show><Show when={!definition.loading && definition.error}><ErrorBanner message={errorMessage(definition.error)} /></Show><Show when={currentDefinition()}>{(item) => <><div class="definition-meta"><strong>{item().name}</strong><span>{item().workflowId} · {item().definitionRevision}</span><span>Entry: {item().definition.entryStepId}</span></div><div class="definition-grid"><section><h3>Steps</h3><Show when={item().definition.steps.length === 0}><p>No steps.</p></Show><For each={item().definition.steps}>{(step) => <div class="definition-row"><strong>{step.id}</strong><span>{step.nodeId}{step.role ? ` · ${step.role}` : ''}</span><span>{step.transitions.map((transition) => transition.toStepId).join(', ') || 'terminal'}</span></div>}</For></section><section><h3>Nodes</h3><Show when={item().definition.nodes.length === 0}><p>No nodes.</p></Show><For each={item().definition.nodes}>{(node) => <div class="definition-row"><strong>{node.id}</strong><span>{node.kind ?? 'agent'}{node.role ? ` · ${node.role}` : ''}</span></div>}</For></section></div><Show when={item().diagnostics.length > 0 || item().diagnosticsTruncated}><div class="diagnostics"><h3>Validation diagnostics</h3><For each={item().diagnostics}>{(diagnostic) => <><p>{diagnostic.summary}</p><Show when={diagnostic.truncated}><p class="truncation-notice">Diagnostic was truncated.</p></Show></>}</For><Show when={item().diagnosticsTruncated}><p class="truncation-notice">Showing {item().diagnostics.length} of {item().diagnosticsTotalCount} diagnostics.</p></Show></div></Show><Show when={item().truncated}><p class="truncation-notice">Definition display was truncated.</p></Show></>}</Show></div></Show>
    <div class="panel registry-panel"><div class="section-title"><div><span class="eyebrow">USER REGISTRY</span><h2>Mutable workflows</h2></div><button onClick={beginRegistration}>Register pasted JSON</button></div>
      <Show when={registry.loading}><LoadingState label="Loading mutable workflows…" /></Show><Show when={registry.error}><ErrorBanner message={errorMessage(registry.error)} /></Show><Show when={!registry.loading && !registry.error && registry()?.length === 0}><EmptyState title="No mutable workflows" detail="Register a workflow from a pasted JSON definition." /></Show>
      <div class="registry-layout"><div><Show when={!registry.error}><For each={registry()}>{(workflow) => <button class="list-row selectable-row" aria-label={`Select mutable workflow ${workflow.name}`} aria-pressed={selectedMutable()?.originId === workflow.originId} onClick={() => selectMutable(workflow)}><span class="row-icon">M</span><div><strong>{workflow.name}</strong><span>{workflow.workflowId} · {workflow.activationState.toLowerCase()}</span></div></button>}</For></Show></div>
        <div><Show when={mutableDetail.loading}><LoadingState label="Loading mutable definition…" /></Show><Show when={mutableDetail.error}><ErrorBanner message={errorMessage(mutableDetail.error)} /></Show><Show when={currentMutableDetail()}>{(workflow) => <div class="registry-actions"><div><strong>{workflow().name}</strong><span>{workflow().originId}</span></div><button class="secondary" disabled={!workflow().definitionRevision} onClick={beginEdit}>Edit JSON</button><button class="secondary" disabled={!workflow().definitionRevision || saving()} onClick={() => void reportRegistryMutation(() => setMutableWorkflowActivation(workflow(), workflow().activationState !== 'ACTIVE'), workflow().activationState === 'ACTIVE' ? 'Workflow deactivated.' : 'Workflow activated.')}>{workflow().activationState === 'ACTIVE' ? 'Deactivate' : 'Activate'}</button><button class="danger" disabled={!workflow().definitionRevision || saving()} onClick={() => { if (window.confirm(`Delete ${workflow().name} (${workflow().definitionRevision})?`)) void reportRegistryMutation(async () => { await deleteMutableWorkflow(workflow()); setSelectedMutable(undefined); setEditor('') }, 'Workflow deleted.') }}>Delete</button></div>}</Show></div></div>
      <Show when={registering() || editor()}><div class="registry-editor"><label><span>{registering() ? 'New workflow definition' : 'Mutable workflow definition'}</span><textarea rows="18" aria-invalid={Boolean(editorValidation().error)} aria-describedby="registry-json-error" value={editor()} onInput={(event) => setEditor(event.currentTarget.value)} /></label><Show when={editorValidation().error}><p id="registry-json-error" class="field-error" role="alert">{editorValidation().error}</p></Show><div class="save-row"><button class="secondary" onClick={() => { setRegistering(false); setEditor('') }}>Cancel</button><button disabled={saving() || Boolean(editorValidation().error)} onClick={() => void saveDefinition()}>{saving() ? 'Saving…' : registering() ? 'Register workflow' : 'Save workflow'}</button></div></div></Show>
    </div>
  </section>
}
