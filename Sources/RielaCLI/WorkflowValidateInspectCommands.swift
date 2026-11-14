import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaAdapters
import RielaAddons
import RielaCore
import RielaWork

public struct WorkflowValidateCommand: Sendable {
  public var resolver: any WorkflowBundleResolving
  public var patchApplier: any WorkflowNodePatchApplying
  public var jsonLoader: JSONReferenceLoader
  public var preflight: any WorkflowExecutablePreflighting
  var hostResolver: any HostCapabilityResolving

  public init(
    resolver: any WorkflowBundleResolving = FileSystemWorkflowBundleResolver(),
    patchApplier: any WorkflowNodePatchApplying = DefaultWorkflowNodePatchApplier(),
    jsonLoader: JSONReferenceLoader = JSONReferenceLoader(),
    preflight: any WorkflowExecutablePreflighting = DeterministicWorkflowExecutablePreflight()
  ) {
    self.resolver = resolver
    self.patchApplier = patchApplier
    self.jsonLoader = jsonLoader
    self.preflight = preflight
    hostResolver = HostCapabilityResolver()
  }

  init(
    resolver: any WorkflowBundleResolving,
    patchApplier: any WorkflowNodePatchApplying = DefaultWorkflowNodePatchApplier(),
    jsonLoader: JSONReferenceLoader = JSONReferenceLoader(),
    preflight: any WorkflowExecutablePreflighting = DeterministicWorkflowExecutablePreflight(),
    hostResolver: any HostCapabilityResolving
  ) {
    self.resolver = resolver
    self.patchApplier = patchApplier
    self.jsonLoader = jsonLoader
    self.preflight = preflight
    self.hostResolver = hostResolver
  }

  public func run(_ options: WorkflowValidateOptions) async -> CLICommandResult {
    do {
      var bundle = try resolver.resolve(options.resolution)
      if let patch = options.nodePatch {
        bundle.nodePayloads = try patchApplier.applyNodePatch(
          jsonLoader.object(from: patch, workingDirectory: options.resolution.workingDirectory),
          to: bundle.nodePayloads
        )
      }
      let patchedProviderDiagnostics = options.nodePatch == nil ? [] : bundle.nodePayloads.keys.sorted().flatMap { nodeId in
        bundle.nodePayloads[nodeId].map { validateAgentNodePayload($0, path: "nodes.\(nodeId)") } ?? []
      }
      let hostDiagnostics = await hostDiagnostics(bundle: bundle, options: options)
      let diagnostics = bundle.diagnostics +
        DefaultWorkflowValidator().validate(
          bundle.workflow, nodePayloads: bundle.nodePayloads,
          addonEvidence: resolvedAddonRouteEvidence(bundle.workflow, packageManifest: bundle.packageManifest)
        ) +
        patchedProviderDiagnostics +
        (await runtimeCapabilityDiagnostics(
          bundle: bundle,
          resolution: options.resolution,
          resolver: resolver
        )) + hostDiagnostics
      let nodeResults = options.executable
        ? try await preflight.preflight(
          bundle.workflow,
          nodePayloads: bundle.nodePayloads,
          packageManifest: bundle.packageManifest,
          sourceScope: bundle.sourceScope
        )
        : []
      let valid = !diagnostics.contains { $0.severity == .error } && !nodeResults.contains { !$0.valid }
      let result = WorkflowValidationCommandResult(
        valid: valid,
        workflowId: bundle.workflow.workflowId,
        sourceScope: bundle.sourceScope,
        sourceKind: workflowSourceKind(bundle),
        workflowDirectory: bundle.workflowDirectory,
        packageName: bundle.packageManifest?.name,
        packageVersion: bundle.packageManifest?.version,
        packageDirectory: bundle.packageDirectory,
        mutable: bundle.provenance == .mutable,
        provenance: bundle.provenance,
        activationState: bundle.activationState,
        diagnostics: diagnostics,
        nodeValidationResults: nodeResults
      )
      return CLICommandResult(
        exitCode: valid ? .success : .failure,
        stdout: try render(result, output: options.output)
      )
    } catch let error as WorkflowResolutionError {
      let diagnostics: [WorkflowValidationDiagnostic]
      if case let .invalidWorkflow(workflowDiagnostics) = error {
        diagnostics = workflowDiagnostics
      } else {
        diagnostics = []
      }
      return renderFailure(
        options: options,
        exitCode: .failure,
        error: "\(error)",
        diagnostics: diagnostics
      )
    } catch let error as CLIUsageError {
      return renderFailure(options: options, exitCode: .usage, error: error.message)
    } catch {
      return renderFailure(options: options, exitCode: .failure, error: "\(error)")
    }
  }

  private func hostDiagnostics(
    bundle: ResolvedWorkflowBundle,
    options: WorkflowValidateOptions
  ) async -> [WorkflowValidationDiagnostic] {
    do {
      return try await workflowHostAssessment(
        bundle: bundle,
        resolution: options.resolution,
        resolver: resolver,
        hostResolver: hostResolver,
        host: options.host,
        strictHost: options.strictHost
      ).diagnostics
    } catch {
      return [WorkflowValidationDiagnostic(
        severity: .error,
        path: "workflow.requirements",
        message: "host requirements could not be resolved: \(error)"
      )]
    }
  }

