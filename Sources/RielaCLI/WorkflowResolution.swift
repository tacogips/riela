#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RielaAddons
import RielaCore

private struct WorkflowTransactionResolutionFailure: Error, CustomStringConvertible {
  var message: String
  var description: String { message }
}

private struct WorkflowCandidateMissing: Error, CustomStringConvertible {
  var path: String
  var description: String { "\(path) not found" }
}

/// Candidate-level rejection that must be collected into the not-found error
/// list (JSON failure result) rather than escalating to a CLI usage error,
/// regardless of the requested scope.
private struct WorkflowCandidateRejected: Error, CustomStringConvertible {
  var description: String
}

public struct ResolvedWorkflowBundle: Equatable, Sendable {
  public var workflow: WorkflowDefinition
  public var nodePayloads: [String: AgentNodePayload]
  public var sourceScope: WorkflowScope
  public var workflowDirectory: String
  public var diagnostics: [WorkflowValidationDiagnostic]
  public var packageManifest: WorkflowPackageManifest?
  public var packageDirectory: String?
  public var provenance: WorkflowProvenance
  public var activationState: WorkflowActivationState
  public var originId: String?
  public var mutable: Bool { provenance == .mutable }
  var mutableRegistryDigest: String?

  public init(
    workflow: WorkflowDefinition,
    nodePayloads: [String: AgentNodePayload],
    sourceScope: WorkflowScope,
    workflowDirectory: String,
    diagnostics: [WorkflowValidationDiagnostic] = [],
    packageManifest: WorkflowPackageManifest? = nil,
    packageDirectory: String? = nil,
    provenance: WorkflowProvenance = .immutable
  ) {
    self.workflow = workflow
    self.nodePayloads = nodePayloads
    self.sourceScope = sourceScope
    self.workflowDirectory = workflowDirectory
    self.diagnostics = diagnostics
    self.packageManifest = packageManifest
    self.packageDirectory = packageDirectory
    self.provenance = provenance
    activationState = .active
    originId = nil
    mutableRegistryDigest = nil
  }
}

public protocol WorkflowBundleResolving: Sendable {
  func resolve(_ options: WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle
}

public struct FileSystemWorkflowBundleResolver: WorkflowBundleResolving {
  private let enforcesTransactionBlock: Bool
  private let capturesCatalogOriginSnapshot: Bool
  private let mutableRegistryHistoryRecoveryHook: @Sendable () throws -> Void
  private let mutableRegistry: WorkflowMutableRegistry

  public init(enforcesTransactionBlock: Bool = true) {
    self.enforcesTransactionBlock = enforcesTransactionBlock
    capturesCatalogOriginSnapshot = true
    mutableRegistryHistoryRecoveryHook = {}
    mutableRegistry = WorkflowMutableRegistry()
  }

  init(enforcesTransactionBlock: Bool = true, capturesCatalogOriginSnapshot: Bool) {
    self.enforcesTransactionBlock = enforcesTransactionBlock
    self.capturesCatalogOriginSnapshot = capturesCatalogOriginSnapshot
    mutableRegistryHistoryRecoveryHook = {}
    mutableRegistry = WorkflowMutableRegistry()
  }

  init(
    enforcesTransactionBlock: Bool = true,
    mutableRegistryHistoryRecoveryHook: @escaping @Sendable () throws -> Void,
    mutableRegistry: WorkflowMutableRegistry = WorkflowMutableRegistry(),
    capturesCatalogOriginSnapshot: Bool = true
  ) {
    self.enforcesTransactionBlock = enforcesTransactionBlock
    self.capturesCatalogOriginSnapshot = capturesCatalogOriginSnapshot
    self.mutableRegistryHistoryRecoveryHook = mutableRegistryHistoryRecoveryHook
    self.mutableRegistry = mutableRegistry
  }

