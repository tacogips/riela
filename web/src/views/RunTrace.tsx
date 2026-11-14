import { For, Show, createEffect, createMemo, createSignal, on, onCleanup } from 'solid-js'
import { api } from '../api'
import { rielaFetch } from '../transport'
import type { RunDetailResponse } from '../contracts'
import { createPollingResource } from '../polling'
import { durationLabel, traceLayout } from './traceLayout'
import { RunExecutionGraph } from './RunExecutionGraph'
import './run-trace.css'

interface Values { input: unknown; output: unknown; inputRecorded: boolean; outputRecorded: boolean; responseText?: string; failureReason?: string }

export function RunTrace(props: { run: RunDetailResponse; profileKey: string }) {
  const [mode, setMode] = createSignal<'trace' | 'graph'>('trace')
  const [selectedId, setSelectedId] = createSignal('')
  const [expanded, setExpanded] = createSignal<Set<string>>(new Set())
  const [open, setOpen] = createSignal(true)
  const [now, setNow] = createSignal(Date.now())
  const timer = setInterval(() => {
    if (props.run.steps.some((step) => step.status === 'running')) setNow(Date.now())
  }, 1000)
  onCleanup(() => clearInterval(timer))
  const contextKey = createMemo(() => `${props.profileKey}:${props.run.session.sessionId}`)
  createEffect(on(contextKey, () => {
    setSelectedId(''); setExpanded(new Set<string>()); setOpen(true)
  }))
  const trace = createMemo(() => traceLayout(props.run.steps, now()))
  const selected = createMemo(() => props.run.steps.find((step) => step.executionId === selectedId()))
  const values = createPollingResource(() => selected() ? `${props.profileKey}/${props.run.session.sessionId}/${selectedId()}` : undefined,
    async (signal): Promise<Values> => {
      const response = await rielaFetch(`/api/v1/workflow-editor/runs/${encodeURIComponent(props.run.session.sessionId)}/steps/${encodeURIComponent(selectedId())}`, { signal, credentials: 'same-origin', headers: api.noteHeaders() })
      const body = await response.json()
      if (!response.ok) throw new Error(body.error?.message ?? 'Could not load recorded values.')
      return body as Values
    })
  const toggle = (id: string) => setExpanded((previous) => {
    const next = new Set(previous)
    if (next.has(id)) next.delete(id); else next.add(id)
    return next
  })
  return <section class="panel run-trace" aria-label="Run visualization">
    <div class="section-title"><h2>Execution trace</h2><div class="trace-modes" aria-label="Run display">
      <button class="secondary" aria-pressed={mode() === 'trace'} onClick={() => setMode('trace')}>Trace timeline</button>
      <button class="secondary" aria-pressed={mode() === 'graph'} onClick={() => setMode('graph')}>Graph</button>
    </div></div>
    <p class="subtle">{props.run.steps.length} of {props.run.stepsTotalCount} attempts · {durationLabel(trace().duration)} elapsed · Select a row to inspect input and output.</p>
    <Show when={props.run.stepsTruncated || props.run.logsTruncated}><p class="truncation-notice">Partial trace: some executions or routing records are not included.</p></Show>
    <div class="trace-workspace" classList={{ 'has-selection': !!selected() }}>
      <div class="trace-content">
        <Show when={mode() === 'trace'} fallback={<RunExecutionGraph run={props.run} selectedId={selectedId()} onSelect={setSelectedId} />}>
          <div class="trace-scroll"><div class="trace-table">
            <div class="trace-axis"><strong>Step / Node</strong><div><For each={[0, 0.25, 0.5, 0.75, 1]}>{(fraction) => <span>{durationLabel(trace().duration * fraction)}</span>}</For></div></div>
            <button class="trace-root secondary" aria-expanded={open()} onClick={() => setOpen(!open())}>{open() ? '▾' : '▸'} {props.run.session.workflowId} · {durationLabel(trace().duration)}</button>
            <Show when={open()}><For each={trace().rows}>{(row) => <>
              <div class="trace-row" classList={{ selected: selectedId() === row.step.executionId }}>
                <button class="trace-expand secondary" aria-label={`Events for ${row.step.stepId} attempt ${row.step.attempt}`} aria-expanded={expanded().has(row.step.executionId)} onClick={() => toggle(row.step.executionId)}>{expanded().has(row.step.executionId) ? '▾' : '▸'}</button>
                <button class="trace-select" aria-label={`Inspect ${row.step.stepId} attempt ${row.step.attempt}`} aria-pressed={selectedId() === row.step.executionId} onClick={() => setSelectedId(row.step.executionId)}>
                  <span class="trace-name"><strong>{row.step.stepId}</strong><small>{row.step.nodeId} · attempt {row.step.attempt}</small></span>
                  <span class="trace-track"><Show when={row.start !== null && row.duration !== null}><span class={`trace-bar ${row.step.status}`} style={{ left: `${((row.start! - trace().start) / trace().scale) * 100}%`, width: `${(row.duration! / trace().scale) * 100}%` }} /></Show><span class="trace-duration">{row.duration === null ? 'Timing unavailable' : durationLabel(row.duration)} · {row.step.status}</span></span>
                </button>
              </div>
              <Show when={expanded().has(row.step.executionId)}><div class="trace-events"><Show when={!row.step.events.length}><p>No persisted backend events.</p></Show><For each={row.step.events}>{(event) => <p><time>{durationLabel(Math.max(0, Date.parse(event.at) - (row.start ?? trace().start)))}</time> {event.eventType} · {event.toolName ?? event.channel ?? 'event'}</p>}</For><Show when={row.step.eventsTruncated}><p>Showing {row.step.events.length} of {row.step.eventTotalCount} events.</p></Show></div></Show>
            </>}</For></Show>
          </div></div>
        </Show>
      </div>
      <Show when={selected()}>{(step) => <aside class="trace-inspector" aria-label="Execution input and output">
        <button class="secondary" onClick={() => setSelectedId('')}>Close details</button>
        <h3>{step().stepId} · attempt {step().attempt}</h3><p>{step().executionId}</p><p>{step().status} · {step().backend ?? 'default'}</p>
        <p>Started {new Date(step().startedAt).toLocaleString()}</p>
        <Show when={step().failureReason}><p role="alert">{step().failureReason}</p></Show>
        <Show when={values.loading() && !values.data()}><p role="status">Loading recorded values…</p></Show>
        <Show when={values.error()}><p role="alert">{String(values.error())}</p><button class="secondary" onClick={() => void values.refresh()}>Retry values</button></Show>
        <Show when={values.data()}>{(data) => <><h4>Input</h4><pre>{data().inputRecorded ? JSON.stringify(data().input, null, 2) : 'Input was not recorded for this attempt.'}</pre><h4>Output</h4><pre>{data().outputRecorded ? JSON.stringify(data().output, null, 2) : 'No accepted output recorded yet.'}</pre><Show when={data().responseText}><h4>Agent response log</h4><pre>{data().responseText}</pre></Show></>}</Show>
      </aside>}</Show>
    </div>
  </section>
}