  private func render(_ result: WorkflowValidationCommandResult, output: WorkflowOutputFormat) throws -> String {
    switch output {
    case .json, .jsonl:
      return try jsonString(result)
    case .text, .table:
      var lines = [
        result.valid ? "valid: \(result.workflowId)" : "invalid: \(result.workflowId)",
        "source: \(result.sourceScope.rawValue) \(result.sourceKind.rawValue) \(result.provenance.rawValue) \(result.activationState.rawValue) \(result.workflowDirectory)"
      ]
      if let packageName = result.packageName {
        lines.append("package: \(packageName) \(result.packageVersion ?? "") \(result.packageDirectory ?? "")")
      }
      lines.append("mutable: \(result.mutable ? "true" : "false")")
      lines.append(contentsOf: result.diagnostics.map { "\($0.severity.rawValue): \($0.path): \($0.message)" })
      lines.append(contentsOf: result.nodeValidationResults.map { "\($0.valid ? "ok" : "error"): \($0.nodeId): \($0.message)" })
      return lines.joined(separator: "\n") + "\n"
    }
  }

  private func renderFailure(
    options: WorkflowValidateOptions,
    exitCode: CLIExitCode,
    error: String,
    diagnostics: [WorkflowValidationDiagnostic] = []
  ) -> CLICommandResult {
    guard options.output.isStructured else {
      return CLICommandResult(exitCode: exitCode, stderr: error)
    }
    let result = WorkflowValidationFailureResult(
      workflowId: options.workflowName,
      sourceScope: options.resolution.scope == .direct ? nil : options.resolution.scope,
      workflowDirectory: options.resolution.workflowDefinitionDir,
      diagnostics: diagnostics,
      error: error,
      exitCode: exitCode.rawValue
    )
    let stdout = (try? jsonString(result)) ?? #"{"diagnostics":[],"error":"failed to encode validate failure","exitCode":1,"nodeValidationResults":[],"valid":false,"workflowId":"workflow validate"}"# + "\n"
    return CLICommandResult(exitCode: exitCode, stdout: stdout)
  }
}

public struct WorkflowInspectionCounts: Codable, Equatable, Sendable {
  public var steps: Int
  public var nodes: Int
  public var crossWorkflowDispatches: Int
}

public struct WorkflowCallableInspection: Codable, Equatable, Sendable {
  public var stepId: String
  public var role: NodeRole
  public var input: NodeInputContract?
  public var output: NodeOutputContract?
}

public struct WorkflowLoopInspectionSummary: Codable, Equatable, Sendable {
  public var kind: String?
  public var required: Bool
  public var description: String?
  public var evidenceRequired: Bool
  public var artifactRootPolicy: String?
  public var requiredEvidenceSections: [String]
  public var gates: [WorkflowLoopGateInspection]
  public var steps: [WorkflowStepLoopInspection]
  public var policies: WorkflowLoopPolicyInspection?
  public var implementationPlan: WorkflowLoopImplementationPlanInspection?
}

public struct WorkflowLoopGateInspection: Codable, Equatable, Sendable {
  public var id: String
  public var stepId: String
  public var required: Bool
  public var acceptDecision: LoopGateDecision?
  public var maxHighFindings: Int?
  public var maxMediumFindings: Int?
}

public struct WorkflowStepLoopInspection: Codable, Equatable, Sendable {
  public var stepId: String
  public var role: String?
  public var gateId: String?
  public var evidenceTags: [String]
  public var recordsChangedFiles: Bool?
  public var recordsVerification: Bool?
}

public struct WorkflowLoopPolicyInspection: Codable, Equatable, Sendable {
  public var allowedWriteRoots: [String]
  public var scratchRoot: String?
  public var commit: String?
  public var push: String?
  public var nestedRiela: String?
  public var nestedCodex: String?
  public var allowedBackends: [String]
  public var requiredWorkerModel: String?
  public var networkMode: String?
}

public struct WorkflowLoopImplementationPlanInspection: Codable, Equatable, Sendable {
  public var required: Bool
  public var pathPattern: String?
}

public struct WorkflowInspectionSummary: Codable, Equatable, Sendable {
  public var workflowId: String
  public var sourceScope: WorkflowScope
  public var sourceKind: WorkflowSourceKind
  public var workflowDirectory: String
  public var packageName: String?
  public var packageVersion: String?
  public var packageDirectory: String?
  public var mutable: Bool
  @CodableDefaultImmutable public var provenance: WorkflowProvenance
  @CodableDefaultActive public var activationState: WorkflowActivationState
  public var description: String
  public var entryStepId: String
  public var managerStepId: String?
  public var stepIds: [String]
  public var nodeRegistryIds: [String]
  public var crossWorkflowDispatchIds: [String]
  public var counts: WorkflowInspectionCounts
  public var defaults: WorkflowDefaults
  public var defaultMaxSteps: Int
  public var callable: WorkflowCallableInspection
  public var addonSourceSummaries: [String]
  public var nativeBundleAddons: [NativeBundleAddonInspection]
  public var runtimeReadinessDescriptors: [String]
  public var runtimeCapabilityGaps: [WorkflowValidationDiagnostic]
  public var backendRequirements: [WorkflowBackendRequirement]
  public var loop: WorkflowLoopInspectionSummary?
}

