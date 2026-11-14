import type { Instance } from '../contracts'

export function instanceSelectionForProfile(
  previousProfileKey: string | undefined,
  nextProfileKey: string,
  selectedId: string | undefined,
): string | undefined {
  return previousProfileKey !== undefined && previousProfileKey !== nextProfileKey
    ? undefined
    : selectedId
}

export interface InstanceEditorSnapshot {
  workingDirectory: string
  environmentFilePath: string
  variables: string
  expectedRevision: number
}

export function instanceEditorSnapshot(
  instance: Instance,
  expectedRevision: number,
): InstanceEditorSnapshot {
  return {
    workingDirectory: instance.workingDirectory ?? '',
    environmentFilePath: instance.environmentFilePath ?? '',
    variables: JSON.stringify(instance.workflowVariables, null, 2),
    expectedRevision,
  }
}

export function instanceEditorIdentity(profileKey: string, instanceId: string): string {
  return `${profileKey}\u{1f}${instanceId}`
}

