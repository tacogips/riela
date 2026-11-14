import type { Document, Step } from './graph'

export function placementRecord(value: unknown): Document {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Document : {}
}

export function updatePlacement(step: Step, patch: Document | null): Step {
  const next = { ...step }
  if (patch === null) delete next.placement
  else next.placement = { ...placementRecord(step.placement), ...patch }
  return next
}

export function placementProblems(value: unknown): string[] {
  if (value === undefined) return []
  const placement = placementRecord(value)
  const target = placementRecord(placement.target)
  const safeText = (value: unknown) => typeof value === 'string' && value.length > 0
    && new TextEncoder().encode(value).length <= 256
    && !Array.from(value).some(c => c.charCodeAt(0) < 32 || (c.charCodeAt(0) >= 127 && c.charCodeAt(0) <= 159))
  const name = (value: unknown) => safeText(value) && typeof value === 'string' && value.trim() === value
  const problems: string[] = []
  if (!name(placement.workspace)) problems.push('Enter the workspace name configured on the worker.')
  if (!placement.target || typeof placement.target !== 'object' || Array.isArray(placement.target)
    || Object.keys(target).some(key => !['workerId', 'group'].includes(key)) || Object.values(target).some(value => !name(value))) {
    problems.push('Worker ID and group must be nonempty names when specified; leave both empty for any remote worker.')
  }
  if (Object.keys(placement).some(key => !['workspace', 'target', 'exports'].includes(key))) problems.push('Placement contains unsupported fields; check the complete workflow definition.')
  if (placement.exports !== undefined) {
    const paths = placement.exports
    if (!Array.isArray(paths) || paths.length > 16 || new Set(paths).size !== paths.length || paths.some(path =>
      !safeText(path) || typeof path !== 'string' || path.includes('\\') || path.split('/').some(part => !part || part === '.' || part === '..'))) {
      problems.push('Exports require at most 16 unique workspace-relative file paths without traversal.')
    }
  }
  return problems
}