  public func resolve(_ options: WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle {
    try WorkflowRegistryService(registry: mutableRegistry).withCoordinatedRead(
      workingDirectory: options.workingDirectory
    ) {
      let deactivatedOrigins = Array(try WorkflowActivationStore().snapshot().values.map(\.origin))
      let catalogOrigins = try deactivatedOrigins.isEmpty || !capturesCatalogOriginSnapshot
        ? []
        : WorkflowCatalogCommand(mutableRegistry: mutableRegistry)
          .catalogOriginIdentities(workingDirectory: options.workingDirectory)
      let activationPolicy = WorkflowSharedNodeActivationPolicy(
        catalogOrigins: catalogOrigins,
        deactivatedOrigins: deactivatedOrigins,
        includeDeactivated: options.includeDeactivated
      )
      return try resolveCoordinated(options, sharedNodeActivationPolicy: activationPolicy)
    }
  }

  private func resolveCoordinated(
    _ options: WorkflowResolutionOptions,
    sharedNodeActivationPolicy: WorkflowSharedNodeActivationPolicy
  ) throws -> ResolvedWorkflowBundle {
    let candidates = try candidateDirectories(for: options)
    if enforcesTransactionBlock {
      try refuseStableNonterminalTransactions(candidates: candidates)
    }
    var errors: [String] = []
    var deactivatedOrigins: [WorkflowOriginIdentity] = []
    var deactivatedDependencyFailure: WorkflowRegistryError?
    for candidate in candidates {
      do {
        try sharedNodeActivationPolicy.requireActiveCandidate(
          name: options.workflowName,
          directory: candidate.directory
        )
        let bundle: ResolvedWorkflowBundle
        if candidate.provenance == .mutable {
          bundle = try mutableRegistry.withWorkflowPinnedAccess(
            workflowId: options.workflowName
          ) { pinned in
            let loadResolved = {
              guard let pinned else { throw WorkflowCandidateMissing(path: candidate.directory.path) }
              guard try pinned.entryType(candidate.directory) != nil else {
                throw WorkflowCandidateMissing(path: candidate.directory.appendingPathComponent("workflow.json").path)
              }
              var resolved = try mutableRegistry.loadBundle(
                workflowId: options.workflowName,
                pinned: pinned,
                resolver: self,
                scope: candidate.scope,
                sharedNodeActivationPolicy: sharedNodeActivationPolicy
              )
              guard resolved.workflowDirectory == candidate.directory.standardizedFileURL.path else {
                throw CLIUsageError("mutable workflow detached read did not restore its configured directory identity")
              }
              if enforcesTransactionBlock {
                try mutableRegistryHistoryRecoveryHook()
                do {
                  let target = try WorkflowHistoryIdentityResolver.identity(for: resolved)
                  let authoritativeHistoryDigest = try mutableRegistry.historyBundleDigest(
                    at: candidate.directory,
                    target: target,
                    pinned: pinned
                  )
                  try refuseNonterminalHistoryTransaction(
                    bundle: resolved,
                    options: options,
                    authoritativeBundleDigest: authoritativeHistoryDigest
                  )
                } catch {
                  throw CLIUsageError("mutable workflow history recovery failed: \(error)")
                }
                do {
                  resolved = try mutableRegistry.loadBundle(
                    workflowId: options.workflowName,
                    pinned: pinned,
                    resolver: self,
                    scope: candidate.scope,
                    sharedNodeActivationPolicy: sharedNodeActivationPolicy
                  )
                } catch {
                  throw CLIUsageError("mutable workflow post-recovery reload failed: \(error)")
                }
              }
              resolved.mutableRegistryDigest = try mutableRegistry.bundleDigest(
                at: candidate.directory,
                pinned: pinned
              )
              return resolved
            }
            return try loadResolved()
          }
        } else {
          bundle = try resolveCandidate(
            candidate,
            options: options,
            sharedNodeActivationPolicy: sharedNodeActivationPolicy
          )
          if enforcesTransactionBlock {
            try refuseNonterminalHistoryTransaction(bundle: bundle, options: options)
          }
        }
        var activatedBundle = bundle
        let origin = try activationOrigin(for: bundle, candidate: candidate, options: options)
        let provenance = origin.provenance
        let activationState = try WorkflowActivationStore().state(for: origin)
        activatedBundle.provenance = provenance
        activatedBundle.activationState = activationState
        activatedBundle.originId = origin.originId
        if activationState == .deactivated, !options.includeDeactivated {
          deactivatedOrigins.append(origin)
          errors.append("\(candidate.directory.path) deactivated")
          continue
        }
        return activatedBundle
      } catch {
        if error is WorkflowTransactionResolutionFailure { throw error }
        if let missing = error as? WorkflowCandidateMissing {
          errors.append(missing.description)
          continue
        }
        if let rejected = error as? WorkflowCandidateRejected {
          errors.append(rejected.description)
          continue
        }
        if let deactivated = error as? WorkflowRegistryError,
           deactivated.code == .workflowDeactivated {
          deactivatedDependencyFailure = deactivatedDependencyFailure ?? deactivated
          errors.append(deactivated.description)
          continue
        }
        guard options.scope == .auto else {
          throw error
        }
        errors.append("\(candidate.directory.path) invalid: \(workflowResolutionErrorDescription(error))")
        continue
      }
    }
    if let deactivatedDependencyFailure {
      throw deactivatedDependencyFailure
    }
    if !deactivatedOrigins.isEmpty {
      throw WorkflowRegistryError(
        code: .workflowDeactivated,
        message: "workflow '\(options.workflowName)' has no active origin",
        workflowId: options.workflowName,
        originId: deactivatedOrigins.count == 1 ? deactivatedOrigins[0].originId : nil
      )
    }
    throw WorkflowResolutionError.notFound(options.workflowName, errors)
  }

  private func activationOrigin(
    for bundle: ResolvedWorkflowBundle,
    candidate: CandidateDirectory,
    options: WorkflowResolutionOptions
  ) throws -> WorkflowOriginIdentity {
    if bundle.sourceScope == .direct {
      let canonical = URL(fileURLWithPath: bundle.workflowDirectory, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL.path
      if let entry = try WorkflowRegistryService().list(workingDirectory: options.workingDirectory).first(where: {
        URL(fileURLWithPath: $0.workflowDirectory, isDirectory: true)
          .resolvingSymlinksInPath().standardizedFileURL.path == canonical
          && $0.workflowId == bundle.workflow.workflowId
      }) {
        return workflowOriginIdentity(
          name: entry.workflowName,
          workflowId: entry.workflowId,
          scope: entry.scope,
          sourceKind: entry.sourceKind,
          provenance: entry.provenance,
          locator: entry.workflowDirectory
        )
      }
    }
    return workflowOriginIdentity(
      name: options.workflowName,
      workflowId: bundle.workflow.workflowId,
      scope: bundle.sourceScope,
      sourceKind: workflowSourceKind(bundle),
      provenance: candidate.provenance,
      locator: bundle.workflowDirectory
    )
  }

  private func resolveCandidate(
    _ candidate: CandidateDirectory,
    options: WorkflowResolutionOptions,
    sharedNodeActivationPolicy: WorkflowSharedNodeActivationPolicy
  ) throws -> ResolvedWorkflowBundle {
    let resolvedRoot = candidate.rootDirectory.resolvingSymlinksInPath().standardizedFileURL
    let resolvedDirectory = candidate.directory.resolvingSymlinksInPath().standardizedFileURL
    guard isContained(resolvedDirectory, in: resolvedRoot) else {
      throw WorkflowCandidateRejected(description: "\(resolvedDirectory.path) escapes \(resolvedRoot.path)")
    }
    let workflowURL = resolvedDirectory.appendingPathComponent("workflow.json")
    guard FileManager.default.fileExists(atPath: workflowURL.path) else {
      throw WorkflowCandidateMissing(path: workflowURL.path)
    }
    return try loadBundle(
      at: resolvedDirectory,
      rootDirectory: candidate.rootDirectory,
      scope: candidate.scope,
      packageManifest: candidate.packageManifest,
      packageDirectory: candidate.packageDirectory,
      provenance: candidate.provenance,
      expectedWorkflowId: candidate.provenance == .mutable ? options.workflowName : nil,
      sharedNodeActivationPolicy: sharedNodeActivationPolicy
    )
  }

  private func refuseStableNonterminalTransactions(candidates: [CandidateDirectory]) throws {
    var inspected = Set<String>()
    for candidate in candidates where candidate.provenance == .immutable {
      let ownershipRoot = (candidate.packageDirectory ?? candidate.directory).standardizedFileURL
      let marker = WorkflowTransactionStableMetadata.url(forOwnershipRoot: ownershipRoot)
      guard inspected.insert(marker.path).inserted else { continue }
      guard try directoryExistsWithoutFollowingLinks(ownershipRoot.deletingLastPathComponent()) else {
        // No stable marker or canonical-target lock can exist without the
        // target parent. Missing discovery candidates are handled normally.
        continue
      }
      let provisionalTarget = WorkflowBundleIdentity(
        workflowId: candidate.directory.lastPathComponent,
        sourceScope: .direct,
        sourceKind: candidate.packageDirectory == nil ? .authoredWorkflow : .installedPackage,
        workflowDirectory: candidate.directory.path,
        ownershipRoot: ownershipRoot.path,
        packageDirectory: candidate.packageDirectory?.path,
        sourceMutable: false
      )
      try withWorkflowTargetLock(target: provisionalTarget, owner: "stable-recovery") {
        var status = stat()
        guard lstat(marker.path, &status) == 0 else {
          if errno == ENOENT { return }
          throw CLIUsageError("unable to inspect stable workflow transaction metadata")
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
          throw CLIUsageError("stable workflow transaction metadata is linked or has unexpected type")
        }
        let metadata = try WorkflowHistorySecurePersistence.readCanonical(
          WorkflowTransactionStableMetadata.self,
          from: marker,
          historyRoot: marker.deletingLastPathComponent()
        )
        guard metadata.schemaVersion == 1,
              metadata.target.ownershipRoot == ownershipRoot.path,
              metadata.historyRoot.hasPrefix("/") else {
          throw CLIUsageError("stable workflow transaction metadata does not match the requested target")
        }
        let historyRoot = URL(fileURLWithPath: metadata.historyRoot, isDirectory: true).standardizedFileURL
        do {
          guard let recovered = try WorkflowDirectoryTransactionCoordinator().recover(
            historyRoot: historyRoot,
            target: metadata.target,
            lockAlreadyHeld: true
          ),
                recovered.transactionId == metadata.transactionId,
                recovered.target == metadata.target else {
            throw CLIUsageError("stable workflow transaction metadata did not resolve to its durable transaction")
          }
        } catch {
          throw CLIUsageError("nonterminal directory transaction recovery failed: \(error)")
        }
      }
    }
  }

  private func refuseNonterminalHistoryTransaction(
    bundle: ResolvedWorkflowBundle,
    options: WorkflowResolutionOptions,
    authoritativeBundleDigest: String? = nil
  ) throws {
    guard isSafeScopedWorkflowName(bundle.workflow.workflowId) else { return }
    let base: URL
    if bundle.sourceScope == .user {
      base = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(), isDirectory: true)
    } else {
      base = URL(fileURLWithPath: options.workingDirectory, isDirectory: true)
    }
    let target = try WorkflowHistoryIdentityResolver.identity(for: bundle)
    let historyRoot = try WorkflowHistoryIdentityResolver.historyRoot(
      for: target,
      workingDirectory: base,
      configuredRoot: bundle.workflow.loop?.selfEvolution?.historyRoot
    )
    do {
      if let recovered = try WorkflowDirectoryTransactionCoordinator().recover(
        historyRoot: historyRoot,
        target: target,
        authoritativeBundleDigest: authoritativeBundleDigest
      ),
         recovered.target != target {
        throw CLIUsageError("workflow transaction recovery did not match the resolved target")
      }
    } catch {
      throw WorkflowTransactionResolutionFailure(
        message: "nonterminal directory transaction recovery failed at \(historyRoot.path): \(error)"
      )
    }
  }

  private struct CandidateDirectory {
    var directory: URL
    var rootDirectory: URL
    var scope: WorkflowScope
    var packageManifest: WorkflowPackageManifest?
    var packageDirectory: URL?
    var provenance: WorkflowProvenance

    init(
      directory: URL,
      rootDirectory: URL,
      scope: WorkflowScope,
      packageManifest: WorkflowPackageManifest? = nil,
      packageDirectory: URL? = nil,
      provenance: WorkflowProvenance = .immutable
    ) {
      self.directory = directory
      self.rootDirectory = rootDirectory
      self.scope = scope
      self.packageManifest = packageManifest
      self.packageDirectory = packageDirectory
      self.provenance = provenance
    }
  }

  private func candidateDirectories(for options: WorkflowResolutionOptions) throws -> [CandidateDirectory] {
    let workingDirectory = URL(fileURLWithPath: options.workingDirectory).standardizedFileURL
    if let workflowDefinitionDir = options.workflowDefinitionDir {
      let directRoot = absoluteURL(workflowDefinitionDir, relativeTo: workingDirectory).standardizedFileURL
      let named = directRoot.appendingPathComponent(options.workflowName)
      return [
        CandidateDirectory(directory: named.standardizedFileURL, rootDirectory: directRoot, scope: .direct),
        CandidateDirectory(directory: directRoot, rootDirectory: directRoot, scope: .direct)
      ]
    }
    let safeWorkflowName = isSafeScopedWorkflowName(options.workflowName)
    let safePackageName = WorkflowPackageManifestValidator.isSafePackageName(options.workflowName)
    guard safeWorkflowName || safePackageName else {
      throw CLIUsageError("invalid scoped workflow or package name '\(options.workflowName)'")
    }
    let project = workingDirectory
      .appendingPathComponent(".riela")
      .appendingPathComponent("workflows")
      .standardizedFileURL
    let user = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory())
      .appendingPathComponent(".riela")
      .appendingPathComponent("workflows")
      .standardizedFileURL
    let workflowCandidates: [CandidateDirectory]
    switch options.scope {
    case .project:
      workflowCandidates = safeWorkflowName
        ? [CandidateDirectory(directory: project.appendingPathComponent(options.workflowName).standardizedFileURL, rootDirectory: project, scope: .project)]
        : []
    case .user:
      workflowCandidates = safeWorkflowName
        ? [CandidateDirectory(directory: user.appendingPathComponent(options.workflowName).standardizedFileURL, rootDirectory: user, scope: .user)]
        : []
    case .auto:
      workflowCandidates = safeWorkflowName ? [
        CandidateDirectory(directory: project.appendingPathComponent(options.workflowName).standardizedFileURL, rootDirectory: project, scope: .project),
        CandidateDirectory(directory: user.appendingPathComponent(options.workflowName).standardizedFileURL, rootDirectory: user, scope: .user)
      ] : []
    case .direct:
      workflowCandidates = safeWorkflowName ? [
        CandidateDirectory(directory: project.appendingPathComponent(options.workflowName).standardizedFileURL, rootDirectory: project, scope: .project),
        CandidateDirectory(directory: user.appendingPathComponent(options.workflowName).standardizedFileURL, rootDirectory: user, scope: .user)
      ] : []
    }
    var candidates = workflowCandidates
      + (safePackageName ? try packageCandidateDirectories(for: options, workingDirectory: workingDirectory) : [])
    if safeWorkflowName, options.scope != .project {
      let mutableRoot = WorkflowMutableRegistry().root
      candidates.append(CandidateDirectory(
        directory: mutableRoot.appendingPathComponent(options.workflowName, isDirectory: true),
        rootDirectory: mutableRoot,
        scope: .user,
        provenance: .mutable
      ))
    }
    return candidates
  }

