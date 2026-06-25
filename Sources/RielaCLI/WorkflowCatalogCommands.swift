import Foundation
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

public struct WorkflowCatalogEntry: Codable, Equatable, Sendable {
  public var workflowName: String
  public var scope: WorkflowScope
  public var sourceKind: WorkflowSourceKind
  public var workflowDirectory: String
  public var packageName: String?
  public var packageVersion: String?
  public var packageDirectory: String?
  public var mutable: Bool
  public var valid: Bool
  public var diagnostics: [WorkflowValidationDiagnostic]

  public init(
    workflowName: String,
    scope: WorkflowScope,
    sourceKind: WorkflowSourceKind = .workflow,
    workflowDirectory: String,
    packageName: String? = nil,
    packageVersion: String? = nil,
    packageDirectory: String? = nil,
    mutable: Bool = true,
    valid: Bool,
    diagnostics: [WorkflowValidationDiagnostic]
  ) {
    self.workflowName = workflowName
    self.scope = scope
    self.sourceKind = sourceKind
    self.workflowDirectory = workflowDirectory
    self.packageName = packageName
    self.packageVersion = packageVersion
    self.packageDirectory = packageDirectory
    self.mutable = mutable
    self.valid = valid
    self.diagnostics = diagnostics
  }
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
  public init() {}

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
        workingDirectory: parsed.workingDirectory
      )
      let bundle = try FileSystemWorkflowBundleResolver().resolve(resolution)
      let diagnostics = bundle.diagnostics + DefaultWorkflowValidator().validate(bundle.workflow)
      let entry = WorkflowCatalogEntry(
        workflowName: target,
        scope: bundle.sourceScope,
        sourceKind: workflowSourceKind(bundle),
        workflowDirectory: bundle.workflowDirectory,
        packageName: bundle.packageManifest?.name,
        packageVersion: bundle.packageManifest?.version,
        packageDirectory: bundle.packageDirectory,
        mutable: bundle.packageManifest == nil,
        valid: !diagnostics.contains { $0.severity == .error },
        diagnostics: diagnostics
      )
      return CLICommandResult(
        exitCode: entry.valid ? .success : .failure,
        stdout: try render(WorkflowCatalogResult(workflows: [entry]), output: options.output)
      )
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  private struct ParsedCatalogOptions {
    var scope: WorkflowScope
    var workingDirectory: String
  }

  private func catalogEntries(options: CLICommandOptions) throws -> [WorkflowCatalogEntry] {
    let parsed = try catalogParseOptions(options)
    let roots = workflowRoots(scope: parsed.scope, workingDirectory: parsed.workingDirectory)
    var entries: [WorkflowCatalogEntry] = []
    for (scope, root) in roots {
      let names = try workflowNames(in: root)
      for name in names {
        let resolution = WorkflowResolutionOptions(workflowName: name, scope: scope, workingDirectory: parsed.workingDirectory)
        do {
          let bundle = try FileSystemWorkflowBundleResolver().resolve(resolution)
          let diagnostics = bundle.diagnostics + DefaultWorkflowValidator().validate(bundle.workflow)
          entries.append(WorkflowCatalogEntry(
            workflowName: name,
            scope: bundle.sourceScope,
            sourceKind: workflowSourceKind(bundle),
            workflowDirectory: bundle.workflowDirectory,
            packageName: bundle.packageManifest?.name,
            packageVersion: bundle.packageManifest?.version,
            packageDirectory: bundle.packageDirectory,
            mutable: bundle.packageManifest == nil,
            valid: !diagnostics.contains { $0.severity == .error },
            diagnostics: diagnostics
          ))
        } catch {
          entries.append(WorkflowCatalogEntry(
            workflowName: name,
            scope: scope,
            sourceKind: .workflow,
            workflowDirectory: root.appendingPathComponent(name).path,
            mutable: true,
            valid: false,
            diagnostics: [
              WorkflowValidationDiagnostic(severity: .error, path: "workflow.json", message: "\(error)")
            ]
          ))
        }
      }
    }
    entries.append(contentsOf: try packageCatalogEntries(options: parsed))
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
          entries.append(WorkflowCatalogEntry(
            workflowName: manifest.name,
            scope: scope,
            sourceKind: .package,
            workflowDirectory: workflowDirectory.path,
            packageName: manifest.name,
            packageVersion: manifest.version,
            packageDirectory: packageDirectory.path,
            mutable: false,
            valid: diagnostics.isEmpty,
            diagnostics: diagnostics
          ))
        } catch {
          entries.append(WorkflowCatalogEntry(
            workflowName: packageDirectoryRelativeName(packageDirectory, packageRoot: root),
            scope: scope,
            sourceKind: .package,
            workflowDirectory: packageDirectory.path,
            packageDirectory: packageDirectory.path,
            mutable: false,
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
        "\($0.workflowName)\t\($0.scope.rawValue)\t\($0.sourceKind.rawValue)\t\($0.valid ? "valid" : "invalid")\t\($0.workflowDirectory)"
      }.joined(separator: "\n") + (result.workflows.isEmpty ? "" : "\n")
    case .table:
      let header = "WORKFLOW\tSCOPE\tSOURCE\tSTATUS\tDIRECTORY"
      let rows = result.workflows.map {
        "\($0.workflowName)\t\($0.scope.rawValue)\t\($0.sourceKind.rawValue)\t\($0.valid ? "valid" : "invalid")\t\($0.workflowDirectory)"
      }
      return ([header] + rows).joined(separator: "\n") + "\n"
    }
  }

  private func catalogParseOptions(_ options: CLICommandOptions) throws -> ParsedCatalogOptions {
    var scope = WorkflowScope.auto
    var workingDirectory = FileManager.default.currentDirectoryPath
    var index = 0
    while index < options.arguments.count {
      let token = options.arguments[index]
      switch token {
      case "--scope":
        guard index + 1 < options.arguments.count, let value = WorkflowScope(rawValue: options.arguments[index + 1]), value != .direct else {
          throw CLIUsageError("invalid --scope value; expected auto, project, or user")
        }
        scope = value
        index += 2
      case "--working-dir", "--working-directory":
        guard index + 1 < options.arguments.count else {
          throw CLIUsageError("\(token) requires a value")
        }
        workingDirectory = options.arguments[index + 1]
        index += 2
      case "--output":
        index += 2
      default:
        if token.hasPrefix("--output=") {
          index += 1
        } else {
          throw CLIUsageError("unsupported workflow catalog option '\(token)'")
        }
      }
    }
    return ParsedCatalogOptions(scope: scope, workingDirectory: workingDirectory)
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
