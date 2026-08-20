import { describe, expect, test } from 'bun:test'
import {
  OPS_MAX_SCALE,
  OPS_MIN_SCALE,
  cameraTransform,
  fitCamera,
  panBy,
  seededCluster,
  seededUnit,
  zoomAt,
} from './scene'

describe('camera zoom', () => {
  test('keeps the world point under the cursor fixed while zooming', () => {
    const camera = { offsetX: 40, offsetY: -12, scale: 1 }
    const zoomed = zoomAt(camera, 300, 200, 1.5)
    const worldBefore = { x: (300 - camera.offsetX) / camera.scale, y: (200 - camera.offsetY) / camera.scale }
    const worldAfter = { x: (300 - zoomed.offsetX) / zoomed.scale, y: (200 - zoomed.offsetY) / zoomed.scale }
    expect(worldAfter.x).toBeCloseTo(worldBefore.x)
    expect(worldAfter.y).toBeCloseTo(worldBefore.y)
    expect(zoomed.scale).toBeCloseTo(1.5)
  })

  test('clamps scale to the allowed range', () => {
    const camera = { offsetX: 0, offsetY: 0, scale: 1 }
    expect(zoomAt(camera, 0, 0, 100).scale).toBe(OPS_MAX_SCALE)
    expect(zoomAt(camera, 0, 0, 0.0001).scale).toBe(OPS_MIN_SCALE)
  })

  test('pan shifts the offset only', () => {
    expect(panBy({ offsetX: 5, offsetY: 6, scale: 2 }, 10, -4)).toEqual({ offsetX: 15, offsetY: 2, scale: 2 })
  })
})

describe('fit camera', () => {
  test('centers the bounds inside the viewport', () => {
    const camera = fitCamera({ minX: -100, minY: -100, maxX: 100, maxY: 100 }, { width: 800, height: 600 }, 100)
    const centerScreenX = 0 * camera.scale + camera.offsetX
    const centerScreenY = 0 * camera.scale + camera.offsetY
    expect(centerScreenX).toBeCloseTo(400)
    expect(centerScreenY).toBeCloseTo(300)
    expect(camera.scale).toBeCloseTo(1.6)
  })

  test('shrinks to fit a wide scene', () => {
    const camera = fitCamera({ minX: -1000, minY: -50, maxX: 1000, maxY: 50 }, { width: 600, height: 400 }, 100)
    expect(camera.scale).toBeCloseTo(400 / 2000)
  })

  test('never zooms past the readable ceiling', () => {
    const camera = fitCamera({ minX: -1, minY: -1, maxX: 1, maxY: 1 }, { width: 2000, height: 2000 })
    expect(camera.scale).toBeLessThanOrEqual(1.6)
  })

  test('renders the transform string', () => {
    expect(cameraTransform({ offsetX: 1.5, offsetY: -2, scale: 0.5 })).toBe('translate(1.5 -2) scale(0.5)')
  })
})

describe('seeded scatter', () => {
  test('is deterministic for the same seed and varies across seeds', () => {
    expect(seededUnit('workflow-a', 3)).toBe(seededUnit('workflow-a', 3))
    expect(seededUnit('workflow-a', 3)).not.toBe(seededUnit('workflow-b', 3))
    const cluster = seededCluster('core', 32, 100)
    expect(cluster).toEqual(seededCluster('core', 32, 100))
    expect(cluster).toHaveLength(32)
    for (const point of cluster) {
      expect(Math.hypot(point.x, point.y)).toBeLessThanOrEqual(100.0001)
    }
  })
})
