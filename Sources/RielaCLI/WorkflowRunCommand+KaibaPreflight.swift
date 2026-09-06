import RielaCore
import RielaKaibaSupport

struct KaibaPreflightedRunContext: Sendable {
  let workingDirectory: String
  let environment: [String: String]
  let snapshot: KaibaExecutionSnapshot?
}

struct PreparedWorkflowRunExecution {
  let instance: EffectiveWorkflowInstance
  let calleeResolver: FileSystemWorkflowCalleeResolver
  let context: KaibaPreflightedRunContext
}

extension WorkflowRunCommand {
  func prepareRunExecution(
    options: WorkflowRunOptions,
    resolution: WorkflowResolutionOptions,
    bundle: inout ResolvedWorkflowBundle,
    variables: JSONObject
  ) async throws -> PreparedWorkflowRunExecution {
    let instance = try prepareEffectiveRunBundle(
      options: options,
      resolution: resolution,
      bundle: &bundle,
      variables: variables
    )
    let calleeResolver = FileSystemWorkflowCalleeResolver(
      resolver: resolver,
      baseResolution: resolution
    )
    let context = try await preflightedRunContext(
      options: options,
      instance: instance,
      nodes: bundle.workflow.nodes,
      workflow: bundle.workflow,
      calleeResolver: calleeResolver
    )
    return PreparedWorkflowRunExecution(
      instance: instance,
      calleeResolver: calleeResolver,
      context: context
    )
  }

  func prepareEffectiveRunBundle(
    options: WorkflowRunOptions,
    resolution: WorkflowResolutionOptions,
    bundle: inout ResolvedWorkflowBundle,
    variables: JSONObject
  ) throws -> EffectiveWorkflowInstance {
    let resolutionResult = try resolveEffectiveInstance(
      options: options,
      workflowId: bundle.workflow.workflowId,
      variables: variables,
      nodePayloads: bundle.nodePayloads
    )
    bundle.nodePayloads = resolutionResult.nodePayloads
    bundle.workflow.nodes = try WorkflowInstanceResolver.applyKaibaInstancePatches(
      resolutionResult.instance.configuration.nodePatches,
      to: bundle.workflow.nodes
    )
    try validateEffectiveSessionPolicies(bundle)
    try saveRequestedEffectiveInstance(
      options: options,
      resolution: resolution,
      bundle: bundle,
      effectiveInstance: resolutionResult.instance
    )
    return resolutionResult.instance
  }

  func saveRequestedEffectiveInstance(
    options: WorkflowRunOptions,
    resolution: WorkflowResolutionOptions,
    bundle: ResolvedWorkflowBundle,
    effectiveInstance: EffectiveWorkflowInstance
  ) throws {
    guard let identity = options.saveInstance else { return }
    try saveEffectiveInstance(
      identity: identity,
      workflowId: bundle.workflow.workflowId,
      sourceIdentity: persistenceIdentity(
        requestedResolution: resolution,
        bundle: bundle,
        fromRegistry: options.fromRegistry
      ).workflowName,
      effectiveInstance: effectiveInstance,
      options: options
    )
  }

  func preflightKaibaNodes(
    _ nodes: [WorkflowNodeRef],
    environment: [String: String],
    mockScenarioPath: String?,
    workflow: WorkflowDefinition,
    calleeResolver: any WorkflowCalleeResolving
  ) async throws -> KaibaExecutionSnapshot? {
    guard mockScenarioPath == nil else { return nil }
    do {
      return try await KaibaExecutionPreflight.workflow(
        nodes: nodes,
        environment: environment,
        workflow: workflow,
        calleeResolver: calleeResolver
      )
    } catch {
      if let preflight = CLIUsageError.kaibaPreflight(error) {
        throw preflight
      }
      throw error
    }
  }

  func preflightedRunContext(
    options: WorkflowRunOptions,
    instance: EffectiveWorkflowInstance,
    nodes: [WorkflowNodeRef],
    workflow: WorkflowDefinition,
    calleeResolver: any WorkflowCalleeResolving
  ) async throws -> KaibaPreflightedRunContext {
    let workingDirectory = effectiveRunWorkingDirectory(options: options, instance: instance)
    let environment = try effectiveRunEnvironment(
      configuration: instance.configuration,
      workingDirectory: workingDirectory
    )
    let snapshot = try await preflightKaibaNodes(
      nodes,
      environment: environment,
      mockScenarioPath: options.mockScenarioPath,
      workflow: workflow,
      calleeResolver: calleeResolver
    )
    return KaibaPreflightedRunContext(
      workingDirectory: workingDirectory,
      environment: environment,
      snapshot: snapshot
    )
  }
}