public struct NativeBundleAddonInspection: Codable, Equatable, Sendable {
  public var nodeId: String
  public var addon: String
  public var sourceKind: String
  public var sourceScope: String
  public var packageName: String?
  public var bundleIdentifier: String
  public var abiVersion: Int
  public var contentDigest: String
  public var dependencyClosureDigest: String
  public var signingRequired: Bool
  public var signingVerified: Bool?
  public var cacheStatus: String
  public var preflightHelperStatus: String?
}

func nativeBundleAddonInspections(
  workflow: WorkflowDefinition,
  packageManifest: WorkflowPackageManifest?,
  sourceScope: WorkflowScope
) -> [NativeBundleAddonInspection] {
  guard let packageManifest else {
    return []
  }
  let nativeLocks = packageManifest.dependencies.flatMap { dependency in
    dependency.addons.compactMap { lock -> (WorkflowPackageDependency, WorkflowPackageManifestAddonDependencyLock)? in
      lock.executionKind == .nativeBundle ? (dependency, lock) : nil
    }
  }
  guard !nativeLocks.isEmpty else {
    return []
  }

  return workflow.nodeRegistry.compactMap { node in
    guard let addon = node.addon else {
      return nil
    }
    guard let match = nativeLocks.first(where: { dependency, lock in
      let versionMatches = addon.version == nil || lock.version == addon.version
      let nameMatches = lock.name == addon.name || "\(dependency.packageId)/\(lock.name)" == addon.name
      return nameMatches && versionMatches
    }) else {
      return nil
    }
    let dependency = match.0
    let lock = match.1
    return NativeBundleAddonInspection(
      nodeId: node.id,
      addon: addon.name,
      sourceKind: WorkflowPackageAddonExecutionKind.nativeBundle.rawValue,
      sourceScope: lock.sourceScope ?? sourceScope.rawValue,
      packageName: dependency.packageId,
      bundleIdentifier: lock.bundleIdentifier ?? "",
      abiVersion: lock.abiVersion ?? 0,
      contentDigest: lock.contentDigest ?? "",
      dependencyClosureDigest: lock.dependencyClosureDigest ?? "",
      signingRequired: lock.codeSignatureRequirementDigest != nil,
      signingVerified: nil,
      cacheStatus: "not_loaded",
      preflightHelperStatus: nil
    )
  }
}

struct ReachableWorkflowMaps {
  var bundles: [String: ResolvedWorkflowBundle]
  var workflows: [String: WorkflowDefinition]
  var nodePayloads: [String: [String: AgentNodePayload]]
  var nodeHostRequirements: [String: [String: WorkflowNodeHostRequirement]]
  var localAddonExecutables: [String: Bool]
}

private struct WorkflowHostAssessment {
  var requirements: [WorkflowBackendRequirement]
  var diagnostics: [WorkflowValidationDiagnostic]
}

private func workflowHostAssessment(
  bundle: ResolvedWorkflowBundle,
  resolution: WorkflowResolutionOptions,
  resolver: any WorkflowBundleResolving,
  hostResolver: any HostCapabilityResolving,
  host: String?,
  strictHost: Bool
) async throws -> WorkflowHostAssessment {
  let maps = try await reachableWorkflowMaps(
    bundle: bundle,
    resolution: resolution,
    resolver: resolver
  )
  let requirements = try WorkflowRequirementResolver().resolve(
    workflowId: bundle.workflow.workflowId,
    workflows: maps.workflows,
    nodePayloads: maps.nodePayloads,
    nodeHostRequirements: maps.nodeHostRequirements
  )
  guard let host else {
    return WorkflowHostAssessment(requirements: requirements, diagnostics: [])
  }
  let severity: WorkflowValidationSeverity = strictHost ? .error : .warning
  let snapshots: [HostCapabilitySnapshot]
  do {
    snapshots = try await hostResolver.resolve(
      host: host,
      scope: resolution.scope,
      workingDirectory: resolution.workingDirectory,
      readOnly: true,
      localAddonExecutables: maps.localAddonExecutables
    )
  } catch {
    return WorkflowHostAssessment(
      requirements: requirements,
      diagnostics: [WorkflowValidationDiagnostic(
        severity: severity,
        path: "workflow.host",
        message: "host \(host) could not be resolved: \(error)"
      )]
    )
  }
  guard let first = snapshots.first else {
    return WorkflowHostAssessment(
      requirements: requirements,
      diagnostics: [WorkflowValidationDiagnostic(
        severity: severity,
        path: "workflow.host",
        message: "host \(host) did not resolve to an available capability snapshot"
      )]
    )
  }
  let placementResolver = BackendCapabilityPlacementResolver()
  let assignments = Dictionary(uniqueKeysWithValues: requirements.flatMap { requirement in
    requirement.provenance.compactMap { provenance -> (WorkflowRequirementProvenance, DistributedWorkerTarget)? in
      guard let target = maps.workflows[provenance.workflowId]?
        .steps.first(where: { $0.id == provenance.stepId })?.placement?.target else { return nil }
      return (provenance, target)
    }
  })
  let local = host == "local" ? first : HostCapabilitySnapshot(
    hostId: "local", live: false, backends: [], refreshedAt: Date()
  )
  let result = placementResolver.resolve(
    requirements: requirements,
    local: local,
    workers: host == "local" ? [] : snapshots,
    assignments: assignments
  )
  let failures = result.failures.map { failure in
    WorkflowValidationDiagnostic(
      severity: severity,
      path: "workflow.steps.\(failure.provenance.stepId)",
      message: "host \(host) \(failure.reason)"
    )
  }
  let unverified = result.choices.filter { !$0.verified }.map { choice in
    WorkflowValidationDiagnostic(
      severity: severity,
      path: "workflow.steps.\(choice.provenance.stepId)",
      message: "host \(host) backend \(choice.backend?.rawValue ?? "host requirement") is stale or unverified"
    )
  }
  return WorkflowHostAssessment(
    requirements: requirements,
    diagnostics: failures + unverified
  )
}

