import { For, createMemo } from 'solid-js'
import type { RunDetailResponse } from '../contracts'

// Routes identify steps, not destination attempts. Keep that distinction visible.
export function RunExecutionGraph(props: { run: RunDetailResponse; selectedId: string; onSelect: (id: string) => void }) {
  const ids = createMemo(() => [...new Set([
    ...props.run.steps.map((step) => step.stepId),
    ...props.run.logs.flatMap((log) => [log.fromStepId, log.toStepId].filter((id): id is string => !!id)),
  ])])
  const routes = createMemo(() => [...new Map(props.run.logs.filter((log) => log.fromStepId && log.toStepId)
    .map((log) => [JSON.stringify([log.fromStepId, log.toStepId]), log])).values()])
  const point = (id: string) => {
    const index = Math.max(0, ids().indexOf(id))
    return { x: 30 + (index % 3) * 270, y: 30 + Math.floor(index / 3) * 150 }
  }
  return <div class="trace-scroll" aria-label="Execution graph">
    <p class="subtle">Persisted step routes. Select an attempt below a node to inspect its recorded values.</p>
    <svg class="run-route-graph" viewBox={`0 0 850 ${Math.max(180, Math.ceil(ids().length / 3) * 150 + 40)}`} role="img" aria-label="Workflow step routing graph">
      <defs><marker id="run-route-arrow" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0 0L8 4L0 8" fill="#65bcd2" /></marker></defs>
      <For each={routes()}>{(route) => {
        const from = () => point(route.fromStepId!)
        const to = () => point(route.toStepId!)
        return <path d={route.fromStepId === route.toStepId
          ? `M${from().x + 160} ${from().y} c80 -30 -80 -30 -50 0`
          : `M${from().x + 110} ${from().y + 70} C${from().x + 110} ${from().y + 115},${to().x + 110} ${to().y - 30},${to().x + 110} ${to().y}`} fill="none" stroke="#65bcd2" stroke-width="1.5" marker-end="url(#run-route-arrow)"><title>{route.fromStepId} → {route.toStepId}</title></path>
      }}</For>
      <For each={ids()}>{(id) => <g transform={`translate(${point(id).x},${point(id).y})`}><rect width="220" height="70" rx="8" fill="#142938" stroke="#45667d" /><text x="12" y="27" fill="#dfebf3">{id.length > 26 ? `${id.slice(0, 25)}…` : id}</text><text x="12" y="50" fill="#9eb3c3" font-size="11">{props.run.steps.filter((step) => step.stepId === id).length} recorded attempts</text><title>{id}</title></g>}</For>
    </svg>
    <div class="trace-graph"><For each={ids()}>{(id) => <div class="trace-graph-entry"><strong>{id}</strong><For each={props.run.steps.filter((step) => step.stepId === id)}>{(step) => <button class="secondary" aria-label={`Inspect ${step.stepId} attempt ${step.attempt}`} aria-pressed={props.selectedId === step.executionId} onClick={() => props.onSelect(step.executionId)}>Attempt {step.attempt} · {step.status}</button>}</For></div>}</For></div>
  </div>
}
