import { describe, expect, test } from 'bun:test'
import type { OpsOverviewResponse, OpsRunSummary, OpsWorkflowGraph } from '../contracts'
import { applyLens, buildWorkflowHubs, carouselIndex, DEFAULT_LENS, searchHubs } from './overview'

const graph = (workflowId: string, scope = 'user'): OpsWorkflowGraph => ({
  sourceId: `source-${workflowId}`,
  name: workflowId,
  workflowId,
  scope,
  sourceKind: 'directory',
  description: '',
  entryStepId: 'entry',
  managerStepId: null,
  steps: [{ id: 'entry', nodeId: 'entry', role: null, description: null, transitions: [] }],
  nodes: [{ id: 'entry', kind: null, role: null, addon: null }],
  stepsTruncated: false,
})

const run = (
  instanceId: string,
  workflowId: string,
  status: string,
  updatedAt: string,
): OpsRunSummary => ({
  instanceId,
  sessionId: `session-${updatedAt}`,
  workflowId,
  status,
  currentStepId: null,
  activeStepIds: [],
  updatedAt,
})

const overview = (): OpsOverviewResponse => ({
  profile: 'default',
  revision: 1,
  workflows: [graph('review-loop'), graph('kanban', 'project')],
  workflowsTruncated: false,
  instances: [
    { id: 'instance-review', name: 'Review', workflowId: 'review-loop', status: 'running', active: true },
    { id: 'instance-kanban', name: 'Kanban', workflowId: 'kanban', status: 'stopped', active: false },
  ],
  runs: [
    run('instance-review', 'review-loop', 'running', '2026-08-19T10:00:00Z'),
    run('instance-review', 'review-loop', 'failed', '2026-08-19T09:00:00Z'),
    run('instance-kanban', 'kanban', 'completed', '2026-08-19T08:00:00Z'),
    run('instance-review', 'other-workflow', 'running', '2026-08-19T07:00:00Z'),
  ],
  runsTruncated: false,
  diagnostics: [],
})

describe('workflow hubs', () => {
  test('joins instances and runs onto their workflow', () => {
    const hubs = buildWorkflowHubs(overview())
    const review = hubs.find((hub) => hub.workflow.workflowId === 'review-loop')!
    expect(review.instances.map((instance) => instance.id)).toEqual(['instance-review'])
    expect(review.runs).toHaveLength(2)
    expect(review.liveRunCount).toBe(1)
    expect(review.failedRunCount).toBe(1)
    expect(review.latestRun?.status).toBe('running')
    const kanban = hubs.find((hub) => hub.workflow.workflowId === 'kanban')!
    expect(kanban.runs).toHaveLength(1)
    expect(kanban.liveRunCount).toBe(0)
  })

  test('drops runs whose workflow id does not match the instance workflow', () => {
    const hubs = buildWorkflowHubs(overview())
    for (const hub of hubs) {
      expect(hub.runs.every((item) => item.workflowId === hub.workflow.workflowId)).toBe(true)
    }
  })
})

describe('lens and search', () => {
  test('filters by scope, source kind, and liveness', () => {
    const hubs = buildWorkflowHubs(overview())
    expect(applyLens(hubs, DEFAULT_LENS)).toHaveLength(2)
    expect(applyLens(hubs, { ...DEFAULT_LENS, scope: 'project' })).toHaveLength(1)
    expect(applyLens(hubs, { ...DEFAULT_LENS, sourceKind: 'package' })).toHaveLength(0)
    expect(applyLens(hubs, { ...DEFAULT_LENS, liveOnly: true }).map((hub) => hub.workflow.workflowId))
      .toEqual(['review-loop'])
  })

  test('searches names, workflow ids, and step ids', () => {
    const hubs = buildWorkflowHubs(overview())
    expect(searchHubs(hubs, 'kanban')).toHaveLength(1)
    expect(searchHubs(hubs, 'entry')).toHaveLength(2)
    expect(searchHubs(hubs, '   ')).toHaveLength(2)
    expect(searchHubs(hubs, 'nothing-matches')).toHaveLength(0)
  })
})

describe('carousel', () => {
  test('wraps in both directions', () => {
    expect(carouselIndex(0, 1, 3)).toBe(1)
    expect(carouselIndex(2, 1, 3)).toBe(0)
    expect(carouselIndex(0, -1, 3)).toBe(2)
    expect(carouselIndex(5, 1, 0)).toBe(0)
  })
})