  private func packageCandidateDirectories(
    for options: WorkflowResolutionOptions,
    workingDirectory: URL
  ) throws -> [CandidateDirectory] {
    var candidates: [CandidateDirectory] = []
    for (scope, root) in packageRoots(scope: options.scope, workingDirectory: workingDirectory) {
      let packageDirectory = root.appendingPathComponent(options.workflowName, isDirectory: true).standardizedFileURL
      guard isContained(packageDirectory, in: root) else {
        continue
      }
      let manifestURL = packageDirectory.appendingPathComponent("riela-package.json")
      guard FileManager.default.fileExists(atPath: manifestURL.path) else {
        continue
      }
      let manifest = try JSONDecoder().decode(WorkflowPackageManifest.self, from: Data(contentsOf: manifestURL))
      guard manifest.kind == .workflow else {
        continue
      }
      let issues = WorkflowPackageManifestValidator.validate(manifest)
        + WorkflowPackageManifestValidator.validateWorkflowBundle(manifest, packageRoot: packageDirectory)
      guard issues.isEmpty else {
        throw CLIUsageError("package source validation failed: \(issues.map { "\($0.path): \($0.message)" }.joined(separator: "; "))")
      }
      guard let workflowDirectory = WorkflowPackageManifestValidator.normalizePackageRelativePath(manifest.workflowDirectory ?? ".") else {
        throw CLIUsageError("package workflowDirectory must be package-relative")
      }
      let resolvedWorkflowDirectory = packageDirectory.appendingPathComponent(workflowDirectory, isDirectory: true).standardizedFileURL
      guard isContained(resolvedWorkflowDirectory.resolvingSymlinksInPath(), in: packageDirectory.resolvingSymlinksInPath()) else {
        throw CLIUsageError("package workflowDirectory escapes package root: \(manifest.workflowDirectory ?? ".")")
      }
      candidates.append(CandidateDirectory(
        directory: resolvedWorkflowDirectory,
        rootDirectory: resolvedWorkflowDirectory.deletingLastPathComponent(),
        scope: scope,
        packageManifest: manifest,
        packageDirectory: packageDirectory
      ))
    }
    return candidates
  }

