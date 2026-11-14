import { rielaFetch } from '../transport'
import { Show, createEffect, createSignal } from 'solid-js'
import { api } from '../api'
import { createPollingResource } from '../polling'
import type { RegistryWorkflow } from './types'
import { validateJSONObject } from './validation'

interface Launch { id: string; status: string; sessionId: string | null; error: string | null }

export function WorkflowRunControls(props: {
  target?: RegistryWorkflow
  disabled: boolean
  onSession: (id: string) => void
  onActivate: () => void
}) {
  const [directory, setDirectory] = createSignal('')
  const [variables, setVariables] = createSignal('{}')
  const [jobId, setJobId] = createSignal('')
  const [submitting, setSubmitting] = createSignal(false)
  const [error, setError] = createSignal('')
  const [terminal, setTerminal] = createSignal(false)
  const [lastStatus, setLastStatus] = createSignal('')
  const job = createPollingResource(() => terminal() ? '' : jobId(), async (signal) => {
    const response = await rielaFetch(`/api/v1/workflow-editor/launches/${jobId()}`, { signal, headers: api.noteHeaders(), credentials: 'same-origin' })
    const value = await response.json()
    if (!response.ok) throw new Error(value.error?.message ?? 'Could not observe the workflow launch.')
    return value as Launch
  }, 800)
  createEffect(() => {
    const current = job.data()
    if (!current) return
    if (current.sessionId) props.onSession(current.sessionId)
    setLastStatus(current.status)
    if (current.error) setError(current.error)
    if (current.status !== 'running') setTerminal(true)
  })
  const start = async () => {
    const target = props.target
    const parsed = validateJSONObject(variables())
    if (!target || !parsed.value || props.disabled || submitting()) return
    setSubmitting(true); setError('')
    try {
      const response = await rielaFetch('/api/v1/workflow-editor/launches', { method: 'POST', credentials: 'same-origin',
        headers: { ...api.noteHeaders(), 'Content-Type': 'application/json' },
        body: JSON.stringify({ workflowId: target.workflowId, originId: target.originId,
          definitionRevision: target.definitionRevision, workingDirectory: directory(), variables: parsed.value }) })
      const result = await response.json()
      if (!response.ok) throw new Error(result.error?.message ?? 'Could not start workflow.')
      setLastStatus(result.status); setTerminal(false); setJobId(result.id)
      if (result.sessionId) props.onSession(result.sessionId)
    } catch (failure) { setError(failure instanceof Error ? failure.message : String(failure)) }
    finally { setSubmitting(false) }
  }
  return <section class="editor-chat" aria-label="Run workflow">
    <h3>Run saved workflow</h3>
    <Show when={!props.target || props.disabled}><p>Save the current graph before running.</p></Show>
    <Show when={props.target?.activationState === 'DEACTIVATED'}><p>This workflow is deactivated.</p><button onClick={props.onActivate} disabled={props.disabled}>Activate workflow</button></Show>
    <form onSubmit={(event) => { event.preventDefault(); void start() }}>
      <label>Execution working directory<input placeholder="/absolute/path/to/project" value={directory()} onInput={(event) => setDirectory(event.currentTarget.value)} /></label>
      <label>Execution input JSON<textarea rows="4" value={variables()} onInput={(event) => setVariables(event.currentTarget.value)} /></label>
      <Show when={validateJSONObject(variables()).error}><p role="alert">{validateJSONObject(variables()).error}</p></Show>
      <button disabled={props.disabled || !props.target || props.target.activationState !== 'ACTIVE' || !directory().startsWith('/')
        || Boolean(validateJSONObject(variables()).error) || submitting() || Boolean(jobId() && !terminal())}>Run workflow</button>
    </form>
    <Show when={lastStatus()}><p role="status">Execution: {lastStatus()}</p></Show>
    <Show when={error() || job.error()}><p role="alert">{error() || String(job.error())}</p></Show>
  </section>
}