func reachableWorkflowMaps(
  bundle: ResolvedWorkflowBundle,
  resolution: WorkflowResolutionOptions,
  resolver: any WorkflowBundleResolving,
  entryStepId: String? = nil
) async throws -> ReachableWorkflowMaps {
  var workflows = [bundle.workflow.workflowId: bundle.workflow]
  var nodePayloads = [bundle.workflow.workflowId: bundle.nodePayloads]
  var nodeHostRequirements = [
    bundle.workflow.workflowId: addonHostRequirements(in: bundle)
  ]
  var bundles = [bundle.workflow.workflowId: bundle]
  var localAddonExecutables: [String: Bool] = [:]
  var pending = [(workflowId: bundle.workflow.workflowId, stepId: entryStepId ?? bundle.workflow.entryStepId)]
  var visited: Set<String> = []
  let calleeResolver = FileSystemWorkflowCalleeResolver(resolver: resolver, baseResolution: resolution)

  while !pending.isEmpty {
    let next = pending.removeFirst()
    guard visited.insert("\(next.workflowId):\(next.stepId)").inserted else { continue }
    if workflows[next.workflowId] == nil {
      let callee = try calleeResolver.resolveBundle(workflowId: next.workflowId)
      bundles[next.workflowId] = callee
      workflows[next.workflowId] = callee.workflow
      nodePayloads[next.workflowId] = callee.nodePayloads
      nodeHostRequirements[next.workflowId] = addonHostRequirements(in: callee)
    }
    guard let step = workflows[next.workflowId]?.steps.first(where: { $0.id == next.stepId }) else {
      throw WorkflowRequirementResolutionError.unknownStep(workflowId: next.workflowId, stepId: next.stepId)
    }
    if let currentBundle = bundles[next.workflowId] {
      localAddonExecutables.merge(localAddonExecutableAvailability(in: currentBundle, nodeId: step.nodeId)) {
        $0 && $1
      }
    }
    for transition in step.transitions ?? [] {
      pending.append((
        workflowId: transition.toWorkflowId ?? next.workflowId,
        stepId: transition.toStepId
      ))
      if let resume = transition.resumeStepId {
        pending.append((workflowId: next.workflowId, stepId: resume))
      }
      if let join = transition.fanout?.joinStepId {
        pending.append((workflowId: next.workflowId, stepId: join))
      }
    }
  }
  return ReachableWorkflowMaps(
    bundles: bundles,
    workflows: workflows,
    nodePayloads: nodePayloads,
    nodeHostRequirements: nodeHostRequirements,
    localAddonExecutables: localAddonExecutables
  )
}

