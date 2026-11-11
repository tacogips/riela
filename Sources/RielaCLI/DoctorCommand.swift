import Foundation
import RielaAdapters
import RielaAddons
import RielaCore
import RielaSQLite
import RielaWorkflowRegistry

public enum DoctorCheckStatus: String, Codable, Equatable, Sendable {
  case ok
  case warning
  case missing
  case unknown
}

public enum DoctorRuntimeKind: String, Codable, Equatable, Sendable {
  case appleContainer = "apple-container"
  case docker
  case podman
}

public struct DoctorCommandResult: Codable, Equatable, Sendable {
  public var scope: String
  public var workingDirectory: String
  public var packages: [DoctorPackageReport]
  public var requiredEnvironment: [DoctorEnvironmentRequirement]
  public var runtimeHints: [DoctorRuntimeHint]
  public var containerRequirements: [DoctorContainerRequirement]
  public var containerRuntimes: [DoctorContainerRuntime]
  public var backendCapabilities: [BackendCapability]
  public var hostTraits: [HostTrait]
  public var definitionSources: [DoctorDefinitionSourceReport]
  public var summary: DoctorSummary
}

public struct DoctorPackageReport: Codable, Equatable, Sendable {
  public var name: String
  public var version: String?
  public var kind: WorkflowPackageKind
  public var packageDirectory: String
  public var valid: Bool
  public var issues: [WorkflowPackageValidationIssue]
}

public struct DoctorEnvironmentRequirement: Codable, Equatable, Sendable {
  public var package: String
  public var name: String
  public var description: String?
  public var secret: Bool
  public var status: DoctorCheckStatus
}

public struct DoctorRuntimeHint: Codable, Equatable, Sendable {
  public var package: String
  public var addon: String
  public var hint: String
  public var status: DoctorCheckStatus
  public var resolvedPath: String?
  public var installHint: String?
}

public struct DoctorContainerRequirement: Codable, Equatable, Sendable {
  public var package: String
  public var addon: String
  public var containerfilePath: String?
  public var image: String?
  public var imageDigest: String?
  public var status: DoctorCheckStatus
  public var installHint: String?
}

public struct DoctorContainerRuntime: Codable, Equatable, Sendable {
  public var kind: DoctorRuntimeKind
  public var command: String
  public var status: DoctorCheckStatus
  public var resolvedPath: String?
}

public struct DoctorDefinitionSourceReport: Codable, Equatable, Sendable {
  public var storeRoot: String
  public var workflowName: String?
  public var currentVersionId: String?
  public var lastFileVersionId: String?
  public var sourceDirectory: String?
  public var result: String
  public var status: DoctorCheckStatus
  public var message: String?
}

public struct DoctorSummary: Codable, Equatable, Sendable {
  public var status: DoctorCheckStatus
  public var packagesChecked: Int
  public var missingEnvironment: Int
  public var missingRuntimeHints: Int
  public var missingContainerRequirements: Int
  public var availableContainerRuntimes: Int
  public var availableBackends: Int
  public var definitionSourceWarnings: Int
}

public struct DoctorCommand: Sendable {
  public var runner: any LocalProcessRunning
  var hostResolver: any HostCapabilityResolving

  public init(
    runner: any LocalProcessRunning = FoundationLocalProcessRunner()
  ) {
    self.runner = runner
    hostResolver = HostCapabilityResolver(runner: runner)
  }

  init(runner: any LocalProcessRunning, hostResolver: any HostCapabilityResolving) {
    self.runner = runner
    self.hostResolver = hostResolver
  }

