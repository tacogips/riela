import type { JSONValue } from '../contracts'

export interface RegistryDiagnostic {
  severity: string
  path: string | null
  message: string
}

export interface RegistryWorkflow {
  originId: string
  workflowId: string
  name: string
  description: string | null
  scope: string
  provenance: string
  mutable: boolean
  activationState: string
  valid: boolean
  definition?: Record<string, JSONValue> | null
  definitionRevision?: string | null
  diagnostics: RegistryDiagnostic[]
}

export interface RegistryError {
  code: string
  message: string
}

export interface RegistryMutationPayload {
  accepted: boolean
  workflow: RegistryWorkflow | null
  errors: RegistryError[]
}
