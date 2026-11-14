import { describe, expect, test } from 'bun:test'
import { FAN_HUB_GAP, FAN_TIER_GAP, layoutFan, layoutRing, ringBounds } from './layout'

const step = (id: string, ...toStepIds: string[]) => ({
  id,
  transitions: toStepIds.map((toStepId) => ({ toStepId })),
})

describe('fan layout', () => {
  test('tiers steps by breadth-first depth from the entry step', () => {
    const layout = layoutFan([
      step('entry', 'work-a', 'work-b'),
      step('work-a', 'publish'),
      step('work-b', 'publish'),
      step('publish'),
    ], 'entry')
    const tierOf = new Map(layout.nodes.map((node) => [node.id, node.tier]))
    expect(tierOf.get('entry')).toBe(0)
    expect(tierOf.get('work-a')).toBe(1)
    expect(tierOf.get('work-b')).toBe(1)
    expect(tierOf.get('publish')).toBe(2)
    const entry = layout.nodes.find((node) => node.id === 'entry')!
    expect(entry.x).toBe(0)
    expect(entry.y).toBe(-FAN_HUB_GAP)
    const publish = layout.nodes.find((node) => node.id === 'publish')!
    expect(publish.y).toBe(-FAN_HUB_GAP - 2 * FAN_TIER_GAP)
  })

  test('marks loop transitions as back edges', () => {
    const layout = layoutFan([
      step('review', 'fix'),
      step('fix', 'review'),
    ], 'review')
    const back = layout.edges.find((edge) => edge.fromStepId === 'fix')!
    const forward = layout.edges.find((edge) => edge.fromStepId === 'review')!
    expect(back.back).toBe(true)
    expect(forward.back).toBe(false)
  })

  test('appends unreachable steps to a final tier instead of dropping them', () => {
    const layout = layoutFan([
      step('entry'),
      step('orphan'),
    ], 'entry')
    const orphan = layout.nodes.find((node) => node.id === 'orphan')
    expect(orphan?.tier).toBe(1)
    expect(layout.nodes).toHaveLength(2)
  })

  test('ignores transitions to unknown steps and survives a missing entry', () => {
    const layout = layoutFan([step('lonely', 'ghost')], 'ghost')
    expect(layout.nodes.map((node) => node.id)).toEqual(['lonely'])
    expect(layout.edges).toHaveLength(0)
  })

  test('centers each tier row symmetrically', () => {
    const layout = layoutFan([
      step('entry', 'a', 'b', 'c'),
      step('a'),
      step('b'),
      step('c'),
    ], 'entry')
    const tierOne = layout.nodes.filter((node) => node.tier === 1)
    const sum = tierOne.reduce((total, node) => total + node.x, 0)
    expect(sum).toBeCloseTo(0)
    expect(new Set(tierOne.map((node) => node.x)).size).toBe(3)
  })
})

describe('ring layout', () => {
  test('spreads hubs evenly starting at the top', () => {
    const ring = layoutRing(4, 400)
    expect(ring).toHaveLength(4)
    expect(ring[0]!.x).toBeCloseTo(0)
    expect(ring[0]!.y).toBeCloseTo(-400)
    expect(ring[1]!.x).toBeCloseTo(400)
    expect(ring[1]!.y).toBeCloseTo(0)
  })

  test('grows the radius for crowded rings and yields finite bounds', () => {
    const crowded = layoutRing(16, 400)
    expect(Math.hypot(crowded[0]!.x, crowded[0]!.y)).toBeGreaterThan(400)
    const bounds = ringBounds(crowded)
    expect(bounds.minX).toBeLessThan(0)
    expect(Number.isFinite(bounds.maxY)).toBe(true)
    expect(ringBounds([]).maxX).toBe(400)
  })
})