  public func run(_ options: CLICommandOptions) async -> CLICommandResult {
    do {
      let parsed = try ParsedParityOptions(options.arguments)
      let workingDirectory = URL(
        fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath,
        isDirectory: true
      )
      let result = try await diagnose(parsed: parsed, workingDirectory: workingDirectory)
      return try render(result, output: options.output)
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  private func diagnose(parsed: ParsedParityOptions, workingDirectory: URL) async throws -> DoctorCommandResult {
    let manifests = try await installedPackageManifests(parsed: parsed, workingDirectory: workingDirectory)
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    let pathDirectories = executableSearchPath(environment: environment)
    let packageReports = manifests.map { entry in
      DoctorPackageReport(
        name: entry.manifest.name,
        version: entry.manifest.version,
        kind: entry.manifest.kind,
        packageDirectory: entry.packageDirectory.path,
        valid: entry.issues.isEmpty,
        issues: entry.issues
      )
    }
    let requiredEnvironment = manifests.flatMap { entry in
      entry.manifest.environmentVariables.filter(\.required).map { requirement in
        DoctorEnvironmentRequirement(
          package: entry.manifest.name,
          name: requirement.name,
          description: requirement.description,
          secret: requirement.secret,
          status: environment[requirement.name].flatMap { $0.isEmpty ? nil : $0 } == nil ? .missing : .ok
        )
      }
    }
    let runtimeHints = manifests.flatMap { entry in
      entry.manifest.nodeAddons.flatMap { addon in
        (addon.execution?.runtimeHints ?? []).map { hint in
          let resolvedPath = resolveExecutable(hint, searchPath: pathDirectories)
          return DoctorRuntimeHint(
            package: entry.manifest.name,
            addon: addon.name,
            hint: hint,
            status: resolvedPath == nil ? .missing : .ok,
            resolvedPath: resolvedPath,
            installHint: resolvedPath == nil ? installHint(forRuntimeHint: hint) : nil
          )
        }
      }
    }
    let containerRuntimes = [
      try await containerRuntime(kind: .appleContainer, command: "container", searchPath: pathDirectories, environment: environment),
      try await containerRuntime(kind: .docker, command: "docker", searchPath: pathDirectories, environment: environment),
      try await containerRuntime(kind: .podman, command: "podman", searchPath: pathDirectories, environment: environment)
    ]
    let containerRuntimeAvailable = containerRuntimes.contains { $0.status == .ok }
    let containerRequirements = manifests.flatMap { entry in
      entry.manifest.nodeAddons.compactMap { addon -> DoctorContainerRequirement? in
        guard addon.execution?.kind == .container else {
          return nil
        }
        return DoctorContainerRequirement(
          package: entry.manifest.name,
          addon: addon.name,
          containerfilePath: addon.execution?.containerfilePath,
          image: addon.execution?.image,
          imageDigest: addon.execution?.imageDigest,
          status: containerRuntimeAvailable ? .ok : .missing,
          installHint: containerRuntimeAvailable ? nil : containerRuntimeInstallHint
        )
      }
    }
    let missingEnvironment = requiredEnvironment.filter { $0.status == .missing }.count
    let missingRuntimeHints = runtimeHints.filter { $0.status == .missing }.count
    let missingContainerRequirements = containerRequirements.filter { $0.status == .missing }.count
    let availableContainerRuntimes = containerRuntimes.filter { $0.status == .ok }.count
    let localSnapshots = try await hostResolver.resolve(
      host: "local",
      scope: parsed.scope,
      workingDirectory: workingDirectory.path,
      readOnly: false
    )
    let backendCapabilities = localSnapshots.first?.backends ?? []
    let hostTraits = localSnapshots.first?.traits.sorted() ?? []
    let definitionSources = definitionSourceReports(parsed: parsed, workingDirectory: workingDirectory.path)
    let definitionSourceWarnings = definitionSources.filter { $0.status == .warning }.count
    let summaryStatus: DoctorCheckStatus =
      missingEnvironment == 0 && missingRuntimeHints == 0 && missingContainerRequirements == 0
        && definitionSourceWarnings == 0 ? .ok : .warning
    return DoctorCommandResult(
      scope: parsed.scope.rawValue,
      workingDirectory: workingDirectory.path,
      packages: packageReports.sorted { $0.name < $1.name },
      requiredEnvironment: requiredEnvironment.sorted { $0.package == $1.package ? $0.name < $1.name : $0.package < $1.package },
      runtimeHints: runtimeHints.sorted { $0.package == $1.package ? $0.hint < $1.hint : $0.package < $1.package },
      containerRequirements: containerRequirements.sorted { $0.package == $1.package ? $0.addon < $1.addon : $0.package < $1.package },
      containerRuntimes: containerRuntimes,
      backendCapabilities: backendCapabilities,
      hostTraits: hostTraits,
      definitionSources: definitionSources,
      summary: DoctorSummary(
        status: summaryStatus,
        packagesChecked: packageReports.count,
        missingEnvironment: missingEnvironment,
        missingRuntimeHints: missingRuntimeHints,
        missingContainerRequirements: missingContainerRequirements,
        availableContainerRuntimes: availableContainerRuntimes,
        availableBackends: backendCapabilities.filter { $0.availability == .available }.count,
        definitionSourceWarnings: definitionSourceWarnings
      )
    )
  }

  private func definitionSourceReports(parsed: ParsedParityOptions, workingDirectory: String) -> [DoctorDefinitionSourceReport] {
    let roots = WorkflowDefinitionStoreSelection.candidateRoots(
      sessionStore: parsed.sessionStore, scope: parsed.scope, workingDirectory: workingDirectory
    )
    var reports: [DoctorDefinitionSourceReport] = []
    var seen: Set<String> = []
    for root in roots where seen.insert(root).inserted {
      let path = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root)
      guard FileManager.default.fileExists(atPath: path) else { continue }
      do {
        guard try definitionStorePrecheck(path: path) else { continue }
        let resolver = FileSystemWorkflowBundleResolver()
        let service = WorkflowDefinitionService(storeRoot: root, fileResolver: resolver)
        for name in try service.workflowNames() {
          do {
            guard let report = try service.inspectSourceDrift(
              workflowName: name, workingDirectory: workingDirectory, fileResolver: resolver
            ) else { continue }
            reports.append(definitionSourceReport(report, root: root))
          } catch {
            reports.append(unreadableDefinitionStore(root: root, workflowName: name, message: "\(error)"))
          }
        }
      } catch {
        reports.append(unreadableDefinitionStore(root: root, workflowName: nil, message: "\(error)"))
      }
    }
    return reports
  }

  private struct DefinitionStorePrecheckError: Error, CustomStringConvertible {
    var description: String
  }

  private func definitionStorePrecheck(path: String) throws -> Bool {
    let db = try SQLiteDatabase.open(path: path, mode: .strictReadOnly, options: .readOnlyDefault)
    let generation = try SQLiteSchemaMigrator.stampedGeneration(in: db)
    guard generation == SQLiteWorkflowRuntimePersistenceStore.schemaGeneration else {
      throw DefinitionStorePrecheckError(description: "Schema generation \(generation) differs from current generation \(SQLiteWorkflowRuntimePersistenceStore.schemaGeneration)")
    }
    guard try db.tableExists("definition_heads") else { return false }
    let journalMode = try db.query("PRAGMA journal_mode").first?["journal_mode"]
    guard journalMode?.lowercased() == "wal" else {
      throw DefinitionStorePrecheckError(description: "Journal mode must be WAL (found \(journalMode ?? "unknown"))")
    }
    return true
  }

  private func unreadableDefinitionStore(root: String, workflowName: String?, message: String) -> DoctorDefinitionSourceReport {
    DoctorDefinitionSourceReport(storeRoot: root, workflowName: workflowName, currentVersionId: nil,
                                 lastFileVersionId: nil, sourceDirectory: nil, result: "storeUnreadable",
                                 status: .unknown, message: message)
  }

  private func definitionSourceReport(_ report: WorkflowDefinitionSourceDriftReport, root: String) -> DoctorDefinitionSourceReport {
    let result: String
    let diagnosticPath: String
    switch report.result {
    case .inSync: result = "inSync"; diagnosticPath = ""
    case .autoSync: result = "pendingAutoSync"; diagnosticPath = "definitionStore.pendingAutoSync"
    case .drift: result = "drift"; diagnosticPath = "definitionStore.sourceDrift"
    case .sourceInvalid: result = "sourceInvalid"; diagnosticPath = "definitionStore.sourceInvalid"
    case .sourceUnavailable: result = "sourceUnavailable"; diagnosticPath = "definitionStore.sourceUnavailable"
    }
    var message: String?
    if report.result != .inSync {
      message = WorkflowDefinitionSourceDrift.diagnostic(
        for: report, path: diagnosticPath, syncedVersionId: nil, auditId: nil
      ).message
      if report.result == .autoSync { message = (message ?? "") + " The next service run will import the file." }
    }
    return DoctorDefinitionSourceReport(
      storeRoot: root, workflowName: report.workflowName, currentVersionId: report.currentVersionId,
      lastFileVersionId: report.lastFileVersionId, sourceDirectory: report.sourceDirectory,
      result: result, status: report.result == .inSync ? .ok : .warning, message: message
    )
  }

  private struct InstalledPackageManifest {
    var packageDirectory: URL
    var manifest: WorkflowPackageManifest
    var issues: [WorkflowPackageValidationIssue]
  }

  private func installedPackageManifests(
    parsed: ParsedParityOptions,
    workingDirectory: URL
  ) async throws -> [InstalledPackageManifest] {
    let loader = FileWorkflowPackageManifestLoader()
    var manifests: [InstalledPackageManifest] = []
    for root in packageRoots(parsed: parsed, workingDirectory: workingDirectory)
      where FileManager.default.fileExists(atPath: root.path) {
      for manifestURL in try packageManifestURLs(in: root) {
        let packageDirectory = manifestURL.deletingLastPathComponent()
        do {
          let manifest = try await loader.loadManifest(from: manifestURL)
          let issues = await loader.validate(manifest, packageRoot: packageDirectory)
          manifests.append(InstalledPackageManifest(
            packageDirectory: packageDirectory,
            manifest: manifest,
            issues: issues
          ))
        } catch {
          let issue = WorkflowPackageValidationIssue(
            code: "INVALID_MANIFEST",
            path: manifestURL.path,
            message: "\(error)"
          )
          let fallback = WorkflowPackageManifest(
            name: packageDirectory.lastPathComponent,
            version: nil,
            description: "Invalid installed package manifest",
            checksum: nil,
            workflowDirectory: nil
          )
          manifests.append(InstalledPackageManifest(
            packageDirectory: packageDirectory,
            manifest: fallback,
            issues: [issue]
          ))
        }
      }
    }
    return manifests
  }

  private func render(_ result: DoctorCommandResult, output: WorkflowOutputFormat) throws -> CLICommandResult {
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: try jsonString(result))
    case .text, .table:
      return CLICommandResult(exitCode: .success, stdout: renderText(result))
    }
  }

  private func renderText(_ result: DoctorCommandResult) -> String {
    var lines: [String] = []
    lines.append("doctor: \(result.summary.status.rawValue)")
    lines.append("packages: \(result.summary.packagesChecked)")
    lines.append("missing environment: \(result.summary.missingEnvironment)")
    lines.append("missing runtime hints: \(result.summary.missingRuntimeHints)")
    lines.append("missing container requirements: \(result.summary.missingContainerRequirements)")
    lines.append("container runtimes: \(result.summary.availableContainerRuntimes) available")
    lines.append("agent backends: \(result.summary.availableBackends) available")
    lines.append("host traits: \(result.hostTraits.isEmpty ? "none declared" : result.hostTraits.map(\.rawValue).joined(separator: ","))")
    if !result.backendCapabilities.isEmpty {
      lines.append("")
      lines.append("agent backends:")
      for capability in result.backendCapabilities {
        let freshness = capability.isFresh(at: Date(), maximumAge: 300) ? "fresh" : "stale-or-unverified"
        let version = capability.version.map { " version=\($0)" } ?? ""
        let models = capability.models.map { " models=\($0.joined(separator: ","))" } ?? ""
        let failures = capability.failures.isEmpty ? "" : " failures=\(capability.failures.joined(separator: ";"))"
        lines.append(
          "- \(capability.backend.rawValue): \(capability.availability.rawValue) "
            + "auth=\(capability.authentication.rawValue) source=\(capability.source.rawValue) \(freshness)"
            + version + models + failures
        )
      }
    }
    if !result.requiredEnvironment.isEmpty {
      lines.append("")
      lines.append("environment:")
      for requirement in result.requiredEnvironment {
        lines.append("- \(requirement.status.rawValue) \(requirement.name) (\(requirement.package))")
      }
    }
    if !result.runtimeHints.isEmpty {
      lines.append("")
      lines.append("runtime hints:")
      for hint in result.runtimeHints {
        let detail = hint.resolvedPath ?? hint.installHint ?? "not found"
        lines.append("- \(hint.status.rawValue) \(hint.hint) (\(hint.package)/\(hint.addon)): \(detail)")
      }
    }
    if !result.containerRequirements.isEmpty {
      lines.append("")
      lines.append("container requirements:")
      for requirement in result.containerRequirements {
        let path = requirement.containerfilePath.map { " containerfile=\($0)" } ?? ""
        let image = requirement.image.map { " image=\($0)" } ?? ""
        let digest = requirement.imageDigest.map { " digest=\($0)" } ?? ""
        let detail = requirement.installHint.map { ": \($0)" } ?? ""
        lines.append("- \(requirement.status.rawValue) \(requirement.package)/\(requirement.addon)\(path)\(image)\(digest)\(detail)")
      }
    }
    lines.append("")
    lines.append("container:")
    for runtime in result.containerRuntimes {
      let detail = runtime.resolvedPath ?? "not found"
      lines.append("- \(runtime.status.rawValue) \(runtime.command): \(detail)")
    }
    let sourceIssues = result.definitionSources.filter { $0.status != .ok }
    if !sourceIssues.isEmpty {
      lines.append("")
      lines.append("Definition sources:")
      for source in sourceIssues {
        lines.append("- \(source.status.rawValue) \(source.workflowName ?? "store") (\(source.storeRoot)): \(source.result) — \(source.message ?? "")")
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private func containerRuntime(
    kind: DoctorRuntimeKind,
    command: String,
    searchPath: [String],
    environment: [String: String]
  ) async throws -> DoctorContainerRuntime {
    let resolvedPath = resolveExecutable(command, searchPath: searchPath)
    let status: DoctorCheckStatus
    if let resolvedPath {
      status = try await runtimeReadinessStatus(
        kind: kind,
        executablePath: resolvedPath,
        environment: environment
      )
    } else {
      status = resolvedPath == nil ? .missing : .ok
    }
    return DoctorContainerRuntime(
      kind: kind,
      command: command,
      status: status,
      resolvedPath: resolvedPath
    )
  }

  private func runtimeReadinessStatus(
    kind: DoctorRuntimeKind,
    executablePath: String,
    environment: [String: String]
  ) async throws -> DoctorCheckStatus {
    let arguments: [String]
    switch kind {
    case .appleContainer:
      arguments = ["system", "status", "--format", "json"]
    case .docker, .podman:
      arguments = ["info"]
    }
    do {
      let statusResult = try await runner.run(
        configuration: LocalProcessConfiguration(
          executableURL: URL(fileURLWithPath: executablePath),
          arguments: arguments,
          environment: environment
        ),
        stdin: "",
        deadline: Date().addingTimeInterval(5)
      )
      return statusResult.terminationStatus == 0 ? .ok : .warning
    } catch {
      return .warning
    }
  }

  private var containerRuntimeInstallHint: String {
    "Run riela setup container, or install Apple Container, Docker, or Podman and start the runtime"
  }

  private func installHint(forRuntimeHint hint: String) -> String {
    switch hint {
    case "ffmpeg":
      return "brew install ffmpeg"
    case "yt-dlp":
      return "brew install yt-dlp"
    case "node":
      return "brew install node"
    case "jq":
      return "brew install jq"
    case "bash":
      return "Install bash or ensure /bin/bash is on PATH"
    default:
      return "Install \(hint) and ensure it is on PATH"
    }
  }
}

func executableSearchPath(environment: [String: String]) -> [String] {
  (environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    .split(separator: ":")
    .map(String.init)
}

func resolveExecutable(_ command: String, searchPath: [String]) -> String? {
  guard !command.contains("/") else {
    return FileManager.default.isExecutableFile(atPath: command) ? command : nil
  }
  for directory in searchPath {
    let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(command).path
    if FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
  }
  return nil
}
