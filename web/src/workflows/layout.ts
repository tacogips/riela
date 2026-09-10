import { clampScale, type OpsCamera } from '../ops/scene'

export interface GraphLayout {
  version: 1
  positions: Record<string, { x: number; y: number }>
  camera?: OpsCamera
}

/** Presentation data is never serialized into the executable workflow. */
export function layoutKey(profileKey: string, originId: string): string {
  return `riela:workflow-layout:v1:${JSON.stringify([profileKey, originId])}`
}

export function readLayout(storage: Pick<Storage, 'getItem'>, key: string): GraphLayout {
  const empty: GraphLayout = { version: 1, positions: {} }
  try {
    const raw = JSON.parse(storage.getItem(key) ?? 'null') as GraphLayout | null
    if (raw?.version !== 1 || !raw.positions || typeof raw.positions !== 'object') return empty
    const positions = Object.fromEntries(Object.entries(raw.positions).filter(([, point]) =>
      point && Number.isFinite(point.x) && Number.isFinite(point.y)))
    const camera = raw.camera && [raw.camera.offsetX, raw.camera.offsetY, raw.camera.scale].every(Number.isFinite)
      ? { ...raw.camera, scale: clampScale(raw.camera.scale) } : undefined
    return { version: 1, positions, camera }
  } catch { return empty }
}

export function writeLayout(storage: Pick<Storage, 'setItem'>, key: string, layout: GraphLayout): boolean {
  try { storage.setItem(key, JSON.stringify(layout)); return true } catch { return false }
}
