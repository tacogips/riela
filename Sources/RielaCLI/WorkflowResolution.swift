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
  public init() {}

  public func resolve(_ options: WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle {
    let candidates = try candidateDirectories(for: options)
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
      return try loadBundle(
        at: resolvedDirectory,
        scope: candidate.scope,
        packageManifest: candidate.packageManifest,
        packageDirectory: candidate.packageDirectory
      )
    }
    throw WorkflowResolutionError.notFound(options.workflowName, errors)
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
        rootDirectory: packageDirectory,
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

  private func isContained(_ directory: URL, in root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.path
    let directoryPath = directory.standardizedFileURL.path
    return directoryPath == rootPath || directoryPath.hasPrefix(rootPath + "/")
  }

  private func loadBundle(
    at directory: URL,
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
    guard let workflow = validation.workflow else {
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

  private func absolutizedStdioPaths(in payload: AgentNodePayload, workflowDirectory: URL) -> AgentNodePayload {
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

  private func containedFile(_ file: URL, in directory: URL, scope: WorkflowScope, label: String) throws -> URL {
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

public protocol WorkflowNodePatchApplying: Sendable {
  func applyNodePatch(_ patch: JSONObject, to nodePayloads: [String: AgentNodePayload]) throws -> [String: AgentNodePayload]
}

public struct DefaultWorkflowNodePatchApplier: WorkflowNodePatchApplying {
  public init() {}

  public func applyNodePatch(_ patch: JSONObject, to nodePayloads: [String: AgentNodePayload]) throws -> [String: AgentNodePayload] {
    var patched = nodePayloads
    for key in patch.keys.sorted() {
      guard case let .object(nodePatch)? = patch[key] else {
        throw NodePatchError.nodePatchMustBeObject(key)
      }
      guard var payload = patched[key] else {
        throw NodePatchError.unknownNodeId(key)
      }
      for field in nodePatch.keys.sorted() {
        guard Set(["executionBackend", "model", "effort"]).contains(field) else {
          throw NodePatchError.unsupportedField(field)
        }
        switch field {
        case "executionBackend":
          guard let raw = nodePatch[field]?.stringValue, let backend = NodeExecutionBackend(rawValue: raw) else {
            throw NodePatchError.invalidFieldValue(field)
          }
          payload.executionBackend = backend
        case "model":
          guard let model = nodePatch[field]?.stringValue, !model.isEmpty else {
            throw NodePatchError.invalidFieldValue(field)
          }
          payload.model = model
        case "effort":
          guard let raw = nodePatch[field]?.stringValue, let effort = NodeReasoningEffort(rawValue: raw) else {
            throw NodePatchError.invalidFieldValue(field)
          }
          payload.effort = effort
        default:
          break
        }
      }
      patched[key] = payload
    }
    return patched
  }
}

public enum NodePatchError: Error, Equatable, Sendable {
  case nodePatchMustBeObject(String)
  case unknownNodeId(String)
  case unsupportedField(String)
  case invalidFieldValue(String)
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
  let url = URL(fileURLWithPath: rawPath)
  return url.path.hasPrefix("/") ? url.standardizedFileURL : directory.appendingPathComponent(rawPath).standardizedFileURL
}

public extension JSONValue {
  var stringValue: String? {
    if case let .string(value) = self {
      return value
    }
    return nil
  }
}
