import Foundation
import RielaAdapters
import RielaAddons
import RielaCore

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

public struct DoctorSummary: Codable, Equatable, Sendable {
  public var status: DoctorCheckStatus
  public var packagesChecked: Int
  public var missingEnvironment: Int
  public var missingRuntimeHints: Int
  public var missingContainerRequirements: Int
  public var availableContainerRuntimes: Int
}

public struct DoctorCommand: Sendable {
  public var runner: any LocalAgentProcessRunning

  public init(
    runner: any LocalAgentProcessRunning = FoundationLocalAgentProcessRunner()
  ) {
    self.runner = runner
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
    let summaryStatus: DoctorCheckStatus =
      missingEnvironment == 0 && missingRuntimeHints == 0 && missingContainerRequirements == 0 ? .ok : .warning
    return DoctorCommandResult(
      scope: parsed.scope.rawValue,
      workingDirectory: workingDirectory.path,
      packages: packageReports.sorted { $0.name < $1.name },
      requiredEnvironment: requiredEnvironment.sorted { $0.package == $1.package ? $0.name < $1.name : $0.package < $1.package },
      runtimeHints: runtimeHints.sorted { $0.package == $1.package ? $0.hint < $1.hint : $0.package < $1.package },
      containerRequirements: containerRequirements.sorted { $0.package == $1.package ? $0.addon < $1.addon : $0.package < $1.package },
      containerRuntimes: containerRuntimes,
      summary: DoctorSummary(
        status: summaryStatus,
        packagesChecked: packageReports.count,
        missingEnvironment: missingEnvironment,
        missingRuntimeHints: missingRuntimeHints,
        missingContainerRequirements: missingContainerRequirements,
        availableContainerRuntimes: availableContainerRuntimes
      )
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
        configuration: LocalAgentProcessConfiguration(
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
