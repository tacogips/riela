import { expect, test } from 'bun:test'
import type { RunDetailStep } from '../contracts'
import { traceLayout } from './traceLayout'

const step = (id: string, start: number, duration: number | null, status = 'completed') => ({
  executionId: id, stepId: 'worker', attempt: 1, startedAt: new Date(start).toISOString(),
  durationMs: duration, endedAt: null, status,
}) as RunDetailStep

test('preserves retries and overlap on one common clock', () => {
  const result = traceLayout([step('retry', 4000, 500), step('first', 1000, 2000), step('parallel', 1500, 1000)], 10000)
  expect(result.rows.map((row) => row.step.executionId)).toEqual(['first', 'parallel', 'retry'])
  expect(result.start).toBe(1000)
  expect(result.duration).toBe(3500)
})

test('only running attempts accrue elapsed time; missing terminal timing stays unknown', () => {
  const result = traceLayout([step('live', 1000, null, 'running'), step('failed', 1000, null, 'failed')], 4000)
  expect(result.rows.map((row) => row.duration)).toEqual([3000, null])
  expect(traceLayout([step('zero', 1000, 0)], 4000).scale).toBe(1)
})

test('invalid timestamp does not poison the shared scale', () => {
  const invalid = { ...step('invalid', 0, null), startedAt: 'invalid' }
  const result = traceLayout([invalid, step('valid', 1000, 100)], 4000)
  expect(result.duration).toBe(100)
  expect(result.rows[1]?.start).toBeNull()
})

test('equal timestamps retain persisted execution order across different attempt numbers', () => {
  const prior = { ...step('z-prior', 1000, 0), attempt: 2 }
  const next = step('a-next', 1000, 0)
  expect(traceLayout([prior, next], 4000).rows.map((row) => row.step.executionId)).toEqual(['z-prior', 'a-next'])
})
