import { describe, expect, test } from 'bun:test'
import type { OpsWorkflowGraph, RunDetailLog, RunDetailResponse, RunDetailStep } from '../contracts'
import { buildRunGraph } from './runGraph'

const definition: OpsWorkflowGraph = {
  sourceId: 'source-review-loop',
  name: 'Review loop',
  workflowId: 'review-loop',
  scope: 'user',
  sourceKind: 'directory',
  description: 'Review then publish',
  entryStepId: 'review',
  managerStepId: null,
  steps: [
    {
      id: 'review',
      nodeId: 'reviewer',
      role: 'worker',
      description: null,
      transitions: [{ toStepId: 'publish', label: 'approved', fanoutJoinStepId: null }],
    },
    { id: 'publish', nodeId: 'publisher', role: 'worker', description: null, transitions: [] },
  ],
  nodes: [
    { id: 'review', kind: null, role: 'worker', addon: null },
    { id: 'publish', kind: 'output', role: 'worker', addon: 'riela/notebook-upsert' },
  ],
  stepsTruncated: false,
}

const execution = (stepId: string, status: string, startedAt: string, attempt = 1): RunDetailStep => ({
  executionId: `execution-${stepId}-${attempt}`,
  executionIdTruncated: false,
  stepId,
  stepIdTruncated: false,
  nodeId: `node-${stepId}`,
  nodeIdTruncated: false,
  attempt,
  status,
  backend: null,
  startedAt,
  endedAt: null,
  durationMs: null,
  failureReason: null,
  failureReasonTruncated: false,
  events: [],
  eventTotalCount: 0,
  eventsTruncated: false,
})

const routing = (fromStepId: string | null, toStepId: string | null): RunDetailLog => ({
  communicationId: `${fromStepId ?? 'session'}-${toStepId ?? 'session'}`,
  communicationIdTruncated: false,
  direction: 'outbound',
  fromStepId,
  fromStepIdTruncated: false,
  toStepId,
  toStepIdTruncated: false,
  sourceStepExecutionId: null,
  sourceStepExecutionIdTruncated: false,
  status: 'delivered',
  deliveryKind: null,
  createdOrder: 1,
  createdAt: null,
})

const detail = (
  steps: RunDetailStep[],
  logs: RunDetailLog[],
  currentStepId: string | null,
): RunDetailResponse => ({
  revision: 1,
  instanceId: 'instance-review',
  instanceIdTruncated: false,
  session: {
    sessionId: 'session-1',
    sessionIdTruncated: false,
    workflowId: 'review-loop',
    workflowIdTruncated: false,
    status: 'running',
    currentStepId,
    currentStepIdTruncated: false,
    updatedAt: '2026-08-19T10:00:00Z',
  },
  steps,
  stepsTotalCount: steps.length,
  stepsTruncated: false,
  logs,
  logsTotalCount: logs.length,
  logsTruncated: false,
  diagnostics: [],
  diagnosticsTotalCount: 0,
  diagnosticsTruncated: false,
  gates: [],
  gatesTotalCount: 0,
  gatesTruncated: false,
  recovery: null,
  truncated: false,
})

describe('run graph', () => {
  test('overlays execution status on the planned graph', () => {
    const graph = buildRunGraph(detail(
      [
        execution('review', 'completed', '2026-08-19T09:00:00Z'),
        execution('review', 'running', '2026-08-19T09:30:00Z', 2),
      ],
      [routing('review', 'publish')],
      'review',
    ), definition)
    const review = graph.steps.find((step) => step.stepId === 'review')!
    expect(review.status).toBe('running')
    expect(review.attempts).toBe(2)
    expect(review.isCurrent).toBe(true)
    expect(review.isEntry).toBe(true)
    expect(review.planned).toBe(true)
    const publish = graph.steps.find((step) => step.stepId === 'publish')!
    expect(publish.status).toBeNull()
    expect(publish.addon).toBe('riela/notebook-upsert')
    const edge = graph.edges.find((item) => item.fromStepId === 'review')!
    expect(edge.planned).toBe(true)
    expect(edge.traveled).toBe(true)
  })

  test('appends executed steps missing from the definition', () => {
    const graph = buildRunGraph(detail(
      [execution('hotfix', 'failed', '2026-08-19T09:00:00Z')],
      [routing('review', 'hotfix')],
      null,
    ), definition)
    const hotfix = graph.steps.find((step) => step.stepId === 'hotfix')!
    expect(hotfix.planned).toBe(false)
    expect(hotfix.status).toBe('failed')
    const edge = graph.edges.find((item) => item.toStepId === 'hotfix')!
    expect(edge.planned).toBe(false)
    expect(edge.traveled).toBe(true)
    expect(graph.layout.nodes.some((node) => node.id === 'hotfix')).toBe(true)
  })

  test('builds a graph purely from evidence when no definition exists', () => {
    const graph = buildRunGraph(detail(
      [
        execution('collect', 'completed', '2026-08-19T08:00:00Z'),
        execution('summarize', 'running', '2026-08-19T08:10:00Z'),
      ],
      [routing('collect', 'summarize'), routing(null, 'collect')],
      'summarize',
    ), undefined)
    expect(graph.entryStepId).toBe('collect')
    expect(graph.steps.map((step) => step.stepId).sort()).toEqual(['collect', 'summarize'])
    const tierOf = new Map(graph.layout.nodes.map((node) => [node.id, node.tier]))
    expect(tierOf.get('collect')).toBe(0)
    expect(tierOf.get('summarize')).toBe(1)
  })

  test('ignores session-level routing endpoints', () => {
    const graph = buildRunGraph(detail([], [routing(null, null)], null), undefined)
    expect(graph.steps).toHaveLength(0)
    expect(graph.edges).toHaveLength(0)
  })
})
