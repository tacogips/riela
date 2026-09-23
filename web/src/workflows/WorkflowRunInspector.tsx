import { rielaFetch } from '../transport'
import { For, Show, createEffect, createMemo, createSignal } from 'solid-js'
import { api } from '../api'
import { createPollingResource } from '../polling'

interface Attempt { executionId: string; stepId: string; nodeId: string; attempt: number; status: string; updatedAt: string }
interface RunEvidence { sessionId: string; workflowId: string; status: string; currentStepId: string | null; steps: Attempt[]; stepsTotalCount: number }
interface AttemptValues { input: unknown; output: unknown; inputRecorded: boolean; outputRecorded: boolean; responseText?: string; failureReason?: string }

async function evidence<T>(path: string, signal: AbortSignal): Promise<T> {
  const response = await rielaFetch(path, { signal, credentials: 'same-origin', headers: api.noteHeaders() })
  const result = await response.json()
  if (!response.ok) throw new Error(result.error?.message ?? 'Could not load run evidence.')
  return result as T
}

export function WorkflowRunInspector(props: {
  workflowId: string
  launchedSessionId?: string
  selectedStepId: string
  onSelectStep: (stepId: string) => void
  onStepStatuses: (statuses: Record<string, string>) => void
}) {
  const [input, setInput] = createSignal('')
  const [sessionId, setSessionId] = createSignal('')
  const [attemptId, setAttemptId] = createSignal('')
  createEffect(() => {
    if (props.launchedSessionId) { setInput(props.launchedSessionId); setSessionId(props.launchedSessionId); setAttemptId('') }
  })
  const run = createPollingResource(() => sessionId(), (signal) => evidence<RunEvidence>(
    `/api/v1/workflow-editor/runs/${encodeURIComponent(sessionId())}`, signal))
  const matchesGraph = createMemo(() => run.data()?.workflowId === props.workflowId)
  createEffect(() => {
    const record = run.data()
    props.onStepStatuses(Object.fromEntries((matchesGraph() ? record?.steps ?? [] : []).map((step) => [step.stepId, step.status])))
  })
  const attempts = createMemo(() => (run.data()?.steps ?? []).filter((step) => !matchesGraph() || !props.selectedStepId || step.stepId === props.selectedStepId))
  const selected = createMemo(() => attempts().find((step) => step.executionId === attemptId()) ?? attempts().at(-1))
  const values = createPollingResource(() => selected() ? `${sessionId()}/${selected()!.executionId}` : '',
    (signal) => evidence<AttemptValues>(`/api/v1/workflow-editor/runs/${encodeURIComponent(sessionId())}/steps/${encodeURIComponent(selected()!.executionId)}`, signal))
  return <section class="editor-chat" aria-label="Workflow run inspector">
    <h3>Run logs and values</h3>
    <p>Recorded values can contain sensitive workflow inputs and outputs. They are shown as stored.</p>
    <form onSubmit={(event) => { event.preventDefault(); setAttemptId(''); setSessionId(input().trim()) }}>
      <label>Run session ID<input value={input()} onInput={(event) => setInput(event.currentTarget.value)} /></label>
      <button disabled={!input().trim()}>Open run</button>
    </form>
    <Show when={run.error()}><p role="alert">{String(run.error())}</p></Show>
    <Show when={run.data()}>{(record) => <>
      <p role="status">{record().workflowId} · {record().status} · Current step: {record().currentStepId ?? 'none'}</p>
      <Show when={!matchesGraph()}><p role="status">This run belongs to another workflow. Graph highlighting and step filtering are disabled.</p></Show>
      <p>{record().steps.length} of {record().stepsTotalCount} recorded attempts.<Show when={matchesGraph()}> Select a graph step to filter.</Show></p>
      <div class="editor-attempts"><For each={record().steps}>{(step) => <button class="secondary" onClick={() => { if (matchesGraph()) props.onSelectStep(step.stepId); setAttemptId(step.executionId) }}>{step.stepId} · attempt {step.attempt} · {step.status}</button>}</For></div>
      <Show when={selected()}>{(step) => <div>
        <h4>{step().stepId} · {step().executionId}</h4>
        <Show when={values.error()}><p role="alert">{String(values.error())}</p></Show>
        <Show when={values.data()}>{(data) => <>
          <div class="editor-values"><section><h4>Input</h4><pre>{data().inputRecorded ? JSON.stringify(data().input, null, 2) : 'Input was not recorded for this attempt.'}</pre></section>
            <section><h4>Output</h4><pre>{data().outputRecorded ? JSON.stringify(data().output, null, 2) : 'No accepted output recorded yet.'}</pre></section></div>
          <Show when={data().failureReason}><p role="alert">{data().failureReason}</p></Show>
          <Show when={data().responseText}><h4>Agent response log</h4><pre>{data().responseText}</pre></Show>
        </>}</Show>
      </div>}</Show>
    </>}</Show>
  </section>
}
