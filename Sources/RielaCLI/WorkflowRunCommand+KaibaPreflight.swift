import RielaCore
import RielaKaibaSupport
import RielaWork

struct KaibaPreflightedRunContext: Sendable {
  let workingDirectory: String
  let environment: [String: String]
  let snapshot: KaibaExecutionSnapshot?
}

struct PreparedWorkflowRunExecution {
  let instance: EffectiveWorkflowInstance
  let calleeResolver: FileSystemWorkflowCalleeResolver
  let context: KaibaPreflightedRunContext
  let gatewayValidationWarnings: [String]
}

struct PreparedResolvedWorkflowRun {
  let bundle: ResolvedWorkflowBundle
  let variables: JSONObject
  let execution: PreparedWorkflowRunExecution
  let definitionSource: WorkflowDefinitionSource
}

extension WorkflowRunCommand {
  func prepareResolvedRun(
    options: WorkflowRunOptions,
    resolution: WorkflowResolutionOptions,
    taskContext: TaskPlacementExecutionContext?
  ) async throws -> PreparedResolvedWorkflowRun {
    let effectiveResolver: any WorkflowBundleResolving
    if case let .service(actor) = options.executionMode, taskContext == nil, !options.fromRegistry {
      effectiveResolver = DefinitionStoreWorkflowBundleResolver(
        inner: resolver,
        sessionStore: options.sessionStore,
        actor: actor,
        mode: .lookupOrSeed
      )
    } else {
      // one-time runs never open definition tables (issue #179 policy)
      effectiveResolver = resolver
    }
    var pendingDefinitionSeed: ResolvedWorkflowBundle?
    var bundle = try resolveRunBundle(
      options: options,
      resolution: resolution,
      taskContext: taskContext,
      effectiveResolver: effectiveResolver,
      pendingDefinitionSeed: &pendingDefinitionSeed
    )
    try applyEntryStep(options.entryStepId, to: &bundle)
    let variables = try parseVariables(options.variables, workingDirectory: options.workingDirectory)
    let execution = try await prepareRunExecution(
      options: options,
      resolution: resolution,
      bundle: &bundle,
      variables: variables,
      taskContext: taskContext,
      resolver: effectiveResolver
    )
    if let pendingDefinitionSeed,
       let storeResolver = effectiveResolver as? DefinitionStoreWorkflowBundleResolver {
      let preparedNodes = bundle.workflow.nodes
      let preparedPayloads = bundle.nodePayloads
      bundle = try storeResolver.seed(fileBundle: pendingDefinitionSeed, options: resolution)
      bundle.workflow.nodes = preparedNodes
      bundle.nodePayloads = preparedPayloads
      try applyEntryStep(options.entryStepId, to: &bundle)
    }
    let definitionSource = bundle.definitionSource
      ?? WorkflowDefinitionDocument.fileDefinitionSource(for: bundle, workflowName: options.target)
    return PreparedResolvedWorkflowRun(
      bundle: bundle,
      variables: variables,
      execution: execution,
      definitionSource: definitionSource
    )
  }

  func resolveRunBundle(
    options: WorkflowRunOptions,
    resolution: WorkflowResolutionOptions,
    taskContext: TaskPlacementExecutionContext?,
    effectiveResolver: any WorkflowBundleResolving,
    pendingDefinitionSeed: inout ResolvedWorkflowBundle?
  ) throws -> ResolvedWorkflowBundle {
    if let taskContext {
      guard let bundle = taskContext.bundles[options.target] else {
        throw WorkStoreError("reserved task root is absent from admitted bundles")
      }
      return bundle
    }
    let bundle: ResolvedWorkflowBundle
    if let temporary = try loadTemporaryWorkflowIfPresent(options.target, workingDirectory: options.workingDirectory) {
      bundle = temporary
    } else if options.fromRegistry { bundle = try resolveRegistryRunBundle(options: options) } else {
      if let storeResolver = effectiveResolver as? DefinitionStoreWorkflowBundleResolver {
        if let stored = try storeResolver.lookup(resolution) {
          bundle = stored
        } else {
          bundle = try resolver.resolve(resolution)
          pendingDefinitionSeed = bundle
        }
      } else {
        // one-time runs never open definition tables (issue #179 policy)
        bundle = try effectiveResolver.resolve(resolution)
      }
    }
    return bundle
  }

  private func applyEntryStep(_ entryStepId: String?, to bundle: inout ResolvedWorkflowBundle) throws {
    guard let entryStepId else { return }
    guard bundle.workflow.steps.contains(where: { $0.id == entryStepId }) else {
      throw AdapterExecutionError(.invalidInput, "workflow entry step does not exist")
    }
    bundle.workflow.entryStepId = entryStepId
  }

  func prepareRunExecution(
    options: WorkflowRunOptions,
    resolution: WorkflowResolutionOptions,
    bundle: inout ResolvedWorkflowBundle,
    variables: JSONObject,
    taskContext: TaskPlacementExecutionContext? = nil,
    resolver: (any WorkflowBundleResolving)? = nil
  ) async throws -> PreparedWorkflowRunExecution {
    let effectiveResolver = resolver ?? self.resolver
    let preparedBundle = try prepareEffectiveRunBundle(
      options: options,
      resolution: resolution,
      bundle: &bundle,
      variables: variables
    )
    let instance = preparedBundle.instance
    if let taskContext {
      bundle = try applyingTaskPlacement(taskContext, to: bundle)
    }
    let calleeResolver = FileSystemWorkflowCalleeResolver(
      resolver: effectiveResolver,
      baseResolution: resolution,
      taskContext: taskContext
    )
    let context = try await preflightedRunContext(
      options: options,
      instance: instance,
      nodes: bundle.workflow.nodes,
      workflow: bundle.workflow,
      calleeResolver: calleeResolver,
      requiredEnvironment: try await CLIRuntimeEnvironmentPreparation.required(
        bundle: bundle,
        resolution: resolution,
        resolver: effectiveResolver
      )
    )
    return PreparedWorkflowRunExecution(
      instance: instance,
      calleeResolver: calleeResolver,
      context: context,
      gatewayValidationWarnings: preparedBundle.gatewayValidationWarnings
    )
  }

  func prepareEffectiveRunBundle(
    options: WorkflowRunOptions,
    resolution: WorkflowResolutionOptions,
    bundle: inout ResolvedWorkflowBundle,
    variables: JSONObject
  ) throws -> (instance: EffectiveWorkflowInstance, gatewayValidationWarnings: [String]) {
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
    let gatewayValidationWarnings = try validateEffectiveSessionPolicies(bundle)
    try saveRequestedEffectiveInstance(
      options: options,
      resolution: resolution,
      bundle: bundle,
      effectiveInstance: resolutionResult.instance
    )
    return (resolutionResult.instance, gatewayValidationWarnings)
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
    calleeResolver: any WorkflowCalleeResolving,
    requiredEnvironment: [String] = []
  ) async throws -> KaibaPreflightedRunContext {
    let workingDirectory = effectiveRunWorkingDirectory(options: options, instance: instance)
    let base = try effectiveRunEnvironment(
      configuration: instance.configuration,
      workingDirectory: workingDirectory
    )
    // Mock scenarios never reach real providers, so credentials stay optional there.
    let environment = try await CLIRuntimeEnvironmentPreparation.prepare(
      path: options.runtimeEnvironmentFile, required: options.mockScenarioPath == nil ? requiredEnvironment : [],
      base: base, workingDirectory: workingDirectory)
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
