export interface OpsCamera {
  offsetX: number
  offsetY: number
  scale: number
}

export interface OpsBounds {
  minX: number
  minY: number
  maxX: number
  maxY: number
}

export interface OpsViewport {
  width: number
  height: number
}

export const OPS_MIN_SCALE = 0.2
export const OPS_MAX_SCALE = 5

export function cameraTransform(camera: OpsCamera): string {
  return `translate(${camera.offsetX} ${camera.offsetY}) scale(${camera.scale})`
}

export function clampScale(scale: number): number {
  return Math.min(OPS_MAX_SCALE, Math.max(OPS_MIN_SCALE, scale))
}

/** Zooms while keeping the world point under the given screen point fixed. */
export function zoomAt(
  camera: OpsCamera,
  screenX: number,
  screenY: number,
  factor: number,
): OpsCamera {
  const scale = clampScale(camera.scale * factor)
  if (scale === camera.scale) return camera
  const worldX = (screenX - camera.offsetX) / camera.scale
  const worldY = (screenY - camera.offsetY) / camera.scale
  return {
    scale,
    offsetX: screenX - worldX * scale,
    offsetY: screenY - worldY * scale,
  }
}

export function panBy(camera: OpsCamera, deltaX: number, deltaY: number): OpsCamera {
  return { ...camera, offsetX: camera.offsetX + deltaX, offsetY: camera.offsetY + deltaY }
}

/** Centers the world bounds inside the viewport with padding, clamped to sane zoom. */
export function fitCamera(
  bounds: OpsBounds,
  viewport: OpsViewport,
  padding = 90,
): OpsCamera {
  const worldWidth = Math.max(bounds.maxX - bounds.minX, 1)
  const worldHeight = Math.max(bounds.maxY - bounds.minY, 1)
  const availableWidth = Math.max(viewport.width - padding * 2, 40)
  const availableHeight = Math.max(viewport.height - padding * 2, 40)
  const scale = clampScale(Math.min(availableWidth / worldWidth, availableHeight / worldHeight, 1.6))
  const centerX = (bounds.minX + bounds.maxX) / 2
  const centerY = (bounds.minY + bounds.maxY) / 2
  return {
    scale,
    offsetX: viewport.width / 2 - centerX * scale,
    offsetY: viewport.height / 2 - centerY * scale,
  }
}

export function expandBounds(bounds: OpsBounds, x: number, y: number, margin = 0): OpsBounds {
  return {
    minX: Math.min(bounds.minX, x - margin),
    minY: Math.min(bounds.minY, y - margin),
    maxX: Math.max(bounds.maxX, x + margin),
    maxY: Math.max(bounds.maxY, y + margin),
  }
}

export const emptyBounds = (): OpsBounds => ({
  minX: Number.POSITIVE_INFINITY,
  minY: Number.POSITIVE_INFINITY,
  maxX: Number.NEGATIVE_INFINITY,
  maxY: Number.NEGATIVE_INFINITY,
})

export function boundsOrFallback(bounds: OpsBounds, fallback: OpsBounds): OpsBounds {
  return Number.isFinite(bounds.minX) ? bounds : fallback
}

/** Deterministic pseudo-random in [0, 1) derived from a string seed. */
export function seededUnit(seed: string, index: number): number {
  let hash = 2166136261 ^ index
  for (let position = 0; position < seed.length; position += 1) {
    hash ^= seed.charCodeAt(position)
    hash = Math.imul(hash, 16777619)
  }
  hash ^= hash >>> 13
  hash = Math.imul(hash, 1274126177)
  hash ^= hash >>> 16
  return (hash >>> 0) / 4294967296
}

export interface OpsClusterPoint {
  x: number
  y: number
  radius: number
}

/** Deterministic scatter of points inside a disc, for the core "brain" cluster. */
export function seededCluster(seed: string, count: number, radius: number): OpsClusterPoint[] {
  const points: OpsClusterPoint[] = []
  for (let index = 0; index < count; index += 1) {
    const angle = seededUnit(seed, index * 3) * Math.PI * 2
    const distance = Math.sqrt(seededUnit(seed, index * 3 + 1)) * radius
    points.push({
      x: Math.cos(angle) * distance,
      y: Math.sin(angle) * distance,
      radius: 0.8 + seededUnit(seed, index * 3 + 2) * 1.8,
    })
  }
  return points
}
