import Foundation
import RielaCore
@testable import RielaGraphQL

enum UnexpectedWorkflowRegistryProviderError: Error {
  case injected
}

actor FailingWorkflowRegistryProvider: WorkflowRegistryGraphQLProviding {
  private var deletedWorkflowIds: [String] = []

  func deleteWorkflowIds() -> [String] { deletedWorkflowIds }
  func workflows(filter: WorkflowRegistryFilter) async throws -> [GraphQLWorkflowRegistryEntry] { [] }

  func workflow(target: WorkflowRegistryTarget) async throws -> GraphQLWorkflowRegistryEntry {
    throw WorkflowRegistryError(code: .workflowNotFound, message: "not found")
  }

  func registerMutableWorkflow(input: GraphQLRegisterMutableWorkflowInput, resolvedBundleURL: URL) async throws -> GraphQLWorkflowMutationPayload {
    if resolvedBundleURL.lastPathComponent == "cancel" { throw CancellationError() }
    if resolvedBundleURL.lastPathComponent == "explode" { throw UnexpectedWorkflowRegistryProviderError.injected }
    return GraphQLWorkflowMutationPayload(accepted: true)
  }

  func updateMutableWorkflow(input: GraphQLUpdateMutableWorkflowInput, resolvedBundleURL: URL) async throws -> GraphQLWorkflowMutationPayload {
    GraphQLWorkflowMutationPayload(accepted: true)
  }

  func deleteMutableWorkflow(input: GraphQLDeleteMutableWorkflowInput) async throws -> GraphQLWorkflowMutationPayload {
    deletedWorkflowIds.append(input.target.workflowId)
    if input.target.workflowId == "cancel" { throw CancellationError() }
    if input.target.workflowId == "explode" { throw UnexpectedWorkflowRegistryProviderError.injected }
    return GraphQLWorkflowMutationPayload(accepted: true)
  }

  func setWorkflowActivation(input: GraphQLSetWorkflowActivationInput, state: WorkflowActivationState) async throws -> GraphQLWorkflowMutationPayload {
    GraphQLWorkflowMutationPayload(accepted: true)
  }

  func consolidateWorkflows(input: GraphQLConsolidateWorkflowsInput, resolvedBundleURL: URL) async throws -> GraphQLWorkflowMutationPayload {
    GraphQLWorkflowMutationPayload(accepted: true)
  }
}

struct StubNoteDocumentExecutor: GraphQLDocumentExecuting, GraphQLDocumentDomainPreflighting {
  func preflight(_ request: GraphQLDocumentRequest, rootFields: [ParsedGraphQLRootField]) async -> GraphQLDocumentExecutionResponse? {
    rootFields.allSatisfy { $0.fieldName == "note" }
      ? nil
      : GraphQLDocumentExecutionResponse(handled: true, body: ["errors": .array([])])
  }

  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    GraphQLDocumentExecutionResponse(
      handled: request.query.contains("note"),
      body: ["data": .object(["note": .object(["id": .string("note-1")])])]
    )
  }
}

struct StubWorkflowRegistryProvider: WorkflowRegistryGraphQLProviding {
  func workflows(filter: WorkflowRegistryFilter) async throws -> [GraphQLWorkflowRegistryEntry] {
    let entries = [entry(id: "alpha", description: "first match", provenance: "MUTABLE"), entry(id: "beta", description: "other", provenance: "IMMUTABLE")]
    guard let query = filter.query?.lowercased(), !query.isEmpty else { return entries }
    return entries.filter { $0.workflowId.lowercased().contains(query) || ($0.description?.contains(query) ?? false) }
  }

  func workflow(target: WorkflowRegistryTarget) async throws -> GraphQLWorkflowRegistryEntry {
    entry(id: target.workflowId, description: nil, provenance: target.workflowId == "immutable" ? "IMMUTABLE" : "MUTABLE")
  }

  func registerMutableWorkflow(input: GraphQLRegisterMutableWorkflowInput, resolvedBundleURL: URL) async throws -> GraphQLWorkflowMutationPayload {
    GraphQLWorkflowMutationPayload(accepted: true, workflow: entry(id: "registered", description: nil, provenance: "MUTABLE"))
  }

  func updateMutableWorkflow(input: GraphQLUpdateMutableWorkflowInput, resolvedBundleURL: URL) async throws -> GraphQLWorkflowMutationPayload {
    try mutablePayload(target: input.target.registryTarget)
  }

  func deleteMutableWorkflow(input: GraphQLDeleteMutableWorkflowInput) async throws -> GraphQLWorkflowMutationPayload {
    try mutablePayload(target: input.target.registryTarget)
  }

  func setWorkflowActivation(input: GraphQLSetWorkflowActivationInput, state: WorkflowActivationState) async throws -> GraphQLWorkflowMutationPayload {
    GraphQLWorkflowMutationPayload(accepted: true, workflow: entry(id: input.target.workflowId, description: nil, provenance: "IMMUTABLE", activation: state.rawValue.uppercased()))
  }

  func consolidateWorkflows(input: GraphQLConsolidateWorkflowsInput, resolvedBundleURL: URL) async throws -> GraphQLWorkflowMutationPayload {
    GraphQLWorkflowMutationPayload(accepted: true, workflow: entry(id: "consolidated", description: nil, provenance: "MUTABLE"))
  }

  private func mutablePayload(target: WorkflowRegistryTarget) throws -> GraphQLWorkflowMutationPayload {
    if target.workflowId == "immutable" {
      throw WorkflowRegistryError(code: .immutableWorkflow, message: "immutable workflow cannot be changed", workflowId: target.workflowId)
    }
    return GraphQLWorkflowMutationPayload(accepted: true, workflow: entry(id: target.workflowId, description: nil, provenance: "MUTABLE"))
  }

  private func entry(
    id: String,
    description: String?,
    provenance: String,
    activation: String = "ACTIVE"
  ) -> GraphQLWorkflowRegistryEntry {
    GraphQLWorkflowRegistryEntry(
      originId: "wfo_\(id)",
      workflowId: id,
      name: id,
      description: description,
      scope: "USER",
      sourceKind: "WORKFLOW",
      provenance: provenance,
      mutable: provenance == "MUTABLE",
      activationState: activation,
      valid: true
    )
  }
}

struct StubWorkflowRegistryAuthorizer: WorkflowRegistryGraphQLAuthorizing {
  var capabilities: Set<WorkflowRegistryCapability>
  func authorize(bearerCredential: String?) async throws -> WorkflowRegistryVerifiedPrincipal {
    guard bearerCredential != nil else { throw WorkflowRegistryError(code: .unauthenticated, message: "missing") }
    return WorkflowRegistryVerifiedPrincipal(principalId: "test", capabilities: capabilities)
  }
}

struct StubManagedReferenceResolver: WorkflowRegistryManagedReferenceResolver {
  func resolveManagedReference(_ reference: String) async throws -> URL { URL(fileURLWithPath: "/managed/\(reference)") }
}
