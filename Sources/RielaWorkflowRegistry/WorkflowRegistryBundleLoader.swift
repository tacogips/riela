import Foundation
import RielaAddons
import RielaCore

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
  public var mutableRegistryDigest: String?

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

public struct WorkflowResolutionOptions: Codable, Equatable, Sendable {
  public var workflowName: String
  public var scope: WorkflowScope
  public var workflowDefinitionDir: String?
  public var workingDirectory: String
  public var includeDeactivated: Bool

  public init(
    workflowName: String,
    scope: WorkflowScope = .auto,
    workflowDefinitionDir: String? = nil,
    workingDirectory: String = FileManager.default.currentDirectoryPath,
    includeDeactivated: Bool = false
  ) {
    self.workflowName = workflowName
    self.scope = workflowDefinitionDir == nil ? scope : .direct
    self.workflowDefinitionDir = workflowDefinitionDir
    self.workingDirectory = workingDirectory
    self.includeDeactivated = includeDeactivated
  }
}

public enum WorkflowResolutionError: Error, Equatable, Sendable {
  case notFound(String, [String])
  case invalidWorkflow([WorkflowValidationDiagnostic])
  case invalidJSONReference(String)
}

public struct WorkflowRegistryBundleLoader: Sendable {
  public init() {}

  public func loadBundle(
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
    let validation = validateAuthoredWorkflowData(try Data(contentsOf: workflowURL))
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
      guard let nodeFile = registryNode.nodeFile else { continue }
      let payloadURL = try containedFile(
        directory.appendingPathComponent(nodeFile),
        in: directory,
        scope: scope,
        label: "nodeFile \(nodeFile)"
      )
      let payload = try JSONDecoder().decode(AgentNodePayload.self, from: Data(contentsOf: payloadURL))
      let hydratedPayload: AgentNodePayload
      do {
        hydratedPayload = try promptTemplateLoader.hydrate(payload, workflowDirectory: directory)
      } catch let error as PromptTemplateAssetLoadingError {
        throw WorkflowResolutionError.invalidWorkflow([error.diagnostic])
      }
      nodePayloads[registryNode.id] = absolutizedStdioPaths(
        in: hydratedPayload,
        workflowDirectory: directory
      )
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

  func isContained(_ directory: URL, in root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.path
    let directoryPath = directory.standardizedFileURL.path
    return directoryPath == rootPath || directoryPath.hasPrefix(rootPath + "/")
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

  func containedFile(_ file: URL, in directory: URL, scope: WorkflowScope, label: String) throws -> URL {
    let resolvedFile = file.resolvingSymlinksInPath().standardizedFileURL
    guard scope == .direct || isContained(resolvedFile, in: directory) else {
      throw WorkflowResolutionError.invalidJSONReference("\(label) \(resolvedFile.path) escapes \(directory.path)")
    }
    return resolvedFile
  }

  private func absoluteCommandPath(_ path: String, relativeTo workflowDirectory: URL) -> String {
    guard !path.hasPrefix("/") && !path.hasPrefix("./") else { return path }
    return workflowDirectory.appendingPathComponent(path).path
  }

  private func loadPackageManifestIfPresent(at directory: URL) throws -> WorkflowPackageManifest? {
    let manifestURL = directory.appendingPathComponent("riela-package.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
    return try JSONDecoder().decode(WorkflowPackageManifest.self, from: Data(contentsOf: manifestURL))
  }
}
