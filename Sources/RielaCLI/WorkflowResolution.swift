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

public struct ResolvedWorkflowBundle: Equatable, Sendable {
  public var workflow: WorkflowDefinition
  public var nodePayloads: [String: AgentNodePayload]
  public var sourceScope: WorkflowScope
  public var workflowDirectory: String
  public var diagnostics: [WorkflowValidationDiagnostic]
  public var packageManifest: WorkflowPackageManifest?
  public var packageDirectory: String?

  public init(
    workflow: WorkflowDefinition,
    nodePayloads: [String: AgentNodePayload],
    sourceScope: WorkflowScope,
    workflowDirectory: String,
    diagnostics: [WorkflowValidationDiagnostic] = [],
    packageManifest: WorkflowPackageManifest? = nil,
    packageDirectory: String? = nil
  ) {
    self.workflow = workflow
    self.nodePayloads = nodePayloads
    self.sourceScope = sourceScope
    self.workflowDirectory = workflowDirectory
    self.diagnostics = diagnostics
    self.packageManifest = packageManifest
    self.packageDirectory = packageDirectory
  }
}

public protocol WorkflowBundleResolving: Sendable {
  func resolve(_ options: WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle
}

public struct FileSystemWorkflowBundleResolver: WorkflowBundleResolving {
  private let enforcesTransactionBlock: Bool

  public init(enforcesTransactionBlock: Bool = true) {
    self.enforcesTransactionBlock = enforcesTransactionBlock
  }

  public func resolve(_ options: WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle {
    let candidates = try candidateDirectories(for: options)
    if enforcesTransactionBlock {
      try refuseStableNonterminalTransactions(candidates: candidates)
    }
    var errors: [String] = []
    for candidate in candidates {
      let resolvedRoot = candidate.rootDirectory.resolvingSymlinksInPath().standardizedFileURL
      let resolvedDirectory = candidate.directory.resolvingSymlinksInPath().standardizedFileURL
      guard isContained(resolvedDirectory, in: resolvedRoot) else {
        errors.append("\(resolvedDirectory.path) escapes \(resolvedRoot.path)")
        continue
      }
      let workflowURL = resolvedDirectory.appendingPathComponent("workflow.json")
      guard FileManager.default.fileExists(atPath: workflowURL.path) else {
        errors.append("\(workflowURL.path) not found")
        continue
      }
      do {
        let bundle = try loadBundle(
          at: resolvedDirectory,
          rootDirectory: candidate.rootDirectory,
          scope: candidate.scope,
          packageManifest: candidate.packageManifest,
          packageDirectory: candidate.packageDirectory
        )
        if enforcesTransactionBlock {
          try refuseNonterminalHistoryTransaction(bundle: bundle, options: options)
        }
        return bundle
      } catch {
        if error is WorkflowTransactionResolutionFailure { throw error }
        guard options.scope == .auto else {
          throw error
        }
        errors.append("\(resolvedDirectory.path) invalid: \(workflowResolutionErrorDescription(error))")
        continue
      }
    }
    throw WorkflowResolutionError.notFound(options.workflowName, errors)
  }

  private func refuseStableNonterminalTransactions(candidates: [CandidateDirectory]) throws {
    var inspected = Set<String>()
    for candidate in candidates {
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
        sourceMutable: candidate.packageDirectory == nil
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
    options: WorkflowResolutionOptions
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
      if let recovered = try WorkflowDirectoryTransactionCoordinator().recover(historyRoot: historyRoot, target: target),
         recovered.target != target {
        throw CLIUsageError("workflow transaction recovery did not match the resolved target")
      }
    } catch {
      throw WorkflowTransactionResolutionFailure(
        message: "nonterminal directory transaction recovery failed: \(error)"
      )
    }
  }

  private struct CandidateDirectory {
    var directory: URL
    var rootDirectory: URL
    var scope: WorkflowScope
    var packageManifest: WorkflowPackageManifest?
    var packageDirectory: URL?

    init(
      directory: URL,
      rootDirectory: URL,
      scope: WorkflowScope,
      packageManifest: WorkflowPackageManifest? = nil,
      packageDirectory: URL? = nil
    ) {
      self.directory = directory
      self.rootDirectory = rootDirectory
      self.scope = scope
      self.packageManifest = packageManifest
      self.packageDirectory = packageDirectory
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
    return workflowCandidates + (safePackageName ? try packageCandidateDirectories(for: options, workingDirectory: workingDirectory) : [])
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

  private func loadBundle(
    at directory: URL,
    rootDirectory: URL,
    scope: WorkflowScope,
    packageManifest providedPackageManifest: WorkflowPackageManifest? = nil,
    packageDirectory: URL? = nil
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
      scope: scope,
      promptTemplateLoader: promptTemplateLoader
    )
    workflow = materialized.workflow
    nodePayloads = materialized.nodePayloads
    let packageManifest = try providedPackageManifest ?? loadPackageManifestIfPresent(at: directory)
    let resolvedPackageDirectory = packageDirectory?.path ?? (packageManifest == nil ? nil : directory.path)
    return ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: nodePayloads,
      sourceScope: scope,
      workflowDirectory: directory.path,
      diagnostics: validation.diagnostics,
      packageManifest: packageManifest,
      packageDirectory: resolvedPackageDirectory
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
