import type { WorkflowDefinitionResponse } from '../contracts'

export interface DiscoveredDefinitionResource {
  profileKey: string
  sourceId: string
  detail: WorkflowDefinitionResponse
}

export function discoveredDefinitionMatchesSelection(
  profileKey: string,
  selectedSourceId: string,
  resource: DiscoveredDefinitionResource | undefined,
): boolean {
  return Boolean(
    resource
      && resource.profileKey === profileKey
      && resource.sourceId === selectedSourceId,
  )
}