  private func packageRoots(scope: WorkflowScope, workingDirectory: URL) -> [(WorkflowScope, URL)] {
    let project = workingDirectory.appendingPathComponent(".riela/packages", isDirectory: true).standardizedFileURL
    let user = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory())
      .appendingPathComponent(".riela/packages", isDirectory: true)
      .standardizedFileURL
    switch scope {
    case .project:
      return [(.project, project)]
    case .user:
      return [(.user, user)]
    case .auto, .direct:
      return [(.project, project), (.user, user)]
    }
  }

  func isContained(_ directory: URL, in root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.path
    let directoryPath = directory.standardizedFileURL.path
    return directoryPath == rootPath || directoryPath.hasPrefix(rootPath + "/")
  }

  func loadBundle(
    at directory: URL,
    rootDirectory: URL,
    scope: WorkflowScope,
    packageManifest providedPackageManifest: WorkflowPackageManifest? = nil,
    packageDirectory: URL? = nil,
    provenance: WorkflowProvenance = .immutable,
    expectedWorkflowId: String? = nil,
    sharedNodeActivationPolicy: WorkflowSharedNodeActivationPolicy = .includeDeactivated,
    sharedNodeActivationRootDirectory: URL? = nil
  ) throws -> ResolvedWorkflowBundle {
    let workflowURL = try containedFile(
      directory.appendingPathComponent("workflow.json"),
      in: directory,
      scope: scope,
      label: "workflow.json"
    )
    let workflowData = try Data(contentsOf: workflowURL)
    let validation = validateAuthoredWorkflowData(workflowData)
    guard var workflow = validation.workflow else {
      throw WorkflowResolutionError.invalidWorkflow(validation.diagnostics)
    }
    if let expectedWorkflowId, workflow.workflowId != expectedWorkflowId {
      throw CLIUsageError(
        "mutable workflow registry key '\(expectedWorkflowId)' does not match decoded workflowId '\(workflow.workflowId)'"
      )
    }
    var nodePayloads: [String: AgentNodePayload] = [:]
    let promptTemplateLoader = PromptTemplateAssetLoader()
    for registryNode in workflow.nodeRegistry {
      guard let nodeFile = registryNode.nodeFile else {
        continue
      }
      let payloadURL = try containedFile(
        directory.appendingPathComponent(nodeFile),
        in: directory,
        scope: scope,
        label: "nodeFile \(nodeFile)"
      )
      let data = try Data(contentsOf: payloadURL)
      let payload = try JSONDecoder().decode(AgentNodePayload.self, from: data)
      let hydratedPayload: AgentNodePayload
      do {
        hydratedPayload = try promptTemplateLoader.hydrate(payload, workflowDirectory: directory)
      } catch let error as PromptTemplateAssetLoadingError {
        throw WorkflowResolutionError.invalidWorkflow([error.diagnostic])
      }
      nodePayloads[registryNode.id] = absolutizedStdioPaths(in: hydratedPayload, workflowDirectory: directory)
    }
    let materialized = try materializeSharedNodeReferences(
      in: workflow,
      nodePayloads: nodePayloads,
      rootDirectory: rootDirectory,
      activationRootDirectory: sharedNodeActivationRootDirectory ?? rootDirectory,
      scope: scope,
      provenance: provenance,
      promptTemplateLoader: promptTemplateLoader,
      activationPolicy: sharedNodeActivationPolicy
    )
    workflow = materialized.workflow
    nodePayloads = materialized.nodePayloads
    let providerDiagnostics = nodePayloads.keys.sorted().flatMap { nodeId in
      nodePayloads[nodeId].map { validateAgentNodePayload($0, path: "nodes.\(nodeId)") } ?? []
    }
    if providerDiagnostics.contains(where: { $0.severity == .error }) {
      throw WorkflowResolutionError.invalidWorkflow(providerDiagnostics)
    }
    let packageManifest: WorkflowPackageManifest?
    let resolvedPackageDirectory: String?
    if provenance == .mutable {
      packageManifest = nil
      resolvedPackageDirectory = nil
    } else {
      packageManifest = try providedPackageManifest ?? loadPackageManifestIfPresent(at: directory)
      resolvedPackageDirectory = packageDirectory?.path ?? (packageManifest == nil ? nil : directory.path)
    }
    return ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: nodePayloads,
      sourceScope: scope,
      workflowDirectory: directory.path,
      diagnostics: validation.diagnostics + providerDiagnostics,
      packageManifest: packageManifest,
      packageDirectory: resolvedPackageDirectory,
      provenance: provenance
    )
  }

  func absolutizedStdioPaths(in payload: AgentNodePayload, workflowDirectory: URL) -> AgentNodePayload {
    var payload = payload
    if var command = payload.command {
      command.executable = absoluteCommandPath(command.executable, relativeTo: workflowDirectory)
      if let workingDirectory = command.workingDirectory {
        command.workingDirectory = absoluteCommandPath(workingDirectory, relativeTo: workflowDirectory)
      }
      payload.command = command
    }
    if var container = payload.container, let workingDirectory = container.workingDirectory {
      container.workingDirectory = absoluteCommandPath(workingDirectory, relativeTo: workflowDirectory)
      payload.container = container
    }
    return payload
  }

  private func absoluteCommandPath(_ path: String, relativeTo workflowDirectory: URL) -> String {
    guard !path.hasPrefix("/") && !path.hasPrefix("./") else {
      return path
    }
    return workflowDirectory.appendingPathComponent(path).path
  }

  private func loadPackageManifestIfPresent(at directory: URL) throws -> WorkflowPackageManifest? {
    let manifestURL = directory.appendingPathComponent("riela-package.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      return nil
    }
    return try JSONDecoder().decode(WorkflowPackageManifest.self, from: Data(contentsOf: manifestURL))
  }

  func containedFile(_ file: URL, in directory: URL, scope: WorkflowScope, label: String) throws -> URL {
    let resolvedFile = file.resolvingSymlinksInPath().standardizedFileURL
    guard scope == .direct || isContained(resolvedFile, in: directory) else {
      throw WorkflowResolutionError.invalidJSONReference("\(label) \(resolvedFile.path) escapes \(directory.path)")
    }
    return resolvedFile
  }
}

