import Foundation
import RielaCore
import RielaGraphQL

public struct FileWorkflowRegistryGraphQLProvider: WorkflowRegistryGraphQLProviding, Sendable {
  public var workingDirectory: String

  public init(workingDirectory: String = FileManager.default.currentDirectoryPath) {
    self.workingDirectory = workingDirectory
  }

  public func workflows(filter: WorkflowRegistryFilter) async throws -> [GraphQLWorkflowRegistryEntry] {
    try WorkflowRegistryService().list(filter: filter, workingDirectory: workingDirectory).map(project)
  }

  public func workflow(target: WorkflowRegistryTarget) async throws -> GraphQLWorkflowRegistryEntry {
    project(try WorkflowRegistryService().fetch(target: target, workingDirectory: workingDirectory))
  }

  public func registerMutableWorkflow(
    input: GraphQLRegisterMutableWorkflowInput,
    resolvedBundleURL: URL
  ) async throws -> GraphQLWorkflowMutationPayload {
    let activation = input.activationState.flatMap {
      WorkflowActivationState(rawValue: $0.rawValue.lowercased())
    }
    return project(try WorkflowRegistryService().register(
      input: resolvedBundleURL,
      overwrite: input.overwrite ?? false,
      activationState: activation,
      workingDirectory: workingDirectory
    ))
  }

  public func updateMutableWorkflow(
    input: GraphQLUpdateMutableWorkflowInput,
    resolvedBundleURL: URL
  ) async throws -> GraphQLWorkflowMutationPayload {
    project(try WorkflowRegistryService().update(
      target: input.target.registryTarget,
      input: resolvedBundleURL,
      workingDirectory: workingDirectory
    ))
  }

  public func deleteMutableWorkflow(
    input: GraphQLDeleteMutableWorkflowInput
  ) async throws -> GraphQLWorkflowMutationPayload {
    project(try WorkflowRegistryService().delete(
      target: input.target.registryTarget,
      workingDirectory: workingDirectory
    ))
  }

  public func setWorkflowActivation(
    input: GraphQLSetWorkflowActivationInput,
    state: WorkflowActivationState
  ) async throws -> GraphQLWorkflowMutationPayload {
    project(try WorkflowRegistryService().setActivation(
      state,
      target: input.target.registryTarget,
      workingDirectory: workingDirectory
    ))
  }

  public func consolidateWorkflows(
    input: GraphQLConsolidateWorkflowsInput,
    resolvedBundleURL: URL
  ) async throws -> GraphQLWorkflowMutationPayload {
    guard let retireMode = WorkflowRetireMode(rawValue: input.retireMode.rawValue.lowercased()) else {
      throw WorkflowRegistryError(code: .invalidRetireMode, message: "retireMode must be DEACTIVATE or DELETE")
    }
    return project(try WorkflowRegistryService().consolidate(
      sources: input.sources.map(\.registryTarget),
      replacement: resolvedBundleURL,
      retireMode: retireMode,
      activateReplacement: input.activateReplacement ?? true,
      workingDirectory: workingDirectory
    ))
  }

  private func project(_ result: WorkflowRegistryMutationResult) -> GraphQLWorkflowMutationPayload {
    GraphQLWorkflowMutationPayload(
      accepted: result.accepted,
      overwritten: result.overwritten,
      workflow: result.workflow.map(project),
      retiredWorkflows: result.retiredWorkflows.map(project),
      errors: result.errors
    )
  }

  private func project(_ entry: WorkflowCatalogEntry) -> GraphQLWorkflowRegistryEntry {
    GraphQLWorkflowRegistryEntry(
      originId: entry.originId,
      workflowId: entry.workflowId,
      name: entry.workflowName,
      description: entry.description,
      scope: entry.scope.rawValue.uppercased(),
      sourceKind: entry.sourceKind.rawValue.uppercased(),
      provenance: entry.provenance.rawValue.uppercased(),
      mutable: entry.mutable,
      activationState: entry.activationState.rawValue.uppercased(),
      valid: entry.valid,
      packageName: entry.packageName,
      packageVersion: entry.packageVersion,
      diagnostics: entry.diagnostics.map {
        GraphQLWorkflowRegistryDiagnostic(
          severity: $0.severity.rawValue,
          path: relativeDiagnosticPath($0.path),
          message: redactedDiagnosticMessage($0.message)
        )
      }
    )
  }

  private func relativeDiagnosticPath(_ path: String) -> String? {
    guard !path.hasPrefix("/") else { return nil }
    return path
  }

  private func redactedDiagnosticMessage(_ message: String) -> String {
    message.replacingOccurrences(of: workingDirectory, with: "<working-directory>")
  }
}