private func addonHostRequirements(
  in bundle: ResolvedWorkflowBundle
) -> [String: WorkflowNodeHostRequirement] {
  var requirements: [String: WorkflowNodeHostRequirement] = [:]
  let packageEnvironment = bundle.packageManifest?.environmentVariables
    .filter(\.required).map(\.name) ?? []
  for node in bundle.workflow.nodeRegistry {
    let addonEnvironment = node.addon?.env?.values.compactMap { value -> String? in
      guard case let .object(binding) = value,
        case let .string(source)? = binding["fromEnv"], !source.isEmpty,
        binding["required"] != .bool(false) else { return nil }
      return source
    } ?? []
    let requiredEnvironment = Array(Set(packageEnvironment + addonEnvironment)).sorted()
    guard let reference = node.addon else {
      if !requiredEnvironment.isEmpty {
        requirements[node.id] = WorkflowNodeHostRequirement(requiredEnvironment: requiredEnvironment)
      }
      continue
    }
    guard let addon = bundle.packageManifest?.nodeAddons.first(where: {
        $0.name == reference.name && (reference.version == nil || $0.version == reference.version)
      }) else {
      let dependencyAddon = bundle.packageManifest?.dependencies.contains { dependency in
        dependency.addons.contains { lock in
          (lock.name == reference.name || "\(dependency.packageId)/\(lock.name)" == reference.name)
            && (reference.version == nil || lock.version == reference.version)
            && (lock.executionKind == .nativeBundle || lock.executionKind == .declarative
              || lock.executionKind == .container)
        }
      } == true
      if RielaBuiltinAddonCatalog.supports(name: reference.name, version: reference.version)
        || dependencyAddon {
        requirements[node.id] = WorkflowNodeHostRequirement(requiredEnvironment: requiredEnvironment)
      }
      continue
    }
    if addon.execution?.kind == .localCommand {
      guard let executable = addon.execution?.entrypoint, !executable.isEmpty else { continue }
      requirements[node.id] = WorkflowNodeHostRequirement(
        addonExecutable: executable,
        requiredEnvironment: requiredEnvironment
      )
    } else {
      requirements[node.id] = WorkflowNodeHostRequirement(requiredEnvironment: requiredEnvironment)
    }
  }
  return requirements
}

private func localAddonExecutableAvailability(
  in bundle: ResolvedWorkflowBundle,
  nodeId: String
) -> [String: Bool] {
  guard let manifest = bundle.packageManifest,
    let packageDirectory = bundle.packageDirectory else { return [:] }
  let packageRoot = URL(fileURLWithPath: packageDirectory, isDirectory: true)
  var availability: [String: Bool] = [:]
  for node in bundle.workflow.nodeRegistry where node.id == nodeId {
    guard let reference = node.addon,
      let addon = manifest.nodeAddons.first(where: {
        $0.name == reference.name && (reference.version == nil || $0.version == reference.version)
      }),
      addon.execution?.kind == .localCommand,
      let executable = addon.execution?.entrypoint,
      !executable.isEmpty else { continue }
    let candidate = packageRoot
      .appendingPathComponent(addon.sourcePath, isDirectory: true)
      .appendingPathComponent(executable, isDirectory: false)
    let isExecutable = FileManager.default.isExecutableFile(atPath: candidate.path)
    availability[executable] = (availability[executable] ?? true) && isExecutable
  }
  return availability
}

func runtimeCapabilityDiagnostics(
  bundle: ResolvedWorkflowBundle,
  resolution: WorkflowResolutionOptions,
  resolver: any WorkflowBundleResolving
) async -> [WorkflowValidationDiagnostic] {
  var diagnostics = DeterministicWorkflowRunner.unsupportedFeatures(
    in: bundle.workflow,
    supportsCrossWorkflowDispatch: true
  ).map(\.diagnostic)
  diagnostics.append(contentsOf: await crossWorkflowCalleeResolutionDiagnostics(
    workflow: bundle.workflow,
    resolution: resolution,
    resolver: resolver
  ))
  return diagnostics
}

private func crossWorkflowCalleeResolutionDiagnostics(
  workflow: WorkflowDefinition,
  resolution: WorkflowResolutionOptions,
  resolver: any WorkflowBundleResolving
) async -> [WorkflowValidationDiagnostic] {
  let references = DeterministicWorkflowRunner.crossWorkflowDispatchReferences(in: workflow)
  guard !references.isEmpty else {
    return []
  }
  let callerStepIds = Set(workflow.steps.map(\.id))
  let calleeResolver = FileSystemWorkflowCalleeResolver(resolver: resolver, baseResolution: resolution)
  var diagnostics: [WorkflowValidationDiagnostic] = []
  for reference in references {
    if !callerStepIds.contains(reference.resumeStepId) {
      diagnostics.append(WorkflowValidationDiagnostic(
        severity: .error,
        path: reference.resumeStepPath,
        message: "step '\(reference.stepId)' resumes at step '\(reference.resumeStepId)' in workflow '\(workflow.workflowId)', but that caller resume step does not exist"
      ))
    }
    let callee: ResolvedWorkflowCallee
    do {
      callee = try await calleeResolver.resolveCallee(workflowId: reference.workflowId)
    } catch {
      diagnostics.append(WorkflowValidationDiagnostic(
        severity: .error,
        path: reference.path,
        message: "step '\(reference.stepId)' references cross-workflow callee '\(reference.workflowId)', but it could not be resolved: \(workflowResolutionErrorDescription(error))"
      ))
      continue
    }
    if callee.workflow.workflowId != reference.workflowId {
      diagnostics.append(WorkflowValidationDiagnostic(
        severity: .error,
        path: reference.path,
        message: "step '\(reference.stepId)' references cross-workflow callee '\(reference.workflowId)', but resolver returned workflowId '\(callee.workflow.workflowId)'"
      ))
    }
    if !callee.workflow.steps.contains(where: { $0.id == reference.calleeEntryStepId }) {
      diagnostics.append(WorkflowValidationDiagnostic(
        severity: .error,
        path: reference.path,
        message: "step '\(reference.stepId)' dispatches to step '\(reference.calleeEntryStepId)' in workflow '\(reference.workflowId)', but that callee step does not exist"
      ))
    }
  }
  return diagnostics
}

