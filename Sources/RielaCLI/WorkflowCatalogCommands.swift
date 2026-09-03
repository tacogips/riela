import Foundation
import ArgumentParser
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaAdapters
import RielaAddons
import RielaCore

public struct WorkflowManifestValidationCommandResult: Codable, Equatable, Sendable {
  public var manifestPath: String
  public var valid: Bool
  public var issues: [WorkflowPackageValidationIssue]
  public var executablePreflight: Bool
}

public struct WorkflowCatalogResult: Codable, Equatable, Sendable {
  public var workflows: [WorkflowCatalogEntry]
}

func workflowSourceKind(_ bundle: ResolvedWorkflowBundle) -> WorkflowSourceKind {
  bundle.packageManifest == nil ? .workflow : .package
}

public struct WorkflowManifestValidateCommand: Sendable {
  public var loader: any WorkflowPackageManifestLoading

  public init(loader: any WorkflowPackageManifestLoading = FileWorkflowPackageManifestLoader()) {
    self.loader = loader
  }

  public func run(_ options: WorkflowManifestValidateOptions) async -> CLICommandResult {
    do {
      let workingDirectory = URL(fileURLWithPath: options.workingDirectory, isDirectory: true)
      let manifestURL = absoluteURL(options.manifestPath, relativeTo: workingDirectory)
      let manifest = try await loader.loadManifest(from: manifestURL)
      let issues = await loader.validate(manifest, packageRoot: manifestURL.deletingLastPathComponent())
      let result = WorkflowManifestValidationCommandResult(
        manifestPath: manifestURL.path,
        valid: issues.isEmpty,
        issues: issues,
        executablePreflight: options.executable
      )
      return CLICommandResult(
        exitCode: result.valid ? .success : .usage,
        stdout: try render(result, output: options.output)
      )
    } catch {
      if options.output.isStructured {
        let result = WorkflowManifestValidationCommandResult(
          manifestPath: options.manifestPath,
          valid: false,
          issues: [
            WorkflowPackageValidationIssue(
              code: "INVALID_MANIFEST",
              path: options.manifestPath,
              message: "\(error)"
            )
          ],
          executablePreflight: options.executable
        )
        return CLICommandResult(exitCode: .failure, stdout: (try? jsonString(result)) ?? "")
      }
      return CLICommandResult(exitCode: .failure, stderr: "workflow manifest validation failed: \(error)")
    }
  }

  private func render(_ result: WorkflowManifestValidationCommandResult, output: WorkflowOutputFormat) throws -> String {
    switch output {
    case .json, .jsonl:
      return try jsonString(result)
    case .text, .table:
      var lines = [
        result.valid ? "valid: \(result.manifestPath)" : "invalid: \(result.manifestPath)"
      ]
      lines.append(contentsOf: result.issues.map { "\($0.code): \($0.path): \($0.message)" })
      return lines.joined(separator: "\n") + "\n"
    }
  }
}

public struct WorkflowCatalogCommand: Sendable {
  private var mutableRegistry: WorkflowMutableRegistry

  public init() {
    mutableRegistry = WorkflowMutableRegistry()
  }

  init(mutableRegistry: WorkflowMutableRegistry) {
    self.mutableRegistry = mutableRegistry
  }