public enum WorkflowResolutionError: Error, Equatable, Sendable {
  case notFound(String, [String])
  case invalidWorkflow([WorkflowValidationDiagnostic])
  case invalidJSONReference(String)
}

func workflowResolutionErrorDescription(_ error: Error) -> String {
  switch error {
  case let error as WorkflowResolutionError:
    switch error {
    case let .notFound(name, reasons):
      return "workflow '\(name)' not found: \(reasons.joined(separator: "; "))"
    case let .invalidWorkflow(diagnostics):
      return diagnostics.map { "\($0.path): \($0.message)" }.joined(separator: "; ")
    case let .invalidJSONReference(message):
      return message
    }
  case let error as CLIUsageError:
    return error.message
  default:
    return "\(error)"
  }
}

public protocol WorkflowNodePatchApplying: Sendable {
  func applyNodePatch(_ patch: JSONObject, to nodePayloads: [String: AgentNodePayload]) throws -> [String: AgentNodePayload]
}

public struct DefaultWorkflowNodePatchApplier: WorkflowNodePatchApplying {
  public init() {}

  public func applyNodePatch(_ patch: JSONObject, to nodePayloads: [String: AgentNodePayload]) throws -> [String: AgentNodePayload] {
    do {
      let patches = try WorkflowInstanceResolver.nodePatches(from: patch)
      return try WorkflowInstanceResolver.applyNodePatches(patches, to: nodePayloads)
    } catch let error as WorkflowInstanceResolutionError {
      throw NodePatchError(error)
    }
  }
}

