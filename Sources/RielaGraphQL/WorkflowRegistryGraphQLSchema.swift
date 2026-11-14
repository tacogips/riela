let workflowRegistryGraphQLSchemaTypes = """
enum WorkflowRegistryScope { AUTO PROJECT USER }
enum WorkflowSourceKind { WORKFLOW PACKAGE }
enum WorkflowProvenance { MUTABLE IMMUTABLE }
enum WorkflowActivationState { ACTIVE DEACTIVATED }
enum WorkflowRetireMode { DEACTIVATE DELETE }
enum WorkflowBundleReferenceKind { LOCAL_PATH MANAGED_REFERENCE }
enum WorkflowRegistryErrorCode {
  WORKFLOW_NOT_FOUND WORKFLOW_DEACTIVATED IMMUTABLE_WORKFLOW DUPLICATE_WORKFLOW
  INVALID_WORKFLOW INVALID_ORIGIN INVALID_FILTER INVALID_RETIRE_MODE
  UNSUPPORTED_BUNDLE_REFERENCE WORKFLOW_REGISTRY_UNAVAILABLE UNAUTHENTICATED FORBIDDEN
  REGISTRY_CONFLICT REGISTRY_IO_FAILURE
}
input WorkflowFilter {
  query: String
  description: String
  scope: WorkflowRegistryScope
  sourceKind: WorkflowSourceKind
  provenance: WorkflowProvenance
  mutable: Boolean
  activationState: WorkflowActivationState
}
input WorkflowTargetInput { workflowId: String!, scope: WorkflowRegistryScope = AUTO, originId: String }
input WorkflowBundleReferenceInput { kind: WorkflowBundleReferenceKind!, value: String! }
input RegisterMutableWorkflowInput {
  bundle: WorkflowBundleReferenceInput!
  overwrite: Boolean = false
  activationState: WorkflowActivationState
}
input UpdateMutableWorkflowInput { target: WorkflowTargetInput!, bundle: WorkflowBundleReferenceInput! }
input DeleteMutableWorkflowInput { target: WorkflowTargetInput! }
input SetWorkflowActivationInput { target: WorkflowTargetInput! }
input ConsolidateWorkflowsInput {
  sources: [WorkflowTargetInput!]!
  replacement: WorkflowBundleReferenceInput!
  retireMode: WorkflowRetireMode!
  activateReplacement: Boolean = true
}
type WorkflowRegistryDiagnostic { severity: String!, path: String, message: String! }
type WorkflowRegistryEntry {
  originId: String!
  workflowId: String!
  name: String!
  description: String
  scope: WorkflowRegistryScope!
  sourceKind: WorkflowSourceKind!
  provenance: WorkflowProvenance!
  mutable: Boolean!
  activationState: WorkflowActivationState!
  valid: Boolean!
  packageName: String
  packageVersion: String
  diagnostics: [WorkflowRegistryDiagnostic!]!
}
type WorkflowRegistryError {
  code: WorkflowRegistryErrorCode!
  message: String!
  workflowId: String
  originId: String
}
type WorkflowListPayload { workflows: [WorkflowRegistryEntry!]!, errors: [WorkflowRegistryError!]! }
type WorkflowQueryPayload { workflow: WorkflowRegistryEntry, errors: [WorkflowRegistryError!]! }
type WorkflowMutationPayload {
  accepted: Boolean!
  overwritten: Boolean!
  workflow: WorkflowRegistryEntry
  retiredWorkflows: [WorkflowRegistryEntry!]!
  errors: [WorkflowRegistryError!]!
}
"""
