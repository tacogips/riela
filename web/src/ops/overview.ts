import type {
  OpsInstanceSummary,
  OpsOverviewResponse,
  OpsRunSummary,
  OpsWorkflowGraph,
} from '../contracts'

export interface WorkflowHubVM {
  workflow: OpsWorkflowGraph
  instances: OpsInstanceSummary[]
  runs: OpsRunSummary[]
  liveRunCount: number
  failedRunCount: number
  latestRun: OpsRunSummary | undefined
}

const LIVE_RUN_STATUSES = new Set(['running', 'created'])

export function buildWorkflowHubs(overview: OpsOverviewResponse): WorkflowHubVM[] {
  const instancesByWorkflowId = new Map<string, OpsInstanceSummary[]>()
  for (const instance of overview.instances) {
    const group = instancesByWorkflowId.get(instance.workflowId) ?? []
    group.push(instance)
    instancesByWorkflowId.set(instance.workflowId, group)
  }
  const runsByInstanceId = new Map<string, OpsRunSummary[]>()
  for (const run of overview.runs) {
    const group = runsByInstanceId.get(run.instanceId) ?? []
    group.push(run)
    runsByInstanceId.set(run.instanceId, group)
  }
  return overview.workflows.map((workflow) => {
    const instances = instancesByWorkflowId.get(workflow.workflowId) ?? []
    const runs = instances
      .flatMap((instance) => runsByInstanceId.get(instance.id) ?? [])
      .filter((run) => run.workflowId === workflow.workflowId)
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt))
    return {
      workflow,
      instances,
      runs,
      liveRunCount: runs.filter((run) => LIVE_RUN_STATUSES.has(run.status)).length,
      failedRunCount: runs.filter((run) => run.status === 'failed').length,
      latestRun: runs[0],
    }
  })
}

export interface OpsLens {
  scope: string
  sourceKind: string
  liveOnly: boolean
}

export const DEFAULT_LENS: OpsLens = { scope: 'all', sourceKind: 'all', liveOnly: false }

export function applyLens(hubs: WorkflowHubVM[], lens: OpsLens): WorkflowHubVM[] {
  return hubs.filter((hub) =>
    (lens.scope === 'all' || hub.workflow.scope === lens.scope)
    && (lens.sourceKind === 'all' || hub.workflow.sourceKind === lens.sourceKind)
    && (!lens.liveOnly || hub.liveRunCount > 0))
}

export function lensScopes(hubs: WorkflowHubVM[]): string[] {
  return [...new Set(hubs.map((hub) => hub.workflow.scope))].sort()
}

export function searchHubs(hubs: WorkflowHubVM[], query: string): WorkflowHubVM[] {
  const needle = query.trim().toLowerCase()
  if (!needle) return hubs
  return hubs.filter((hub) =>
    hub.workflow.name.toLowerCase().includes(needle)
    || hub.workflow.workflowId.toLowerCase().includes(needle)
    || hub.workflow.steps.some((step) => step.id.toLowerCase().includes(needle)))
}

/** Wraps an index for the bottom `<  workflow  >` carousel. */
export function carouselIndex(current: number, delta: number, count: number): number {
  if (count <= 0) return 0
  return ((current + delta) % count + count) % count
}