public enum NodePatchError: Error, Equatable, Sendable {
  case nodePatchMustBeObject(String)
  case unknownNodeId(String)
  case unsupportedField(String)
  case invalidFieldValue(String)
  case modelChangeFrozen(String)

  init(_ error: WorkflowInstanceResolutionError) {
    switch error {
    case let .nodePatchMustBeObject(nodeId):
      self = .nodePatchMustBeObject(nodeId)
    case let .unknownNodeId(nodeId):
      self = .unknownNodeId(nodeId)
    case let .unsupportedField(field):
      self = .unsupportedField(field)
    case let .invalidFieldValue(field):
      self = .invalidFieldValue(field)
    case let .modelChangeFrozen(nodeId):
      self = .modelChangeFrozen(nodeId)
    }
  }
}

public struct JSONReferenceLoader: Sendable {
  public init() {}

  public func object(from reference: String, workingDirectory: String = FileManager.default.currentDirectoryPath) throws -> JSONObject {
    let value = try value(from: reference, workingDirectory: workingDirectory)
    guard case let .object(object) = value else {
      throw WorkflowResolutionError.invalidJSONReference("expected top-level JSON object")
    }
    return object
  }

  public func value(from reference: String, workingDirectory: String = FileManager.default.currentDirectoryPath) throws -> JSONValue {
    let text: String
    if reference.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
      text = reference
    } else {
      let rawPath = reference.hasPrefix("@") ? String(reference.dropFirst()) : reference
      let url = absoluteURL(rawPath, relativeTo: URL(fileURLWithPath: workingDirectory))
      text = try String(contentsOf: url, encoding: .utf8)
    }
    guard let data = text.data(using: .utf8) else {
      throw WorkflowResolutionError.invalidJSONReference("JSON reference is not UTF-8")
    }
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }
}

func absoluteURL(_ rawPath: String, relativeTo directory: URL) -> URL {
  if rawPath.hasPrefix("/") {
    return URL(fileURLWithPath: rawPath).standardizedFileURL
  }
  return directory.standardizedFileURL.appendingPathComponent(rawPath).standardizedFileURL
}

public extension JSONValue {
  var stringValue: String? {
    if case let .string(value) = self {
      return value
    }
    return nil
  }
}
