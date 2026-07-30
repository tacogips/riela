import { describe, expect, test } from 'bun:test'
import type { RunDetailLog, RunDetailStep } from '../contracts'
import {
  logsForStepExecution,
  routingLogsWithoutVisibleExecution,
} from './RunDetailView'

function step(executionId: string, attempt: number): RunDetailStep {
  return {
    executionId,
    executionIdTruncated: false,
    stepId: 'review',
    stepIdTruncated: false,
    nodeId: 'reviewer',
    nodeIdTruncated: false,
    attempt,
    status: 'completed',
    backend: 'codex',
    startedAt: '2026-07-30T00:00:00Z',
    endedAt: '2026-07-30T00:00:01Z',
    durationMs: 1_000,
    failureReason: null,
    failureReasonTruncated: false,
    events: [],
    eventTotalCount: 0,
    eventsTruncated: false,
  }
}

function log(
  communicationId: string,
  sourceStepExecutionId: string | null,
): RunDetailLog {
  return {
    communicationId,
    communicationIdTruncated: false,
    direction: 'outbox',
    fromStepId: 'review',
    fromStepIdTruncated: false,
    toStepId: 'complete',
    toStepIdTruncated: false,
    sourceStepExecutionId,
    sourceStepExecutionIdTruncated: false,
    status: 'delivered',
    deliveryKind: 'direct',
    createdOrder: 1,
    createdAt: '2026-07-30T00:00:01Z',
  }
}

describe('run detail routing attribution', () => {
  test('does not duplicate routing records across retries of the same step', () => {
    const first = step('execution-review-1', 1)
    const second = step('execution-review-2', 2)
    const logs = [
      log('comm-first', first.executionId),
      log('comm-second', second.executionId),
      log('comm-unattributed', null),
      log('comm-hidden', 'execution-review-3'),
    ]

    expect(logsForStepExecution(logs, first).map((item) => item.communicationId))
      .toEqual(['comm-first'])
    expect(logsForStepExecution(logs, second).map((item) => item.communicationId))
      .toEqual(['comm-second'])
    expect(routingLogsWithoutVisibleExecution(logs, [first, second])
      .map((item) => item.communicationId))
      .toEqual(['comm-unattributed', 'comm-hidden'])
  })
})
