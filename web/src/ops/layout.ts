import type { OpsBounds } from './scene'
import { boundsOrFallback, emptyBounds, expandBounds } from './scene'

export interface FanStepInput {
  id: string
  transitions: Array<{ toStepId: string }>
}

export interface FanNodePosition {
  id: string
  tier: number
  indexInTier: number
  tierSize: number
  x: number
  y: number
}

export interface FanEdge {
  fromStepId: string
  toStepId: string
  /** True when the edge targets an earlier or same tier (a loop-back). */
  back: boolean
}

export interface FanLayout {
  nodes: FanNodePosition[]
  edges: FanEdge[]
  bounds: OpsBounds
  /** Hub position (the workflow / session anchor below the fan). */
  hub: { x: number; y: number }
}

export const FAN_TIER_GAP = 190
export const FAN_HORIZONTAL_GAP = 210
export const FAN_HUB_GAP = 240

/**
 * Tiers a step graph by breadth-first depth from the entry step and fans each
 * tier out above the hub, mirroring the radial "command deck" composition.
 * Unreachable steps are appended as a final tier so nothing disappears.
 */
export function layoutFan(steps: FanStepInput[], entryStepId: string): FanLayout {
  const known = new Map(steps.map((step) => [step.id, step]))
  const tierByStep = new Map<string, number>()
  let frontier = known.has(entryStepId) ? [entryStepId] : []
  if (frontier.length === 0 && steps.length > 0) frontier = [steps[0]!.id]
  let depth = 0
  while (frontier.length > 0) {
    const next: string[] = []
    for (const stepId of frontier) {
      if (tierByStep.has(stepId)) continue
      tierByStep.set(stepId, depth)
      for (const transition of known.get(stepId)?.transitions ?? []) {
        if (known.has(transition.toStepId) && !tierByStep.has(transition.toStepId)) {
          next.push(transition.toStepId)
        }
      }
    }
    frontier = next
    depth += 1
  }
  const reachableTierCount = tierByStep.size === 0
    ? 0
    : Math.max(...[...tierByStep.values()]) + 1
  for (const step of steps) {
    if (!tierByStep.has(step.id)) tierByStep.set(step.id, reachableTierCount)
  }

  const tiers = new Map<number, string[]>()
  for (const step of steps) {
    const tier = tierByStep.get(step.id)!
    const row = tiers.get(tier) ?? []
    row.push(step.id)
    tiers.set(tier, row)
  }

  const nodes: FanNodePosition[] = []
  let bounds = emptyBounds()
  for (const [tier, stepIds] of tiers) {
    const spacing = stepIds.length > 5
      ? FAN_HORIZONTAL_GAP * (5 / stepIds.length) + 60
      : FAN_HORIZONTAL_GAP
    stepIds.forEach((stepId, indexInTier) => {
      const x = (indexInTier - (stepIds.length - 1) / 2) * spacing
      const y = -FAN_HUB_GAP - tier * FAN_TIER_GAP
      nodes.push({ id: stepId, tier, indexInTier, tierSize: stepIds.length, x, y })
      bounds = expandBounds(bounds, x, y, 120)
    })
  }

  const edges: FanEdge[] = []
  for (const step of steps) {
    for (const transition of step.transitions) {
      if (!known.has(transition.toStepId)) continue
      const fromTier = tierByStep.get(step.id)!
      const toTier = tierByStep.get(transition.toStepId)!
      edges.push({ fromStepId: step.id, toStepId: transition.toStepId, back: toTier <= fromTier })
    }
  }

  const hub = { x: 0, y: 0 }
  bounds = expandBounds(boundsOrFallback(bounds, { minX: -200, minY: -200, maxX: 200, maxY: 0 }), hub.x, hub.y, 150)
  return { nodes, edges, bounds, hub }
}

export interface RingPosition {
  index: number
  angle: number
  x: number
  y: number
}

/**
 * Distributes hubs on a ring around the origin, starting at the top and
 * growing the radius with the population so labels keep breathing room.
 */
export function layoutRing(count: number, baseRadius = 430): RingPosition[] {
  if (count <= 0) return []
  const radius = count <= 8 ? baseRadius : baseRadius + (count - 8) * 26
  return Array.from({ length: count }, (_, index) => {
    const angle = -Math.PI / 2 + (index * Math.PI * 2) / count
    return {
      index,
      angle,
      x: Math.cos(angle) * radius,
      y: Math.sin(angle) * radius,
    }
  })
}

export function ringBounds(positions: RingPosition[], margin = 220): OpsBounds {
  let bounds = emptyBounds()
  for (const position of positions) {
    bounds = expandBounds(bounds, position.x, position.y, margin)
  }
  return boundsOrFallback(bounds, { minX: -400, minY: -400, maxX: 400, maxY: 400 })
}

/** Vertical-ish cubic curve between two points, used for fan edges. */
export function edgePath(fromX: number, fromY: number, toX: number, toY: number): string {
  const bend = (toY - fromY) * 0.5
  return `M ${fromX} ${fromY} C ${fromX} ${fromY + bend}, ${toX} ${toY - bend}, ${toX} ${toY}`
}

/** Side arc for loop-back edges so they do not overlap the forward flow. */
export function backEdgePath(fromX: number, fromY: number, toX: number, toY: number): string {
  const sideways = fromX >= toX ? 1 : -1
  const controlX = Math.max(Math.abs(fromX), Math.abs(toX)) * sideways + 170 * sideways
  return `M ${fromX} ${fromY} C ${controlX} ${fromY}, ${controlX} ${toY}, ${toX} ${toY}`
}
