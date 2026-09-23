import type { RunDetailStep } from '../contracts'

export function durationLabel(ms: number): string {
  if (ms < 1000) return `${Math.round(ms)} ms`
  if (ms < 60000) return `${(ms / 1000).toFixed(2)} s`
  return `${(ms / 60000).toFixed(2)} min`
}

export function traceLayout(steps: RunDetailStep[], now: number) {
  const rows = steps.map((step) => {
    const parsed = Date.parse(step.startedAt)
    const start = Number.isFinite(parsed) ? parsed : null
    const ended = step.endedAt ? Date.parse(step.endedAt) : NaN
    const running = ['running', 'pending', 'in_progress'].includes(step.status)
    const duration = step.durationMs !== null && Number.isFinite(step.durationMs)
      ? Math.max(0, step.durationMs)
      : start !== null && Number.isFinite(ended) ? Math.max(0, ended - start)
        : start !== null && running ? Math.max(0, now - start) : null
    return { step, start, duration, running }
  }).sort((a, b) => (a.start ?? Infinity) - (b.start ?? Infinity))
  const starts = rows.flatMap((row) => row.start === null ? [] : [row.start])
  const start = starts.length ? Math.min(...starts) : now
  const end = Math.max(start, ...rows.map((row) => (row.start ?? start) + (row.duration ?? 0)))
  return { rows, start, duration: end - start, scale: Math.max(1, end - start) }
}