  public func list(_ options: CLICommandOptions) -> CLICommandResult {
    do {
      let entries = try catalogEntries(options: options)
      return CLICommandResult(exitCode: .success, stdout: try render(WorkflowCatalogResult(workflows: entries), output: options.output))
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  public func status(_ options: CLICommandOptions) -> CLICommandResult {
    guard let target = options.target, !target.isEmpty else {
      return CLICommandResult(exitCode: .usage, stderr: "workflow name is required for workflow status")
    }
    do {
      let parsed = try catalogParseOptions(options)
      let resolution = WorkflowResolutionOptions(
        workflowName: target,
        scope: parsed.scope,
        workflowDefinitionDir: nil,
        workingDirectory: parsed.workingDirectory,
        includeDeactivated: true
      )
      let bundle = try FileSystemWorkflowBundleResolver().resolve(resolution)
      let diagnostics = bundle.diagnostics
        + DefaultWorkflowValidator().validate(bundle.workflow, nodePayloads: bundle.nodePayloads)
      let entry = WorkflowCatalogEntry(
        workflowName: target,
        workflowId: bundle.workflow.workflowId,
        description: bundle.workflow.description,
        scope: bundle.sourceScope,
        sourceKind: workflowSourceKind(bundle),
        workflowDirectory: bundle.workflowDirectory,
        packageName: bundle.packageManifest?.name,
        packageVersion: bundle.packageManifest?.version,
        packageDirectory: bundle.packageDirectory,
        provenance: bundle.provenance,
        valid: !diagnostics.contains { $0.severity == .error },
        diagnostics: diagnostics
      )
      let activatedEntry = try applyingActivation(to: entry)
      return CLICommandResult(
        exitCode: activatedEntry.valid ? .success : .failure,
        stdout: try render(WorkflowCatalogResult(workflows: [activatedEntry]), output: options.output)
      )
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  private struct ParsedCatalogArguments: RielaClientFamilyArguments {
    @Option var scope = "auto"
    @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
    var workingDirectory = FileManager.default.currentDirectoryPath
    @Option var output: String?
    @Flag var excludeMutable = false
    @Option var activation: String?
    @Option var provenance: String?
    @Option var description: String?
  }

  private struct ParsedCatalogOptions {
    var scope: WorkflowScope
    var workingDirectory: String
    var excludeMutable: Bool
    var activation: WorkflowActivationState?
    var provenance: WorkflowProvenance?
    var description: String?
  }

  func catalogEntries(options: CLICommandOptions) throws -> [WorkflowCatalogEntry] {
    if let query = options.target, query.isEmpty {
      throw CLIUsageError("query must not be empty")
    }
    let parsed = try catalogParseOptions(options)
    return try WorkflowRegistryService(registry: mutableRegistry).list(
      filter: WorkflowRegistryFilter(
        query: options.target,
        description: parsed.description,
        scope: WorkflowRegistryScope(rawValue: parsed.scope.rawValue),
        provenance: parsed.provenance,
        mutable: parsed.excludeMutable ? false : nil,
        activationState: parsed.activation
      ),
      workingDirectory: parsed.workingDirectory
    )
  }

  func catalogOriginIdentities(workingDirectory: String) throws -> [WorkflowOriginIdentity] {
    try WorkflowRegistryService(registry: mutableRegistry).list(workingDirectory: workingDirectory).map {
      workflowOriginIdentity(
        name: $0.workflowName,
        workflowId: $0.workflowId,
        scope: $0.scope,
        sourceKind: $0.sourceKind,
        provenance: $0.provenance,
        locator: $0.workflowDirectory
      )
    }
  }

  private func authoredWorkflowOrigin(
    name: String,
    directory: URL,
    scope: WorkflowScope,
    sourceKind: WorkflowSourceKind = .workflow,
    provenance: WorkflowProvenance = .immutable
  ) -> WorkflowOriginIdentity? {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("workflow.json")),
          let workflow = validateAuthoredWorkflowData(data).workflow else {
      return nil
    }
    return workflowOriginIdentity(
      name: name,
      workflowId: workflow.workflowId,
      scope: scope,
      sourceKind: sourceKind,
      provenance: provenance,
      locator: directory.path
    )
  }

  private func packageOriginIdentities(workingDirectory: String) -> [WorkflowOriginIdentity] {
    packageRoots(scope: .auto, workingDirectory: workingDirectory).flatMap { scope, root in
      ((try? packageManifestURLs(in: root)) ?? []).compactMap { manifestURL in
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(WorkflowPackageManifest.self, from: manifestData),
              manifest.kind == .workflow else {
          return nil
        }
        let packageDirectory = manifestURL.deletingLastPathComponent().standardizedFileURL
        let workflowDirectory: URL
        if let normalized = WorkflowPackageManifestValidator.normalizePackageRelativePath(
          manifest.workflowDirectory ?? "."
        ) {
          workflowDirectory = packageDirectory
            .appendingPathComponent(normalized, isDirectory: true)
            .standardizedFileURL
        } else {
          workflowDirectory = packageDirectory
        }
        return authoredWorkflowOrigin(
          name: manifest.name,
          directory: workflowDirectory,
          scope: scope,
          sourceKind: .package
        )
      }
    }
  }

  private func catalogEntriesCoordinated(
    options: CLICommandOptions,
    parsed: ParsedCatalogOptions
  ) throws -> [WorkflowCatalogEntry] {
    if options.target == "" {
      throw CLIUsageError("workflow list query must not be empty")
    }
    let roots = workflowRoots(scope: parsed.scope, workingDirectory: parsed.workingDirectory)
    var entries: [WorkflowCatalogEntry] = []
    for (scope, root) in roots {
      let names = try workflowNames(in: root)
      for name in names {
        let resolution = WorkflowResolutionOptions(
          workflowName: name,
          scope: scope,
          workingDirectory: parsed.workingDirectory,
          includeDeactivated: true
        )
        do {
          let bundle = try FileSystemWorkflowBundleResolver(
            capturesCatalogOriginSnapshot: false
          ).resolve(resolution)
          let diagnostics = bundle.diagnostics
            + DefaultWorkflowValidator().validate(bundle.workflow, nodePayloads: bundle.nodePayloads)
          entries.append(WorkflowCatalogEntry(
            workflowName: name,
            workflowId: bundle.workflow.workflowId,
            description: bundle.workflow.description,
            scope: bundle.sourceScope,
            sourceKind: workflowSourceKind(bundle),
            workflowDirectory: bundle.workflowDirectory,
            packageName: bundle.packageManifest?.name,
            packageVersion: bundle.packageManifest?.version,
            packageDirectory: bundle.packageDirectory,
            provenance: bundle.provenance,
            valid: !diagnostics.contains { $0.severity == .error },
            diagnostics: diagnostics
          ))
        } catch {
          entries.append(WorkflowCatalogEntry(
            workflowName: name,
            scope: scope,
            sourceKind: .workflow,
            workflowDirectory: root.appendingPathComponent(name).path,
            provenance: .immutable,
            valid: false,
            diagnostics: [
              WorkflowValidationDiagnostic(severity: .error, path: "workflow.json", message: "\(error)")
            ]
          ))
        }
      }
    }
    entries.append(contentsOf: try packageCatalogEntries(options: parsed))
    if parsed.scope != .project {
      entries.append(contentsOf: try WorkflowRegistryService().list(
        filter: WorkflowRegistryFilter(scope: .user, mutable: true),
        workingDirectory: parsed.workingDirectory
      ))
    }
    entries = try entries.map(applyingActivation)
    if parsed.excludeMutable {
      entries.removeAll { $0.provenance == .mutable }
    }
    if let activation = parsed.activation {
      entries.removeAll { $0.activationState != activation }
    }
    if let provenance = parsed.provenance {
      entries.removeAll { $0.provenance != provenance }
    }
    if let description = parsed.description?.lowercased(), !description.isEmpty {
      entries.removeAll { !($0.description?.lowercased().contains(description) ?? false) }
    }
    if let query = options.target {
      entries = entries.filter { Self.matchesQuery($0, query: query) }
    }
    return entries.sorted { left, right in
      if left.scope.rawValue != right.scope.rawValue {
        return left.scope.rawValue < right.scope.rawValue
      }
      if left.workflowName != right.workflowName {
        return left.workflowName < right.workflowName
      }
      return left.sourceKind.rawValue < right.sourceKind.rawValue
    }
  }

  static func matchesQuery(_ entry: WorkflowCatalogEntry, query: String) -> Bool {
    let needle = query.lowercased()
    return entry.workflowName.lowercased().contains(needle)
      || entry.workflowId.lowercased().contains(needle)
      || (entry.description?.lowercased().contains(needle) ?? false)
      || (entry.packageName?.lowercased().contains(needle) ?? false)
  }

  private func packageCatalogEntries(options: ParsedCatalogOptions) throws -> [WorkflowCatalogEntry] {
    var entries: [WorkflowCatalogEntry] = []
    for (scope, root) in packageRoots(scope: options.scope, workingDirectory: options.workingDirectory) {
      guard FileManager.default.fileExists(atPath: root.path) else {
        continue
      }
      for manifestURL in try packageManifestURLs(in: root) {
        let packageDirectory = manifestURL.deletingLastPathComponent().standardizedFileURL
        do {
          let manifest = try JSONDecoder().decode(WorkflowPackageManifest.self, from: Data(contentsOf: manifestURL))
          guard manifest.kind == .workflow else {
            continue
          }
          let issues = WorkflowPackageManifestValidator.validate(manifest)
            + WorkflowPackageManifestValidator.validateWorkflowBundle(manifest, packageRoot: packageDirectory)
          let workflowDirectory: URL
          if let normalized = WorkflowPackageManifestValidator.normalizePackageRelativePath(manifest.workflowDirectory ?? ".") {
            workflowDirectory = packageDirectory.appendingPathComponent(normalized, isDirectory: true).standardizedFileURL
          } else {
            workflowDirectory = packageDirectory
          }
          let diagnostics = issues.map {
            WorkflowValidationDiagnostic(severity: .error, path: $0.path, message: $0.message)
          }
          let workflowValidation = validateAuthoredWorkflowData(
            try Data(contentsOf: workflowDirectory.appendingPathComponent("workflow.json"))
          )
          let workflow = workflowValidation.workflow
          let completeDiagnostics = diagnostics + workflowValidation.diagnostics
          entries.append(WorkflowCatalogEntry(
            workflowName: manifest.name,
            workflowId: workflow?.workflowId,
            description: workflow?.description,
            scope: scope,
            sourceKind: .package,
            workflowDirectory: workflowDirectory.path,
            packageName: manifest.name,
            packageVersion: manifest.version,
            packageDirectory: packageDirectory.path,
            provenance: .immutable,
            valid: !completeDiagnostics.contains { $0.severity == .error },
            diagnostics: completeDiagnostics
          ))
        } catch {
          entries.append(WorkflowCatalogEntry(
            workflowName: packageDirectoryRelativeName(packageDirectory, packageRoot: root),
            scope: scope,
            sourceKind: .package,
            workflowDirectory: packageDirectory.path,
            packageDirectory: packageDirectory.path,
            provenance: .immutable,
            valid: false,
            diagnostics: [
              WorkflowValidationDiagnostic(severity: .error, path: "riela-package.json", message: "\(error)")
            ]
          ))
        }
      }
    }
    return entries
  }

  private func render(_ result: WorkflowCatalogResult, output: WorkflowOutputFormat) throws -> String {
    switch output {
    case .json, .jsonl:
      return try jsonString(result)
    case .text:
      return result.workflows.map {
        "\($0.workflowName)\t\($0.scope.rawValue)\t\($0.sourceKind.rawValue)\t\($0.provenance.rawValue)\t\($0.mutable)\t\($0.activationState.rawValue)\t\($0.valid ? "valid" : "invalid")\t\($0.workflowDirectory)"
      }.joined(separator: "\n") + (result.workflows.isEmpty ? "" : "\n")
    case .table:
      let header = "WORKFLOW\tSCOPE\tSOURCE\tPROVENANCE\tMUTABLE\tACTIVATION\tSTATUS\tDIRECTORY"
      let rows = result.workflows.map {
        "\($0.workflowName)\t\($0.scope.rawValue)\t\($0.sourceKind.rawValue)\t\($0.provenance.rawValue)\t\($0.mutable)\t\($0.activationState.rawValue)\t\($0.valid ? "valid" : "invalid")\t\($0.workflowDirectory)"
      }
      return ([header] + rows).joined(separator: "\n") + "\n"
    }
  }

  private func applyingActivation(to entry: WorkflowCatalogEntry) throws -> WorkflowCatalogEntry {
    var activated = entry
    let origin = workflowOriginIdentity(
      name: entry.workflowName,
      workflowId: entry.workflowId,
      scope: entry.scope,
      sourceKind: entry.sourceKind,
      provenance: entry.provenance,
      locator: entry.workflowDirectory
    )
    activated.originId = origin.originId
    activated.activationState = try WorkflowActivationStore().state(for: origin)
    return activated
  }

  private func catalogParseOptions(_ options: CLICommandOptions) throws -> ParsedCatalogOptions {
    let arguments = try ParsedCatalogArguments.parseCLI(options.arguments)
    guard let scope = WorkflowScope(rawValue: arguments.scope), scope != .direct else {
      throw CLIUsageError("invalid --scope value; expected auto, project, or user")
    }
    let activation = try arguments.activation.map {
      guard let value = WorkflowActivationState(rawValue: $0) else {
        throw CLIUsageError("invalid --activation value; expected active or deactivated")
      }
      return value
    }
    let provenance = try arguments.provenance.map {
      guard let value = WorkflowProvenance(rawValue: $0) else {
        throw CLIUsageError("invalid --provenance value; expected mutable or immutable")
      }
      return value
    }
    return ParsedCatalogOptions(
      scope: scope,
      workingDirectory: arguments.workingDirectory,
      excludeMutable: arguments.excludeMutable,
      activation: activation,
      provenance: provenance,
      description: arguments.description
    )
  }

  private func workflowRoots(scope: WorkflowScope, workingDirectory: String) -> [(WorkflowScope, URL)] {
    let project = URL(fileURLWithPath: workingDirectory).appendingPathComponent(".riela/workflows", isDirectory: true)
    let user = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory()).appendingPathComponent(".riela/workflows", isDirectory: true)
    switch scope {
    case .project:
      return [(.project, project)]
    case .user:
      return [(.user, user)]
    case .auto, .direct:
      return [(.project, project), (.user, user)]
    }
  }

  private func workflowNames(in root: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: root.path) else {
      return []
    }
    let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
    return contents.compactMap { url in
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        return nil
      }
      return url.lastPathComponent
    }
  }

  private func packageRoots(scope: WorkflowScope, workingDirectory: String) -> [(WorkflowScope, URL)] {
    let project = URL(fileURLWithPath: workingDirectory).appendingPathComponent(".riela/packages", isDirectory: true)
    let user = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory()).appendingPathComponent(".riela/packages", isDirectory: true)
    switch scope {
    case .project:
      return [(.project, project)]
    case .user:
      return [(.user, user)]
    case .auto, .direct:
      return [(.project, project), (.user, user)]
    }
  }

  private func packageManifestURLs(in root: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }
    var urls: [URL] = []
    for case let url as URL in enumerator where url.lastPathComponent == "riela-package.json" {
      urls.append(url)
      enumerator.skipDescendants()
    }
    return urls.sorted { $0.path < $1.path }
  }

  private func packageDirectoryRelativeName(_ packageDirectory: URL, packageRoot: URL) -> String {
    let packagePath = packageDirectory.standardizedFileURL.path
    let rootPath = packageRoot.standardizedFileURL.path
    guard packagePath.hasPrefix(rootPath + "/") else {
      return packageDirectory.lastPathComponent
    }
    return String(packagePath.dropFirst(rootPath.count + 1))
  }
}