public struct WorkflowInspectionFailureResult: Codable, Equatable, Sendable {
  public var workflowId: String
  public var sourceScope: WorkflowScope?
  public var workflowDirectory: String?
  public var diagnostics: [WorkflowValidationDiagnostic]
  public var error: String
  public var exitCode: Int32

  public init(
    workflowId: String,
    sourceScope: WorkflowScope? = nil,
    workflowDirectory: String? = nil,
    diagnostics: [WorkflowValidationDiagnostic] = [],
    error: String,
    exitCode: Int32
  ) {
    self.workflowId = workflowId
    self.sourceScope = sourceScope
    self.workflowDirectory = workflowDirectory
    self.diagnostics = diagnostics
    self.error = error
    self.exitCode = exitCode
  }
}

public struct WorkflowInspectCommand: Sendable {
  public var resolver: any WorkflowBundleResolving
  var hostResolver: any HostCapabilityResolving

  public init(resolver: any WorkflowBundleResolving = FileSystemWorkflowBundleResolver()) {
    self.resolver = resolver
    hostResolver = HostCapabilityResolver()
  }

  init(
    resolver: any WorkflowBundleResolving,
    hostResolver: any HostCapabilityResolving
  ) {
    self.resolver = resolver
    self.hostResolver = hostResolver
  }

  public func run(_ options: WorkflowInspectOptions) async -> CLICommandResult {
    do {
      let bundle = try resolver.resolve(options.resolution)
      let summary = await buildSummary(bundle, options: options)
      let failed = summary.runtimeCapabilityGaps.contains { $0.severity == .error }
      if options.output.isStructured {
        return CLICommandResult(
          exitCode: failed ? .failure : .success,
          stdout: try jsonString(summary)
        )
      }
      if options.structure {
        var output = renderStructure(bundle.workflow)
        if options.host != nil {
          output += summary.runtimeCapabilityGaps.map {
            "\($0.severity.rawValue): \($0.path): \($0.message)"
          }.joined(separator: "\n")
          if !summary.runtimeCapabilityGaps.isEmpty { output += "\n" }
        }
        return CLICommandResult(exitCode: failed ? .failure : .success, stdout: output)
      }
      return CLICommandResult(
        exitCode: failed ? .failure : .success,
        stdout: renderText(summary)
      )
    } catch let error as WorkflowResolutionError {
      let diagnostics: [WorkflowValidationDiagnostic]
      if case let .invalidWorkflow(workflowDiagnostics) = error {
        diagnostics = workflowDiagnostics
      } else {
        diagnostics = []
      }
      return renderFailure(options: options, exitCode: .failure, error: "\(error)", diagnostics: diagnostics)
    } catch {
      return renderFailure(options: options, exitCode: .failure, error: "\(error)")
    }
  }

  private func buildSummary(
    _ bundle: ResolvedWorkflowBundle,
    options: WorkflowInspectOptions
  ) async -> WorkflowInspectionSummary {
    let resolution = options.resolution
    let workflow = bundle.workflow
    let crossWorkflowIds = workflow.steps.flatMap { step in
      (step.transitions ?? []).compactMap { transition in
        transition.toWorkflowId.map { "\(step.id)->\($0):\(transition.toStepId)" }
      }
    }
    let addonSummaries = workflow.nodeRegistry.compactMap { node in
      node.addon.map { "\(node.id):\($0.name)" }
    }
    let nativeBundleAddons = nativeBundleAddonInspections(
      workflow: workflow,
      packageManifest: bundle.packageManifest,
      sourceScope: bundle.sourceScope
    )
    let readiness = workflow.nodeRegistry.map { node -> String in
      guard let payload = bundle.nodePayloads[node.id] else {
        return "\(node.id):not_checked"
      }
      return "\(node.id):\(payload.executionBackend?.rawValue ?? "deterministic-local")"
    }
    let callable = buildCallableInspection(workflow, nodePayloads: bundle.nodePayloads)
    var capabilityGaps = bundle.diagnostics
      + DefaultWorkflowValidator().validate(
        workflow, nodePayloads: bundle.nodePayloads,
        addonEvidence: resolvedAddonRouteEvidence(workflow, packageManifest: bundle.packageManifest)
      )
      + (await runtimeCapabilityDiagnostics(
      bundle: bundle,
      resolution: resolution,
      resolver: resolver
      ))
    let backendRequirements: [WorkflowBackendRequirement]
    do {
      let assessment = try await workflowHostAssessment(
        bundle: bundle,
        resolution: resolution,
        resolver: resolver,
        hostResolver: hostResolver,
        host: options.host,
        strictHost: options.strictHost
      )
      backendRequirements = assessment.requirements
      capabilityGaps.append(contentsOf: assessment.diagnostics)
    } catch {
      backendRequirements = []
      capabilityGaps.append(WorkflowValidationDiagnostic(
        severity: .error,
        path: options.host == nil ? "workflow.requirements" : "workflow.host",
        message: "host requirements could not be resolved: \(error)"
      ))
    }
    return WorkflowInspectionSummary(
      workflowId: workflow.workflowId,
      sourceScope: bundle.sourceScope,
      sourceKind: workflowSourceKind(bundle),
      workflowDirectory: bundle.workflowDirectory,
      packageName: bundle.packageManifest?.name,
      packageVersion: bundle.packageManifest?.version,
      packageDirectory: bundle.packageDirectory,
      mutable: bundle.provenance == .mutable,
      provenance: CodableDefaultImmutable(wrappedValue: bundle.provenance),
      activationState: CodableDefaultActive(wrappedValue: bundle.activationState),
      description: workflow.description,
      entryStepId: workflow.entryStepId,
      managerStepId: workflow.managerStepId,
      stepIds: workflow.steps.map(\.id),
      nodeRegistryIds: workflow.nodeRegistry.map(\.id),
      crossWorkflowDispatchIds: crossWorkflowIds,
      counts: WorkflowInspectionCounts(
        steps: workflow.steps.count,
        nodes: workflow.nodeRegistry.count,
        crossWorkflowDispatches: crossWorkflowIds.count
      ),
      defaults: workflow.defaults,
      defaultMaxSteps: defaultMaxSteps(for: workflow),
      callable: callable,
      addonSourceSummaries: addonSummaries,
      nativeBundleAddons: nativeBundleAddons,
      runtimeReadinessDescriptors: readiness,
      runtimeCapabilityGaps: capabilityGaps,
      backendRequirements: backendRequirements,
      loop: buildLoopInspection(workflow)
    )
  }

  private func buildLoopInspection(_ workflow: WorkflowDefinition) -> WorkflowLoopInspectionSummary? {
    guard let loop = workflow.loop else {
      return nil
    }
    let gates = loop.gates.map { gate in
      WorkflowLoopGateInspection(
        id: gate.id,
        stepId: gate.stepId,
        required: gate.required,
        acceptDecision: gate.acceptWhen.decision,
        maxHighFindings: gate.acceptWhen.maxHighFindings,
        maxMediumFindings: gate.acceptWhen.maxMediumFindings
      )
    }
    let steps = workflow.steps.compactMap { step -> WorkflowStepLoopInspection? in
      guard let loop = step.loop else {
        return nil
      }
      return WorkflowStepLoopInspection(
        stepId: step.id,
        role: loop.role,
        gateId: loop.gateId,
        evidenceTags: loop.evidenceTags,
        recordsChangedFiles: loop.recordsChangedFiles,
        recordsVerification: loop.recordsVerification
      )
    }
    return WorkflowLoopInspectionSummary(
      kind: loop.kind,
      required: loop.required,
      description: loop.description,
      evidenceRequired: loop.evidence?.required ?? false,
      artifactRootPolicy: loop.evidence?.artifactRootPolicy,
      requiredEvidenceSections: loop.evidence?.requiredSections ?? [],
      gates: gates,
      steps: steps,
      policies: buildLoopPolicyInspection(loop.policies),
      implementationPlan: loop.implementationPlan.map {
        WorkflowLoopImplementationPlanInspection(required: $0.required, pathPattern: $0.pathPattern)
      }
    )
  }

  private func buildLoopPolicyInspection(_ policies: LoopPolicyDeclaration?) -> WorkflowLoopPolicyInspection? {
    guard let policies else {
      return nil
    }
    return WorkflowLoopPolicyInspection(
      allowedWriteRoots: policies.mutation?.allowedWriteRoots ?? [],
      scratchRoot: policies.mutation?.scratchRoot,
      commit: policies.mutation?.commit,
      push: policies.mutation?.push,
      nestedRiela: policies.process?.nestedRiela,
      nestedCodex: policies.process?.nestedCodex,
      allowedBackends: policies.process?.allowedBackends ?? [],
      requiredWorkerModel: policies.process?.requiredWorkerModel,
      networkMode: policies.network?.mode
    )
  }

  private func buildCallableInspection(
    _ workflow: WorkflowDefinition,
    nodePayloads: [String: AgentNodePayload]
  ) -> WorkflowCallableInspection {
    let stepId = workflow.managerStepId ?? workflow.entryStepId
    let step = workflow.steps.first { $0.id == stepId }
    let role = step?.role ?? (workflow.managerStepId == stepId ? .manager : .worker)
    let payload = nodePayload(for: step, stepId: stepId, nodePayloads: nodePayloads)
    return WorkflowCallableInspection(
      stepId: stepId,
      role: role,
      input: payload?.input,
      output: payload?.output
    )
  }

  private func nodePayload(
    for step: WorkflowStepRef?,
    stepId: String,
    nodePayloads: [String: AgentNodePayload]
  ) -> AgentNodePayload? {
    if let payload = nodePayloads[stepId] {
      return payload
    }
    if let nodeId = step?.nodeId, let payload = nodePayloads[nodeId] {
      return payload
    }
    return nil
  }

  private func renderStructure(_ workflow: WorkflowDefinition) -> String {
    workflow.steps.map { step in
      "\(step.id)\n  \(step.description ?? "-")"
    }.joined(separator: "\n") + "\n"
  }

  private func renderText(_ summary: WorkflowInspectionSummary) -> String {
    var lines = [
      "workflow: \(summary.workflowId)",
      "source: \(summary.sourceScope.rawValue) \(summary.sourceKind.rawValue) \(summary.provenance.rawValue) \(summary.activationState.rawValue) \(summary.workflowDirectory)",
      "entryStepId: \(summary.entryStepId)",
      "steps: \(summary.stepIds.joined(separator: ", "))",
      "nodes: \(summary.nodeRegistryIds.joined(separator: ", "))",
      "counts: steps=\(summary.counts.steps) nodes=\(summary.counts.nodes) crossWorkflowDispatches=\(summary.counts.crossWorkflowDispatches)",
      "defaultMaxSteps: \(summary.defaultMaxSteps)"
    ]
    if let manager = summary.managerStepId {
      lines.append("managerStepId: \(manager)")
    }
    if let loop = summary.loop {
      lines.append(renderLoopText(loop))
    }
    if let packageName = summary.packageName {
      lines.append("package: \(packageName) \(summary.packageVersion ?? "") \(summary.packageDirectory ?? "")")
    }
    lines.append("mutable: \(summary.mutable ? "true" : "false")")
    lines.append("callableStepId: \(summary.callable.stepId)")
    lines.append("callableRole: \(summary.callable.role.rawValue)")
    if let input = summary.callable.input {
      lines.append("callableInput: \(contractDescription(input.description))")
    }
    if let output = summary.callable.output {
      lines.append("callableOutput: \(contractDescription(output.description))")
    }
    if summary.callable.input != nil {
      lines.append("variables: --variables '{...}'")
    }
    if !summary.addonSourceSummaries.isEmpty {
      lines.append("addons: \(summary.addonSourceSummaries.joined(separator: ", "))")
    }
    if !summary.nativeBundleAddons.isEmpty {
      lines.append(contentsOf: summary.nativeBundleAddons.map {
        "nativeBundle: \($0.nodeId): \($0.addon) \($0.bundleIdentifier) abi=\($0.abiVersion) cache=\($0.cacheStatus)"
      })
    }
    lines.append(contentsOf: summary.runtimeCapabilityGaps.map {
      "\($0.severity.rawValue): \($0.path): \($0.message)"
    })
    if !summary.backendRequirements.isEmpty {
      lines.append("backendRequirements:")
      lines.append(contentsOf: summary.backendRequirements.map { requirement in
        let names = requirement.pin.map { [$0.rawValue] }
          ?? requirement.policy?.orderedCandidates().map(\.rawValue)
          ?? []
        return "- \(names.joined(separator: ",")): "
          + requirement.provenance.map { "\($0.workflowId):\($0.stepId)" }.joined(separator: ",")
      })
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private func defaultMaxSteps(for workflow: WorkflowDefinition) -> Int {
    max(1, workflow.steps.count + workflow.defaults.maxLoopIterations)
  }

  private func renderLoopText(_ loop: WorkflowLoopInspectionSummary) -> String {
    var parts = ["loop: required=\(loop.required ? "true" : "false")"]
    if let kind = loop.kind, !kind.isEmpty {
      parts.append("kind=\(kind)")
    }
    parts.append("gates=\(loop.gates.count)")
    if !loop.steps.isEmpty {
      parts.append("stepMetadata=\(loop.steps.count)")
    }
    if let artifactRootPolicy = loop.artifactRootPolicy, !artifactRootPolicy.isEmpty {
      parts.append("artifactRootPolicy=\(artifactRootPolicy)")
    }
    return parts.joined(separator: " ")
  }

  private func contractDescription(_ description: String?) -> String {
    guard let description, !description.isEmpty else {
      return "(not declared)"
    }
    return description
  }

  private func renderFailure(
    options: WorkflowInspectOptions,
    exitCode: CLIExitCode,
    error: String,
    diagnostics: [WorkflowValidationDiagnostic] = []
  ) -> CLICommandResult {
    guard options.output.isStructured else {
      return CLICommandResult(exitCode: exitCode, stderr: error)
    }
    let result = WorkflowInspectionFailureResult(
      workflowId: options.workflowName,
      sourceScope: options.resolution.scope,
      workflowDirectory: options.resolution.workflowDefinitionDir,
      diagnostics: diagnostics,
      error: error,
      exitCode: exitCode.rawValue
    )
    let stdout = (try? jsonString(result)) ?? #"{"diagnostics":[],"error":"failed to encode inspect failure","exitCode":1,"workflowId":"workflow inspect"}"# + "\n"
    return CLICommandResult(exitCode: exitCode, stdout: stdout)
  }
}
