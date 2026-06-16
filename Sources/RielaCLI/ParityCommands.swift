import Foundation
import RielaAdapters
import RielaAddons
import RielaCore
import RielaEvents
import RielaGraphQL
import RielaHook
import RielaServer

public struct WorkflowCheckoutCommandResult: Codable, Equatable, Sendable {
  public var workflowName: String
  public var sourceDirectory: String
  public var destinationDirectory: String
  public var scope: WorkflowScope
  public var overwritten: Bool
}

public struct WorkflowCreateCommandResult: Codable, Equatable, Sendable {
  public var workflowName: String
  public var workflowDirectory: String
  public var scope: WorkflowScope
  public var files: [String]
}

public struct WorkflowSelfImproveCommandResult: Codable, Equatable, Sendable {
  public var workflowName: String
  public var dryRun: Bool
  public var mutated: Bool
  public var backupDirectory: String?
  public var reportPath: String?
  public var report: [String]
}

public struct WorkflowPackageCommandResult: Codable, Equatable, Sendable {
  public var scope: String
  public var command: String
  public var target: String?
  public var packages: [WorkflowPackageSummary]
  public var destinationDirectory: String?
  public var dryRun: Bool
  public var message: String
  public var runSessionId: String?
}

public struct WorkflowPackageSummary: Codable, Equatable, Sendable {
  public var name: String
  public var version: String?
  public var kind: WorkflowPackageKind
  public var packageDirectory: String
  public var workflowDirectory: String?
  public var valid: Bool
  public var issues: [WorkflowPackageValidationIssue]
}

public struct WorkflowPackageRegistryConfig: Codable, Equatable, Sendable {
  public var defaultRegistryId: String
  public var registries: [WorkflowPackageRegistryEntry]
}

public struct WorkflowPackageRegistryEntry: Codable, Equatable, Sendable {
  public var id: String
  public var url: String
  public var defaultBranch: String
  public var localPath: String?
  public var registeredAt: String
  public var updatedAt: String
}

public struct ScopedParityCommandResult: Codable, Equatable, Sendable {
  public var scope: String
  public var command: String?
  public var target: String?
  public var status: String
  public var records: [String]
}

public struct WorkflowScaffoldCommand: Sendable {
  public init() {}

  public func checkout(_ options: CLICommandOptions) -> CLICommandResult {
    do {
      guard let checkoutTarget = options.target, !checkoutTarget.isEmpty else {
        throw CLIUsageError("workflow checkout requires a GitHub workflow directory URL")
      }
      let parsed = try ParsedParityOptions(options.arguments)
      let workflowName: String
      if isGitHubWorkflowDirectoryURL(checkoutTarget) {
        workflowName = try workflowNameFromGitHubDirectoryURL(checkoutTarget)
      } else if parsed.source != nil {
        workflowName = checkoutTarget
      } else {
        throw CLIUsageError("workflow checkout requires a GitHub workflow directory URL")
      }
      guard isSafeScopedWorkflowName(workflowName) else {
        throw CLIUsageError("invalid scoped workflow name '\(workflowName)'")
      }
      let workingDirectory = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
      let destinationScope = parsed.scope
      let destinationRoot = scopedWorkflowRoot(scope: destinationScope, workingDirectory: workingDirectory)
      let destination = destinationRoot.appendingPathComponent(workflowName, isDirectory: true)
      let source = try checkoutSource(workflowName: workflowName, checkoutTarget: checkoutTarget, parsed: parsed, workingDirectory: workingDirectory)
      let existed = FileManager.default.fileExists(atPath: destination.path)
      if existed {
        guard parsed.overwrite else {
          throw CLIUsageError("workflow checkout destination already exists: \(destination.path); pass --overwrite to replace it")
        }
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: source, to: destination)
      try writeWorkflowCheckoutRecord(
        workflowName: workflowName,
        checkoutTarget: checkoutTarget,
        source: source,
        destination: destination,
        scope: destinationScope,
        workingDirectory: workingDirectory
      )
      let result = WorkflowCheckoutCommandResult(
        workflowName: workflowName,
        sourceDirectory: source.path,
        destinationDirectory: destination.path,
        scope: destinationScope,
        overwritten: existed
      )
      return try render(result, options: options) { result in
        "checked out workflow \(result.workflowName) to \(result.destinationDirectory)\n"
      }
    } catch let error as CLIUsageError {
      return failure(error.message, output: options.output, options: options)
    } catch {
      return failure("\(error)", output: options.output, options: options)
    }
  }

  public func create(_ options: CLICommandOptions) -> CLICommandResult {
    do {
      guard let workflowName = options.target, !workflowName.isEmpty else {
        throw CLIUsageError("workflow create requires a workflow name")
      }
      guard isSafeScopedWorkflowName(workflowName) else {
        throw CLIUsageError("invalid scoped workflow name '\(workflowName)'")
      }
      let parsed = try ParsedParityOptions(options.arguments)
      let workingDirectory = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
      let destinationRoot = parsed.destination.map { absoluteURL($0, relativeTo: workingDirectory) }
        ?? scopedWorkflowRoot(scope: parsed.scope, workingDirectory: workingDirectory)
      let workflowDirectory = destinationRoot.appendingPathComponent(workflowName, isDirectory: true)
      if FileManager.default.fileExists(atPath: workflowDirectory.path) {
        guard parsed.overwrite else {
          throw CLIUsageError("workflow create destination already exists: \(workflowDirectory.path); pass --overwrite to replace it")
        }
        try FileManager.default.removeItem(at: workflowDirectory)
      }
      let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
      try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
      let workflowPath = workflowDirectory.appendingPathComponent("workflow.json")
      let nodePath = nodesDirectory.appendingPathComponent("node-main-worker.json")
      try scaffoldWorkflowJSON(workflowName: workflowName).write(to: workflowPath, atomically: true, encoding: .utf8)
      try scaffoldNodeJSON().write(to: nodePath, atomically: true, encoding: .utf8)
      let result = WorkflowCreateCommandResult(
        workflowName: workflowName,
        workflowDirectory: workflowDirectory.path,
        scope: parsed.scope,
        files: [workflowPath.path, nodePath.path]
      )
      return try render(result, options: options) { result in
        "created workflow \(result.workflowName) at \(result.workflowDirectory)\n"
      }
    } catch let error as CLIUsageError {
      return failure(error.message, output: options.output, options: options)
    } catch {
      return failure("\(error)", output: options.output, options: options)
    }
  }

  public func selfImprove(_ options: CLICommandOptions) -> CLICommandResult {
    do {
      guard let workflowName = options.target, !workflowName.isEmpty else {
        throw CLIUsageError("workflow self-improve requires a workflow name")
      }
      let parsed = try ParsedParityOptions(options.arguments)
      let workingDirectory = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
      let bundle = try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
        workflowName: workflowName,
        scope: parsed.scope,
        workflowDefinitionDir: parsed.workflowDefinitionDir,
        workingDirectory: workingDirectory.path
      ))
      let report: [String]
      let backupDirectory: String?
      let reportPath: String?
      if parsed.dryRun {
        backupDirectory = nil
        reportPath = nil
        report = [
          "Swift self-improve dry run completed without mutation.",
          "dryRun=true",
          "workflow=\(workflowName)",
          "workflowDirectory=\(bundle.workflowDirectory)",
          "steps=\(bundle.workflow.steps.count)",
        ]
      } else {
        guard parsed.overwrite else {
          throw CLIUsageError("workflow self-improve write mode needs explicit --yes or --force approval")
        }
        let mutation = try applySelfImproveMutation(
          workflowName: workflowName,
          workflowDirectory: URL(fileURLWithPath: bundle.workflowDirectory, isDirectory: true),
          workingDirectory: workingDirectory
        )
        backupDirectory = mutation.backupDirectory
        reportPath = mutation.reportPath
        report = mutation.report
      }
      let result = WorkflowSelfImproveCommandResult(
        workflowName: workflowName,
        dryRun: parsed.dryRun,
        mutated: !parsed.dryRun,
        backupDirectory: backupDirectory,
        reportPath: reportPath,
        report: report
      )
      return try render(result, options: options) { result in
        result.report.joined(separator: "\n") + "\n"
      }
    } catch let error as CLIUsageError {
      return failure(error.message, output: options.output, options: options)
    } catch {
      return failure("\(error)", output: options.output, options: options)
    }
  }

  private struct SelfImproveMutationResult {
    var backupDirectory: String
    var reportPath: String
    var report: [String]
  }

  private func applySelfImproveMutation(
    workflowName: String,
    workflowDirectory: URL,
    workingDirectory: URL
  ) throws -> SelfImproveMutationResult {
    let workflowJSON = workflowDirectory.appendingPathComponent("workflow.json")
    guard FileManager.default.fileExists(atPath: workflowJSON.path) else {
      throw CLIUsageError("workflow self-improve requires workflow.json at \(workflowJSON.path)")
    }
    let stamp = "2026-06-16T00-00-00Z"
    let backupDirectory = workingDirectory
      .appendingPathComponent(".riela/self-improve/backups", isDirectory: true)
      .appendingPathComponent("\(workflowName)-\(stamp)", isDirectory: true)
    let reportDirectory = workingDirectory.appendingPathComponent(".riela/self-improve/reports", isDirectory: true)
    let reportURL = reportDirectory.appendingPathComponent("\(workflowName)-\(stamp).json")
    try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
    let backupWorkflow = backupDirectory.appendingPathComponent("workflow.json")
    if FileManager.default.fileExists(atPath: backupWorkflow.path) {
      try FileManager.default.removeItem(at: backupWorkflow)
    }
    try FileManager.default.copyItem(at: workflowJSON, to: backupWorkflow)

    let data = try Data(contentsOf: workflowJSON)
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CLIUsageError("workflow self-improve requires workflow.json root object")
    }
    let reviewedDescription = "self-improve-reviewed"
    if let existingDescription = object["description"] as? String, !existingDescription.contains(reviewedDescription) {
      object["description"] = "\(existingDescription) \(reviewedDescription)"
    } else if object["description"] == nil {
      object["description"] = reviewedDescription
    }
    object["selfImproveMutation"] = [
      "mode": "reviewed-patch",
      "reviewedAt": stamp,
      "rollbackMetadata": backupWorkflow.path,
    ]
    let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try updated.write(to: workflowJSON, options: .atomic)

    let markerURL = workflowDirectory.appendingPathComponent(".riela-self-improve-patch.json")
    try jsonString([
      "workflowName": .string(workflowName),
      "mode": .string("reviewed-patch"),
      "backupWorkflow": .string(backupWorkflow.path),
      "reportPath": .string(reportURL.path),
      "rollbackMetadata": .string(backupWorkflow.path),
    ] as JSONObject).write(to: markerURL, atomically: true, encoding: .utf8)
    try jsonString([
      "workflowName": .string(workflowName),
      "mutated": .bool(true),
      "mutationMode": .string("reviewed-patch"),
      "backupDirectory": .string(backupDirectory.path),
      "rollbackMetadata": .string(backupWorkflow.path),
      "workflowJSON": .string(workflowJSON.path),
    ] as JSONObject).write(to: reportURL, atomically: true, encoding: .utf8)

    return SelfImproveMutationResult(
      backupDirectory: backupDirectory.path,
      reportPath: reportURL.path,
      report: [
        "Swift self-improve write mode applied reviewed patch.",
        "dryRun=false",
        "workflow=\(workflowName)",
        "workflowDirectory=\(workflowDirectory.path)",
        "backupDirectory=\(backupDirectory.path)",
        "reportPath=\(reportURL.path)",
        "rollbackMetadata=\(backupWorkflow.path)",
      ]
    )
  }

  private func checkoutSource(workflowName: String, checkoutTarget: String, parsed: ParsedParityOptions, workingDirectory: URL) throws -> URL {
    if let source = parsed.source {
      let url = absoluteURL(source, relativeTo: workingDirectory)
      let workflowJSON = url.appendingPathComponent("workflow.json")
      guard FileManager.default.fileExists(atPath: workflowJSON.path) else {
        throw CLIUsageError("workflow checkout source must contain workflow.json: \(url.path)")
      }
      return url
    }
    if isGitHubWorkflowDirectoryURL(checkoutTarget) {
      return try resolveGitHubWorkflowDirectory(checkoutTarget, workingDirectory: workingDirectory)
    }
    let roots = [scopedWorkflowRoot(scope: .project, workingDirectory: workingDirectory), scopedWorkflowRoot(scope: .user, workingDirectory: workingDirectory)]
    for root in roots {
      let candidate = root.appendingPathComponent(workflowName, isDirectory: true)
      if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("workflow.json").path) {
        return candidate
      }
    }
    throw CLIUsageError("workflow checkout source not found for \(workflowName); pass --source <workflow-dir>")
  }

  private func isGitHubWorkflowDirectoryURL(_ value: String) -> Bool {
    guard let url = URL(string: value), url.scheme == "https", url.host == "github.com" else {
      return false
    }
    return url.pathComponents.contains("tree")
  }

  private struct GitHubWorkflowDirectoryReference {
    var owner: String
    var repository: String
    var branch: String
    var workflowPath: String
  }

  private func resolveGitHubWorkflowDirectory(_ value: String, workingDirectory: URL) throws -> URL {
    let reference = try parseGitHubWorkflowDirectoryURL(value)
    let cacheRoot = workingDirectory.appendingPathComponent(".riela/workflow-checkout-sources", isDirectory: true)
    let cacheDirectory = cacheRoot.appendingPathComponent(gitHubCheckoutCacheKey(reference), isDirectory: true)
    let workflowDirectory = cacheDirectory.appendingPathComponent(reference.workflowPath, isDirectory: true)
    if FileManager.default.fileExists(atPath: workflowDirectory.appendingPathComponent("workflow.json").path) {
      return workflowDirectory
    }
    if FileManager.default.fileExists(atPath: cacheDirectory.path) {
      try FileManager.default.removeItem(at: cacheDirectory)
    }
    try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    let repositoryURL = "https://github.com/\(reference.owner)/\(reference.repository).git"
    try runGit(["clone", "--depth", "1", "--filter=blob:none", "--sparse", "--branch", reference.branch, repositoryURL, cacheDirectory.path])
    try runGit(["-C", cacheDirectory.path, "sparse-checkout", "set", reference.workflowPath])
    guard FileManager.default.fileExists(atPath: workflowDirectory.appendingPathComponent("workflow.json").path) else {
      throw CLIUsageError("workflow checkout GitHub URL did not resolve to a workflow.json: \(value)")
    }
    return workflowDirectory
  }

  private func parseGitHubWorkflowDirectoryURL(_ value: String) throws -> GitHubWorkflowDirectoryReference {
    guard let url = URL(string: value), url.scheme == "https", url.host == "github.com" else {
      throw CLIUsageError("workflow checkout requires a GitHub workflow directory URL")
    }
    let components = url.pathComponents.filter { $0 != "/" }
    guard components.count >= 5, components[2] == "tree" else {
      throw CLIUsageError("workflow checkout requires a GitHub workflow directory URL")
    }
    let owner = components[0]
    let repository = components[1]
    let branch = components[3]
    let workflowPath = components.dropFirst(4).joined(separator: "/")
    guard
      isSafeGitHubCheckoutComponent(owner),
      isSafeGitHubCheckoutComponent(repository),
      isSafeGitHubCheckoutComponent(branch),
      !workflowPath.isEmpty,
      workflowPath.split(separator: "/").allSatisfy({ isSafeGitHubCheckoutComponent(String($0)) })
    else {
      throw CLIUsageError("workflow checkout GitHub URL contains unsafe path components")
    }
    return GitHubWorkflowDirectoryReference(owner: owner, repository: repository, branch: branch, workflowPath: workflowPath)
  }

  private func gitHubCheckoutCacheKey(_ reference: GitHubWorkflowDirectoryReference) -> String {
    let raw = [reference.owner, reference.repository, reference.branch, reference.workflowPath].joined(separator: "-")
    let sanitized = raw.unicodeScalars.map { scalar in
      isParityASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-"
        ? String(Character(scalar))
        : "-"
    }.joined()
    return "github-\(sanitized)"
  }

  private func isSafeGitHubCheckoutComponent(_ value: String) -> Bool {
    guard !value.isEmpty, value != ".", value != "..", value.unicodeScalars.count <= 120 else {
      return false
    }
    return value.unicodeScalars.allSatisfy { scalar in
      isParityASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-"
    }
  }

  private func runGit(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    process.standardOutput = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw CLIUsageError("workflow checkout failed to start git: \(error)")
    }
    guard process.terminationStatus == 0 else {
      let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw CLIUsageError("workflow checkout git failed: \(stderr ?? "exit \(process.terminationStatus)")")
    }
  }

  private func workflowNameFromGitHubDirectoryURL(_ value: String) throws -> String {
    guard let url = URL(string: value), url.host == "github.com" else {
      throw CLIUsageError("workflow checkout requires a GitHub workflow directory URL")
    }
    let components = url.pathComponents.filter { $0 != "/" }
    guard let treeIndex = components.firstIndex(of: "tree"), components.count > treeIndex + 2 else {
      throw CLIUsageError("workflow checkout requires a GitHub workflow directory URL")
    }
    let name = components.last ?? ""
    guard isSafeScopedWorkflowName(name) else {
      throw CLIUsageError("invalid scoped workflow name '\(name)'")
    }
    return name
  }

  private func writeWorkflowCheckoutRecord(
    workflowName: String,
    checkoutTarget: String,
    source: URL,
    destination: URL,
    scope: WorkflowScope,
    workingDirectory: URL
  ) throws {
    let recordRoot = workingDirectory.appendingPathComponent(".riela/workflow-checkouts", isDirectory: true)
    try FileManager.default.createDirectory(at: recordRoot, withIntermediateDirectories: true)
    try jsonString([
      "workflowName": .string(workflowName),
      "checkoutUrl": .string(checkoutTarget),
      "sourceDirectory": .string(source.path),
      "destinationDirectory": .string(destination.path),
      "scope": .string(scope.rawValue),
      "installType": .string("workflow-checkout"),
      "managedBy": .string("workflow checkout"),
    ] as JSONObject).write(to: recordRoot.appendingPathComponent("\(workflowName).json"), atomically: true, encoding: .utf8)
  }
}

public struct WorkflowPackageCommandRunner: Sendable {
  public init() {}

  public func run(_ command: PackageCommand) async -> CLICommandResult {
    let options = command.options
    do {
      if command.kind == .registry {
        return try registryCommand(options: options)
      }
      let parsed = try ParsedParityOptions(options.arguments)
      switch command.kind {
      case .search, .list, .status:
        let packages = try await packageSummaries(options: options, parsed: parsed)
        let filtered = filter(packages, target: options.target, command: command.kind)
        let result = WorkflowPackageCommandResult(
          scope: options.scope,
          command: command.kind.rawValue,
          target: options.target,
          packages: filtered,
          destinationDirectory: nil,
          dryRun: parsed.dryRun,
          message: filtered.isEmpty ? "no packages found" : "packages found: \(filtered.count)",
          runSessionId: nil
        )
        return try renderPackage(result, output: options.output)
      case .registry:
        throw CLIUsageError("unreachable package registry command")
      case .install, .checkout:
        let destination = try await installPackage(target: options.target, parsed: parsed)
        let result = WorkflowPackageCommandResult(
          scope: options.scope,
          command: command.kind.rawValue,
          target: options.target,
          packages: [],
          destinationDirectory: destination.path,
          dryRun: parsed.dryRun,
          message: parsed.dryRun ? "package \(command.kind.rawValue) dry run" : "package \(command.kind.rawValue) completed",
          runSessionId: nil
        )
        return try renderPackage(result, output: options.output)
      case .update:
        guard let target = options.target, !target.isEmpty else {
          throw CLIUsageError("\(options.scope) update requires a package name")
        }
        let packages = try await packageSummaries(options: options, parsed: parsed).filter { $0.name == target }
        guard !packages.isEmpty else {
          throw CLIUsageError("installed package not found: \(target)")
        }
        let result = WorkflowPackageCommandResult(scope: options.scope, command: command.kind.rawValue, target: target, packages: packages, destinationDirectory: nil, dryRun: parsed.dryRun, message: "package update checked \(target)", runSessionId: nil)
        return try renderPackage(result, output: options.output)
      case .remove:
        let destination = try removePackage(target: options.target, parsed: parsed)
        let result = WorkflowPackageCommandResult(scope: options.scope, command: command.kind.rawValue, target: options.target, packages: [], destinationDirectory: destination.path, dryRun: parsed.dryRun, message: parsed.dryRun ? "package remove dry run" : "package removed", runSessionId: nil)
        return try renderPackage(result, output: options.output)
      case .run, .tempRun:
        return try await runPackage(command: command, parsed: parsed)
      case .publish:
        if parsed.dryRun {
          let published = try await publishPackage(target: options.target, parsed: parsed)
          let result = WorkflowPackageCommandResult(scope: options.scope, command: command.kind.rawValue, target: options.target, packages: [published.summary], destinationDirectory: published.registryRecord.path, dryRun: true, message: "package publish dry run completed", runSessionId: nil)
          return try renderPackage(result, output: options.output)
        }
        let published = try await publishPackage(target: options.target, parsed: parsed)
        let result = WorkflowPackageCommandResult(
          scope: options.scope,
          command: command.kind.rawValue,
          target: options.target,
          packages: [published.summary],
          destinationDirectory: published.registryRecord.path,
          dryRun: false,
          message: "package publish metadata recorded",
          runSessionId: nil
        )
        return try renderPackage(result, output: options.output)
      }
    } catch let error as CLIUsageError {
      return failure(error.message, output: options.output, options: options)
    } catch {
      return failure("\(error)", output: options.output, options: options)
    }
  }

  private func registryCommand(options: CLICommandOptions) throws -> CLICommandResult {
    guard let action = options.target else {
      throw CLIUsageError("package registry supports: add, list")
    }
    let registryId: String?
    let optionArguments: [String]
    if action == "add", let first = options.arguments.first, !first.hasPrefix("--") {
      registryId = first
      optionArguments = Array(options.arguments.dropFirst())
    } else {
      registryId = nil
      optionArguments = options.arguments
    }
    let parsed = try ParsedParityOptions(optionArguments)
    switch action {
    case "list":
      let config = try loadRegistryConfig(parsed: parsed)
      return try renderRegistryConfig(config, output: options.output)
    case "add":
      guard let registryId, !registryId.isEmpty, let registryURL = parsed.registryURL, !registryURL.isEmpty else {
        throw CLIUsageError("package registry add requires <id> and --registry-url <url>")
      }
      let config = try registerRegistry(id: registryId, url: registryURL, parsed: parsed)
      return try renderRegistryConfig(config, output: options.output, text: "registered package registry: \(registryId)\n")
    default:
      throw CLIUsageError("package registry supports: add, list")
    }
  }

  private func runPackage(command: PackageCommand, parsed: ParsedParityOptions) async throws -> CLICommandResult {
    guard let target = command.options.target, !target.isEmpty else {
      throw CLIUsageError("\(command.options.scope) \(command.kind.rawValue) requires a package name")
    }
    let packageDirectory = try packageDirectory(target: target, parsed: parsed)
    let manifestURL = packageDirectory.appendingPathComponent("riela-package.json")
    let loader = FileWorkflowPackageManifestLoader()
    let manifest = try await loader.loadManifest(from: manifestURL)
    let issues = await loader.validate(manifest, packageRoot: packageDirectory)
    guard issues.isEmpty else {
      throw CLIUsageError("package source validation failed: \(issues.map { "\($0.path): \($0.message)" }.joined(separator: "; "))")
    }
    let workflowDirectory = packageWorkflowDirectory(manifest.workflowDirectory, packageDirectory: packageDirectory)
    let bundle = try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
      workflowName: workflowDirectory.lastPathComponent,
      scope: .direct,
      workflowDefinitionDir: workflowDirectory.path,
      workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    ))
    if parsed.dryRun {
      let packageResult = WorkflowPackageCommandResult(
        scope: command.options.scope,
        command: command.kind.rawValue,
        target: target,
        packages: [
          WorkflowPackageSummary(
            name: manifest.name,
            version: manifest.version,
            kind: manifest.kind,
            packageDirectory: packageDirectory.path,
            workflowDirectory: manifest.workflowDirectory,
            valid: true,
            issues: []
          ),
        ],
        destinationDirectory: packageDirectory.path,
        dryRun: true,
        message: "package \(command.kind.rawValue) dry run planned without workflow execution",
        runSessionId: nil
      )
      return try renderPackage(packageResult, output: command.options.output)
    }
    let variables = try parsed.variables.map { try JSONReferenceLoader().object(from: $0, workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath) } ?? [:]
    let adapter: any NodeAdapter
    if let scenarioPath = parsed.mockScenarioPath {
      adapter = try ScenarioNodeAdapter(
        scenario: WorkflowMockScenarioLoader().loadScenario(at: absoluteURL(
          scenarioPath,
          relativeTo: URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath)
        ).path),
        fallback: DeterministicLocalNodeAdapter()
      )
    } else {
      adapter = DeterministicLocalNodeAdapter()
    }
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    let storeRoot = CLIWorkflowSessionStore.resolveRootDirectory(
      sessionStore: parsed.sessionStore,
      scope: parsed.scope,
      workingDirectory: workingDirectory
    )
    let persistedResolution = CLIWorkflowSessionResolution.resolutionForPersistence(
      resolution: WorkflowResolutionOptions(
        workflowName: workflowDirectory.lastPathComponent,
        scope: .direct,
        workflowDefinitionDir: workflowDirectory.path,
        workingDirectory: workingDirectory
      ),
      resolvedSourceScope: .direct
    )
    let runtimeStore = InMemoryWorkflowRuntimeStore()
    try await seedRuntimeStoreFromPersistedCLIState(runtimeStore, sessionStoreRoot: storeRoot)
    let result = try await DeterministicWorkflowRunner(
      store: runtimeStore,
      adapter: adapter,
      stdioNodeExecutor: LocalWorkflowStdioNodeExecutor()
    ).run(DeterministicWorkflowRunRequest(workflow: bundle.workflow, nodePayloads: bundle.nodePayloads, variables: variables))
    try CLIWorkflowSessionStore(rootDirectory: storeRoot).save(PersistedCLIWorkflowSession(
      workflowName: workflowDirectory.lastPathComponent,
      session: result.session,
      resolution: persistedResolution,
      mockScenarioPath: parsed.mockScenarioPath
    ))
    let workflowMessages = try await runtimeStore.listMessages(for: result.session.sessionId, toStepId: nil)
    try FileWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot)).save(
      WorkflowRuntimePersistenceProjector.snapshot(session: result.session, workflowMessages: workflowMessages)
    )
    let packageResult = WorkflowPackageCommandResult(
      scope: command.options.scope,
      command: command.kind.rawValue,
      target: target,
      packages: [],
      destinationDirectory: packageDirectory.path,
      dryRun: parsed.dryRun,
      message: "package \(command.kind.rawValue) completed",
      runSessionId: result.session.sessionId
    )
    if command.options.output == .json {
      return CLICommandResult(exitCode: CLIExitCode(rawValue: result.exitCode) ?? .failure, stdout: try jsonString(packageResult))
    }
    return CLICommandResult(
      exitCode: CLIExitCode(rawValue: result.exitCode) ?? .failure,
      stdout: "package \(command.kind.rawValue) completed\nsessionId: \(result.session.sessionId)\nstatus: \(result.status.rawValue)\n"
    )
  }

  private func packageDirectory(target: String, parsed: ParsedParityOptions) throws -> URL {
    let workingDirectory = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
    guard WorkflowPackageManifestValidator.isSafePackageName(target) else {
      throw CLIUsageError("invalid package name '\(target)'")
    }
    if let source = parsed.source {
      return absoluteURL(source, relativeTo: workingDirectory)
    }
    let root = packageRoot(scope: parsed.scope, workingDirectory: workingDirectory).standardizedFileURL
    let directory = root.appendingPathComponent(target, isDirectory: true).standardizedFileURL
    guard isURL(directory, containedIn: root) else {
      throw CLIUsageError("invalid package name '\(target)'")
    }
    return directory
  }

  private struct PublishedPackageRecord {
    var summary: WorkflowPackageSummary
    var registryRecord: URL
  }

  private struct PublishRegistryResolution {
    var id: String
    var url: String
    var branch: String
    var localPath: String?
  }

  private func publishPackage(target: String?, parsed: ParsedParityOptions) async throws -> PublishedPackageRecord {
    guard let target, !target.isEmpty else {
      throw CLIUsageError("package publish requires a workflow directory")
    }
    guard parsed.dryRun || parsed.overwrite else {
      throw CLIUsageError("package publish write mode needs explicit --yes or --force approval")
    }
    let workingDirectory = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
    let workflowDirectory = absoluteURL(target, relativeTo: workingDirectory).standardizedFileURL
    guard FileManager.default.fileExists(atPath: workflowDirectory.appendingPathComponent("workflow.json").path) else {
      throw CLIUsageError("package publish workflow directory must contain workflow.json: \(workflowDirectory.path)")
    }
    let bundle = try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
      workflowName: workflowDirectory.lastPathComponent,
      scope: .direct,
      workflowDefinitionDir: workflowDirectory.path,
      workingDirectory: workingDirectory.path
    ))
    let packageName = parsed.packageName ?? parsed.packageID ?? bundle.workflow.workflowId
    guard WorkflowPackageManifestValidator.isSafePackageName(packageName) else {
      throw CLIUsageError("invalid package name '\(packageName)'")
    }
    let registryConfig = try loadRegistryConfig(parsed: parsed)
    let registry = try resolvePublishRegistry(config: registryConfig, parsed: parsed)
    let packageKey = packageFilesystemKey(packageName)
    let registryRoot = workingDirectory.appendingPathComponent(".riela/package-registry", isDirectory: true)
    let registryRecord = registryRoot.appendingPathComponent("\(packageKey).json")
    let summary = WorkflowPackageSummary(
      name: packageName,
      version: "0.1.0",
      kind: .workflow,
      packageDirectory: workflowDirectory.path,
      workflowDirectory: ".",
      valid: true,
      issues: []
    )
    if parsed.dryRun {
      return PublishedPackageRecord(summary: summary, registryRecord: registryRecord)
    }
    let cacheRoot = workingDirectory.appendingPathComponent(".riela/package-cache", isDirectory: true)
    let lockRoot = workingDirectory.appendingPathComponent(".riela/package-locks", isDirectory: true)
    let skillsRoot = workingDirectory.appendingPathComponent(".riela/skills", isDirectory: true)
    let nativeEvidenceRoot = workingDirectory.appendingPathComponent(".riela/package-native-addons", isDirectory: true)
    try FileManager.default.createDirectory(at: registryRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: lockRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nativeEvidenceRoot, withIntermediateDirectories: true)
    let cacheRecord = cacheRoot.appendingPathComponent("\(packageKey).json")
    let lockRecord = lockRoot.appendingPathComponent("\(packageKey).json")
    let nativeEvidenceRecord = nativeEvidenceRoot.appendingPathComponent("\(packageKey).json")
    let skillDirectory = skillsRoot.appendingPathComponent(packageKey, isDirectory: true)
    try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
    try jsonString([
      "packageName": .string(packageName),
      "packageId": .string(packageName),
      "workflowName": .string(bundle.workflow.workflowId),
      "workflowDirectory": .string(workflowDirectory.path),
      "registry": .string(registry.id),
      "registryUrl": .string(registry.url),
      "registryRef": .string(registry.branch),
      "mode": .string("direct"),
      "dryRun": .bool(parsed.dryRun),
    ] as JSONObject).write(to: registryRecord, atomically: true, encoding: .utf8)
    try jsonString(summary).write(to: cacheRecord, atomically: true, encoding: .utf8)
    try jsonString([
      "name": .string(packageName),
      "version": .string("0.1.0"),
      "registry": .string(registry.id),
      "registryUrl": .string(registry.url),
      "registryRef": .string(registry.branch),
      "checksum": .string("swift-deterministic-publish-record"),
      "checksumAlgorithm": .string("swift-deterministic"),
    ] as JSONObject).write(to: lockRecord, atomically: true, encoding: .utf8)
    try jsonString([
      "packageName": .string(packageName),
      "nativeAddonCount": .number(0),
      "nativeAddonNames": .array([]),
      "dependencyNativeLockCount": .number(0),
      "evidence": .string("validated-manifest-native-addon-publish-record"),
    ] as JSONObject).write(to: nativeEvidenceRecord, atomically: true, encoding: .utf8)
    try """
    # \(packageName)

    Swift-projected workflow package skill for deterministic local package execution.
    """.write(to: skillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    if let registryLocalPath = registry.localPath {
      let localRegistryRoot = absoluteURL(registryLocalPath, relativeTo: workingDirectory)
      let packageTarget = localRegistryRoot
        .appendingPathComponent("packages", isDirectory: true)
        .appendingPathComponent(packageKey, isDirectory: true)
      let workflowTarget = packageTarget.appendingPathComponent("workflow", isDirectory: true)
      try FileManager.default.createDirectory(at: packageTarget, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: workflowTarget.path) {
        try FileManager.default.removeItem(at: workflowTarget)
      }
      try FileManager.default.copyItem(at: workflowDirectory, to: workflowTarget)
      let registryIndex = localRegistryRoot.appendingPathComponent("registry", isDirectory: true)
      try FileManager.default.createDirectory(at: registryIndex, withIntermediateDirectories: true)
      try jsonString([
        "packageName": .string(packageName),
        "workflowName": .string(bundle.workflow.workflowId),
        "sourcePath": .string("packages/\(packageKey)"),
        "registryId": .string(registry.id),
        "registryUrl": .string(registry.url),
        "sourceBranch": .string(registry.branch),
      ] as JSONObject).write(to: registryIndex.appendingPathComponent("\(packageKey).json"), atomically: true, encoding: .utf8)
    }
    return PublishedPackageRecord(summary: summary, registryRecord: registryRecord)
  }

  private func resolvePublishRegistry(config: WorkflowPackageRegistryConfig, parsed: ParsedParityOptions) throws -> PublishRegistryResolution {
    let selector = parsed.registry
    let selectorIsURL = selector.map(isSupportedRegistryURL) ?? false
    let explicitURL = parsed.registryURL ?? (selectorIsURL ? selector : nil)
    if let explicitURL {
      guard isSupportedRegistryURL(explicitURL) else {
        throw CLIUsageError("registry URL must be https://github.com/<owner>/<repo>")
      }
      let registered = config.registries.first { entry in
        entry.url == explicitURL || entry.id == selector
      }
      return PublishRegistryResolution(
        id: registered?.id ?? directRegistryId(for: explicitURL),
        url: explicitURL,
        branch: parsed.branch ?? registered?.defaultBranch ?? "main",
        localPath: parsed.localPath ?? registered?.localPath
      )
    }
    if let selector {
      guard let registered = config.registries.first(where: { $0.id == selector }) else {
        throw CLIUsageError("package registry not found: \(selector)")
      }
      return PublishRegistryResolution(
        id: registered.id,
        url: registered.url,
        branch: parsed.branch ?? registered.defaultBranch,
        localPath: parsed.localPath ?? registered.localPath
      )
    }
    if let registered = config.registries.first(where: { $0.id == config.defaultRegistryId }) ?? config.registries.first {
      return PublishRegistryResolution(
        id: registered.id,
        url: registered.url,
        branch: parsed.branch ?? registered.defaultBranch,
        localPath: parsed.localPath ?? registered.localPath
      )
    }
    return PublishRegistryResolution(
      id: config.defaultRegistryId,
      url: "local",
      branch: parsed.branch ?? "main",
      localPath: parsed.localPath
    )
  }

  private func loadRegistryConfig(parsed: ParsedParityOptions) throws -> WorkflowPackageRegistryConfig {
    let url = registryConfigURL(parsed: parsed)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return defaultRegistryConfig()
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(WorkflowPackageRegistryConfig.self, from: data)
  }

  private func defaultRegistryConfig() -> WorkflowPackageRegistryConfig {
    WorkflowPackageRegistryConfig(defaultRegistryId: "local", registries: [])
  }

  private func saveRegistryConfig(_ config: WorkflowPackageRegistryConfig, parsed: ParsedParityOptions) throws {
    let url = registryConfigURL(parsed: parsed)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try jsonString(config).write(to: url, atomically: true, encoding: .utf8)
  }

  private func registerRegistry(id: String, url registryURL: String, parsed: ParsedParityOptions) throws -> WorkflowPackageRegistryConfig {
    guard isSafeRegistryId(id) else {
      throw CLIUsageError("invalid registry id '\(id)'")
    }
    guard isSupportedRegistryURL(registryURL) else {
      throw CLIUsageError("registry URL must be https://github.com/<owner>/<repo>")
    }
    var config = try loadRegistryConfig(parsed: parsed)
    let now = "2026-06-16T00:00:00Z"
    let existing = config.registries.first { $0.id == id }
    let entry = WorkflowPackageRegistryEntry(
      id: id,
      url: registryURL,
      defaultBranch: parsed.branch ?? existing?.defaultBranch ?? "main",
      localPath: parsed.localPath ?? existing?.localPath,
      registeredAt: existing?.registeredAt ?? now,
      updatedAt: now
    )
    config.defaultRegistryId = config.registries.isEmpty ? id : config.defaultRegistryId
    config.registries = [entry] + config.registries.filter { $0.id != id }
    try saveRegistryConfig(config, parsed: parsed)
    return config
  }

  private func packageWorkflowDirectory(_ rawPath: String?, packageDirectory: URL) -> URL {
    guard let rawPath, rawPath != "." else {
      return packageDirectory.standardizedFileURL
    }
    if rawPath.hasPrefix("/") {
      return URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
    }
    return packageDirectory.appendingPathComponent(rawPath, isDirectory: true).standardizedFileURL
  }

  private func packageSummaries(options: CLICommandOptions, parsed: ParsedParityOptions) async throws -> [WorkflowPackageSummary] {
    let workingDirectory = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
    let roots = packageRoots(parsed: parsed, workingDirectory: workingDirectory)
    let loader = FileWorkflowPackageManifestLoader()
    var summaries: [WorkflowPackageSummary] = []
    for root in roots where FileManager.default.fileExists(atPath: root.path) {
      for manifestURL in try packageManifestURLs(in: root) {
        let url = manifestURL.deletingLastPathComponent()
        let manifest = try await loader.loadManifest(from: manifestURL)
        let issues = await loader.validate(manifest, packageRoot: url)
        summaries.append(WorkflowPackageSummary(
          name: manifest.name,
          version: manifest.version,
          kind: manifest.kind,
          packageDirectory: url.path,
          workflowDirectory: manifest.workflowDirectory,
          valid: issues.isEmpty,
          issues: issues
        ))
      }
    }
    return summaries.sorted { $0.name == $1.name ? $0.packageDirectory < $1.packageDirectory : $0.name < $1.name }
  }

  private func filter(_ packages: [WorkflowPackageSummary], target: String?, command: PackageCommandKind) -> [WorkflowPackageSummary] {
    guard let target, !target.isEmpty else {
      return packages
    }
    switch command {
    case .search:
      return packages.filter { $0.name.localizedCaseInsensitiveContains(target) }
    default:
      return packages.filter { $0.name == target }
    }
  }

  private func installPackage(target: String?, parsed: ParsedParityOptions) async throws -> URL {
    guard let target, !target.isEmpty else {
      throw CLIUsageError("package install requires a package name")
    }
    guard WorkflowPackageManifestValidator.isSafePackageName(target) else {
      throw CLIUsageError("invalid package name '\(target)'")
    }
    guard let source = parsed.source else {
      throw CLIUsageError("package install requires --source <package-dir> for deterministic Swift local install")
    }
    let workingDirectory = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
    let sourceURL = absoluteURL(source, relativeTo: workingDirectory)
    guard FileManager.default.fileExists(atPath: sourceURL.appendingPathComponent("riela-package.json").path) else {
      throw CLIUsageError("package source must contain riela-package.json: \(sourceURL.path)")
    }
    let loader = FileWorkflowPackageManifestLoader()
    let manifest = try await loader.loadManifest(from: sourceURL.appendingPathComponent("riela-package.json"))
    let issues = await loader.validate(manifest, packageRoot: sourceURL)
    guard issues.isEmpty else {
      throw CLIUsageError("package source validation failed: \(issues.map { "\($0.path): \($0.message)" }.joined(separator: "; "))")
    }
    let destination = packageRoot(scope: parsed.scope, workingDirectory: workingDirectory).appendingPathComponent(target, isDirectory: true)
    if parsed.dryRun {
      return destination
    }
    if FileManager.default.fileExists(atPath: destination.path) {
      guard parsed.overwrite else {
        throw CLIUsageError("package destination already exists: \(destination.path); pass --overwrite to replace it")
      }
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: sourceURL, to: destination)
    return destination
  }

  private func removePackage(target: String?, parsed: ParsedParityOptions) throws -> URL {
    guard let target, !target.isEmpty else {
      throw CLIUsageError("package remove requires a package name")
    }
    guard WorkflowPackageManifestValidator.isSafePackageName(target) else {
      throw CLIUsageError("invalid package name '\(target)'")
    }
    let workingDirectory = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
    let root = packageRoot(scope: parsed.scope, workingDirectory: workingDirectory).standardizedFileURL
    let destination = root.appendingPathComponent(target, isDirectory: true).standardizedFileURL
    guard isURL(destination, containedIn: root) else {
      throw CLIUsageError("invalid package name '\(target)'")
    }
    guard FileManager.default.fileExists(atPath: destination.path) else {
      throw CLIUsageError("installed package not found: \(target)")
    }
    if !parsed.dryRun {
      try FileManager.default.removeItem(at: destination)
    }
    return destination
  }
}

public struct SessionContinueCommand: Sendable {
  public init() {}

  public func run(_ options: CLICommandOptions) async -> CLICommandResult {
    guard let sessionId = options.target else {
      return CLICommandResult(exitCode: .usage, stderr: "session continue requires a session id")
    }
    do {
      let parsed = try ParsedParityOptions(options.arguments)
      return await SessionResumeCommand().run(SessionResumeOptions(
        sessionId: sessionId,
        output: options.output,
        scope: parsed.scope,
        workflowDefinitionDir: parsed.workflowDefinitionDir,
        workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath,
        mockScenarioPath: parsed.mockScenarioPath,
        sessionStore: parsed.sessionStore
      ))
    } catch let error as CLIUsageError {
      return failure(error.message, output: options.output, options: options)
    } catch {
      return failure("\(error)", output: options.output, options: options)
    }
  }
}

public struct ScopedParityCommandRunner: Sendable {
  public init() {}

  public func run(_ command: ScopedCommand) async -> CLICommandResult {
    do {
      let options = command.options
      let parityArguments: [String]
      if (command.kind == .callStep || command.kind == .workflowCall),
        let first = options.arguments.first,
        !first.hasPrefix("--")
      {
        parityArguments = Array(options.arguments.dropFirst())
      } else if command.kind == .events,
        options.command == "schedules",
        let first = options.arguments.first,
        !first.hasPrefix("--")
      {
        parityArguments = Array(options.arguments.dropFirst())
      } else {
        parityArguments = options.arguments
      }
      let parsed = try ParsedParityOptions(parityArguments)
      switch command.kind {
      case .callStep, .workflowCall:
        return await callStep(options: options, parsed: parsed)
      case .graphql, .gql:
        let result = try graphqlResult(kind: command.kind, options: options, parsed: parsed)
        return try render(result, options: options) { result in result.records.joined(separator: "\n") + "\n" }
      case .hook:
        let vendor = try hookVendor(options.command ?? "codex")
        let payload = try hookPayload(options: options, parsed: parsed)
        let parsedHook = try HookParsing.parse(payload, vendor: vendor)
        let result = ScopedParityCommandResult(scope: command.kind.rawValue, command: options.command, target: options.target, status: "ok", records: ["vendor=\(parsedHook.context.vendor.rawValue)", "event=\(parsedHook.context.eventName)", "agentSessionId=\(parsedHook.context.agentSessionId)"])
        return try render(result, options: options) { result in result.records.joined(separator: "\n") + "\n" }
      case .events:
        let result = try await eventResult(options: options, parsed: parsed)
        return try render(result, options: options) { result in result.records.joined(separator: "\n") + "\n" }
      case .serve:
        let response = try await serverResponse(options: options, parsed: parsed)
        let result = ScopedParityCommandResult(scope: command.kind.rawValue, command: options.command, target: options.target, status: response.status == 200 ? "ok" : "failed", records: ["status=\(response.status)", "body=\(response.body)"])
        return try render(result, options: options) { result in result.records.joined(separator: "\n") + "\n" }
      }
    } catch let error as CLIUsageError {
      return failure(error.message, output: command.options.output, options: command.options)
    } catch {
      return failure("\(error)", output: command.options.output, options: command.options)
    }
  }

  private func graphqlResult(kind: ScopedCommandKind, options: CLICommandOptions, parsed: ParsedParityOptions) throws -> ScopedParityCommandResult {
    let action = options.command ?? "schema"
    let records: [String]
    switch action {
    case "schema":
      records = [GraphQLContractProjector.schemaContract]
    case "session", "inspect-session", "workflow-session":
      let snapshot = try loadRuntimeSnapshot(sessionId: options.target, parsed: parsed, action: action)
      let projected = GraphQLContractProjector.project(
        session: snapshot.session,
        communications: snapshot.workflowMessages
      )
      records = [try jsonString(projected)]
    case "manager-session":
      let snapshot = try loadRuntimeSnapshot(sessionId: options.target, parsed: parsed, action: action)
      let view = GraphQLManagerSessionViewDTO(
        session: .object([
          "sessionId": .string(snapshot.session.sessionId),
          "workflowId": .string(snapshot.session.workflowId),
          "status": .string(snapshot.session.status.rawValue),
        ]),
        messages: .array(snapshot.workflowMessages.map { .string($0.communicationId) })
      )
      records = [try jsonString(view)]
    case "send-manager-message":
      var snapshot = try loadRuntimeSnapshot(sessionId: options.target, parsed: parsed, action: action)
      let managerPayload = try managerMessagePayload(parsed: parsed, action: action)
      let sourceExecution = try latestExecution(snapshot: snapshot, action: action)
      let nextOrder = (snapshot.workflowMessages.map(\.createdOrder).max() ?? 0) + 1
      let communicationId = "graphql-manager-\(snapshot.session.sessionId)-\(nextOrder)"
      let message = WorkflowMessageRecord(
        communicationId: communicationId,
        workflowExecutionId: snapshot.session.sessionId,
        fromStepId: nil,
        toStepId: snapshot.session.currentStepId ?? sourceExecution.stepId,
        routingScope: .workflow,
        deliveryKind: .direct,
        sourceStepExecutionId: sourceExecution.executionId,
        payload: managerPayload,
        lifecycleStatus: .delivered,
        createdOrder: nextOrder,
        createdAt: Date(timeIntervalSince1970: Double(nextOrder))
      )
      snapshot.workflowMessages.append(message)
      try runtimePersistenceStore(parsed: parsed).save(snapshot)
      records = [try jsonString(GraphQLSendManagerMessagePayload(
        accepted: true,
        managerMessageId: communicationId,
        parsedIntent: [GraphQLManagerIntentSummaryDTO(kind: "message", targetId: message.toStepId, reason: "persisted manager-control message")],
        createdCommunicationIds: [communicationId],
        queuedNodeIds: message.toStepId.map { [$0] } ?? [],
        workflowId: snapshot.session.workflowId,
        workflowExecutionId: snapshot.session.sessionId,
        managerSessionId: snapshot.session.sessionId
      ))]
    case "replay-communication":
      let communicationId = try requiredGraphQLTarget(options: options, action: action)
      var snapshot = try loadRuntimeSnapshot(containingCommunicationId: communicationId, parsed: parsed, action: action)
      guard let source = snapshot.workflowMessages.first(where: { $0.communicationId == communicationId }) else {
        throw CLIUsageError("graphql \(action) communication not found: \(communicationId)")
      }
      let nextOrder = (snapshot.workflowMessages.map(\.createdOrder).max() ?? 0) + 1
      let replayedId = "\(communicationId)-replay-\(nextOrder)"
      snapshot.workflowMessages.append(WorkflowMessageRecord(
        communicationId: replayedId,
        workflowExecutionId: source.workflowExecutionId,
        fromStepId: source.fromStepId,
        toStepId: source.toStepId,
        routingScope: source.routingScope,
        deliveryKind: source.deliveryKind,
        sourceStepExecutionId: source.sourceStepExecutionId,
        transitionCondition: source.transitionCondition,
        payload: source.payload,
        artifactRefs: source.artifactRefs,
        lifecycleStatus: .delivered,
        createdOrder: nextOrder,
        createdAt: Date(timeIntervalSince1970: Double(nextOrder))
      ))
      try runtimePersistenceStore(parsed: parsed).save(snapshot)
      records = [try jsonString(GraphQLReplayCommunicationPayload(sourceCommunicationId: communicationId, workflowExecutionId: snapshot.session.sessionId, replayedCommunicationId: replayedId, status: "replayed"))]
    case "retry-communication-delivery", "retry-communication":
      let communicationId = try requiredGraphQLTarget(options: options, action: action)
      let snapshot = try loadRuntimeSnapshot(containingCommunicationId: communicationId, parsed: parsed, action: action)
      guard snapshot.workflowMessages.contains(where: { $0.communicationId == communicationId }) else {
        throw CLIUsageError("graphql \(action) communication not found: \(communicationId)")
      }
      records = [try jsonString(GraphQLRetryCommunicationDeliveryPayload(communicationId: communicationId, activeDeliveryAttemptId: "\(communicationId)-retry", status: "queued"))]
    default:
      throw CLIUsageError("unknown graphql command '\(action)'")
    }
    return ScopedParityCommandResult(scope: kind.rawValue, command: options.command, target: options.target, status: "ok", records: records)
  }

  private func managerMessagePayload(parsed: ParsedParityOptions, action: String) throws -> JSONObject {
    if parsed.messageJSON != nil && parsed.messageFile != nil {
      throw CLIUsageError("graphql \(action) accepts only one of --message-json or --message-file")
    }
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    if let messageJSON = parsed.messageJSON {
      return try JSONReferenceLoader().object(from: messageJSON, workingDirectory: workingDirectory)
    }
    if let messageFile = parsed.messageFile {
      return try JSONReferenceLoader().object(from: messageFile, workingDirectory: workingDirectory)
    }
    throw CLIUsageError("graphql \(action) requires --message-json or --message-file")
  }

  private func runtimePersistenceStore(parsed: ParsedParityOptions) -> FileWorkflowRuntimePersistenceStore {
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    let sessionRoot = CLIWorkflowSessionStore.resolveRootDirectory(
      sessionStore: parsed.sessionStore,
      scope: parsed.scope,
      workingDirectory: workingDirectory
    )
    return FileWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionRoot))
  }

  private func loadExistingWorkflowMessages(
    sessionId: String,
    persistenceStore: FileWorkflowRuntimePersistenceStore
  ) throws -> [WorkflowMessageRecord] {
    do {
      return try persistenceStore.load(sessionId: sessionId).workflowMessages
    } catch WorkflowRuntimePersistenceStoreError.notFound(_) {
      return []
    }
  }

  private func loadRuntimeSnapshot(sessionId rawSessionId: String?, parsed: ParsedParityOptions, action: String) throws -> WorkflowRuntimePersistenceSnapshot {
    let sessionId = try requiredGraphQLTargetValue(rawSessionId, action: action, label: "persisted session id")
    let store = runtimePersistenceStore(parsed: parsed)
    do {
      return try store.load(sessionId: sessionId)
    } catch WorkflowRuntimePersistenceStoreError.notFound {
      let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
      let loaded = try CLIWorkflowSessionResolution.loadPersistedSession(
        sessionId: sessionId,
        sessionStore: parsed.sessionStore,
        scope: parsed.scope,
        workingDirectory: workingDirectory
      )
      let repaired = WorkflowRuntimePersistenceProjector.snapshot(session: loaded.record.session)
      try store.save(repaired)
      return repaired
    }
  }

  private func loadRuntimeSnapshot(containingCommunicationId communicationId: String, parsed: ParsedParityOptions, action: String) throws -> WorkflowRuntimePersistenceSnapshot {
    let snapshots = try runtimePersistenceStore(parsed: parsed).loadAll()
    let matches = snapshots.filter { snapshot in
      snapshot.workflowMessages.contains { $0.communicationId == communicationId }
    }
    guard let snapshot = matches.first else {
      throw CLIUsageError("graphql \(action) communication not found: \(communicationId)")
    }
    guard matches.count == 1 else {
      throw CLIUsageError("graphql \(action) communication id is ambiguous across sessions: \(communicationId)")
    }
    return snapshot
  }

  private func requiredGraphQLTarget(options: CLICommandOptions, action: String) throws -> String {
    try requiredGraphQLTargetValue(options.target, action: action, label: "target")
  }

  private func requiredGraphQLTargetValue(_ value: String?, action: String, label: String) throws -> String {
    guard let value, !value.isEmpty else {
      throw CLIUsageError("graphql \(action) requires a \(label)")
    }
    return value
  }

  private func latestExecution(snapshot: WorkflowRuntimePersistenceSnapshot, action: String) throws -> WorkflowStepExecution {
    guard let execution = snapshot.session.executions.last else {
      throw CLIUsageError("graphql \(action) requires a persisted step execution")
    }
    return execution
  }

  private func serverResponse(options: CLICommandOptions, parsed: ParsedParityOptions) async throws -> ServerResponseDescriptor {
    let action = options.command ?? "status"
    let handler = DeterministicServerRouteHandler()
    switch action {
    case "status", "health":
      return await handler.route(ServerRequestEnvelope(method: "GET", path: "/healthz"), context: serverContext(parsed: parsed))
    case "overview":
      return await handler.route(ServerRequestEnvelope(method: "GET", path: "/overview"), context: serverContext(parsed: parsed))
    case "graphql":
      let bodyObject: JSONObject
      if let target = options.target {
        bodyObject = try JSONReferenceLoader().object(from: target, workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath)
      } else {
        bodyObject = ["query": .string(GraphQLContractProjector.schemaContract), "variables": .object([:])]
      }
      let body = try JSONEncoder().encode(JSONValue.object(bodyObject))
      return await handler.route(ServerRequestEnvelope(method: "POST", path: "/graphql", body: body), context: serverContext(parsed: parsed))
    default:
      let route = options.target ?? action
      let response = await DeterministicServerRouteHandler().route(
        ServerRequestEnvelope(method: "GET", path: route.hasPrefix("/") ? route : "/\(route)"),
        context: serverContext(parsed: parsed)
      )
      return response
    }
  }

  private func serverContext(parsed: ParsedParityOptions) -> ServerRequestContext {
    ServerRequestContext(inheritedEnvironment: parsed.sessionStore.map { ["RIELA_MANAGER_SESSION_ID": $0] } ?? [:])
  }

  private func callStep(options: CLICommandOptions, parsed: ParsedParityOptions) async -> CLICommandResult {
    guard let workflowId = options.command,
      let workflowRunId = options.target,
      let stepId = options.arguments.first,
      !stepId.hasPrefix("--")
    else {
      return CLICommandResult(exitCode: .usage, stderr: "call-step requires <workflow-id> <workflow-run-id> <step-id>")
    }
    do {
      if parsed.messageJSON != nil && parsed.messageFile != nil {
        throw CLIUsageError("use only one of --message-json or --message-file")
      }
      let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
      let persisted = try CLIWorkflowSessionResolution.loadPersistedSession(
        sessionId: workflowRunId,
        sessionStore: parsed.sessionStore,
        scope: parsed.scope,
        workingDirectory: workingDirectory
      )
      guard persisted.record.session.workflowId == workflowId else {
        throw CLIUsageError("workflow id mismatch: session '\(workflowRunId)' belongs to '\(persisted.record.session.workflowId)', not '\(workflowId)'")
      }
      guard parsed.continueSession || (persisted.record.session.status != .completed && persisted.record.session.status != .failed) else {
        throw CLIUsageError("cannot call step '\(stepId)' on terminal session '\(workflowRunId)' with status '\(persisted.record.session.status.rawValue)'")
      }
      let resolution = WorkflowResolutionOptions(
        workflowName: persisted.record.workflowName,
        scope: persisted.record.resolution.scope,
        workflowDefinitionDir: parsed.workflowDefinitionDir ?? persisted.record.resolution.workflowDefinitionDir,
        workingDirectory: workingDirectory
      )
      let bundle = try FileSystemWorkflowBundleResolver().resolve(resolution)
      guard bundle.workflow.workflowId == workflowId else {
        throw CLIUsageError("workflow '\(persisted.record.workflowName)' resolved to workflowId '\(bundle.workflow.workflowId)', not '\(workflowId)'")
      }
      guard bundle.workflow.steps.contains(where: { $0.id == stepId }) else {
        throw CLIUsageError("call-step target step not found: \(stepId)")
      }
      var workflow = bundle.workflow
      if let promptVariant = parsed.promptVariant,
        let stepIndex = workflow.steps.firstIndex(where: { $0.id == stepId })
      {
        workflow.steps[stepIndex].promptVariant = promptVariant
      }
      let persistedResolution = CLIWorkflowSessionResolution.resolutionForPersistence(
        resolution: resolution,
        resolvedSourceScope: bundle.sourceScope
      )
      var variables = try parsed.variables.map { try JSONReferenceLoader().object(from: $0, workingDirectory: resolution.workingDirectory) } ?? [:]
      if let resumeStepExecutionId = parsed.resumeStepExecutionId {
        variables["resumeStepExecId"] = .string(resumeStepExecutionId)
        variables["resumedFromNodeExecId"] = .string(resumeStepExecutionId)
      }
      let adapter: any NodeAdapter
      if let scenarioPath = parsed.mockScenarioPath {
        adapter = try ScenarioNodeAdapter(
          scenario: WorkflowMockScenarioLoader().loadScenario(at: absoluteURL(
            scenarioPath,
            relativeTo: URL(fileURLWithPath: resolution.workingDirectory)
          ).path),
          fallback: DeterministicLocalNodeAdapter()
        )
      } else {
        adapter = DeterministicLocalNodeAdapter()
      }
      let storeRoot = CLIWorkflowSessionStore.resolveRootDirectory(
        sessionStore: parsed.sessionStore,
        scope: persistedResolution.scope,
        workingDirectory: resolution.workingDirectory
      )
      let persistenceStore = FileWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot))
      let existingMessages = try loadExistingWorkflowMessages(sessionId: persisted.record.session.sessionId, persistenceStore: persistenceStore)
      let runtimeStore = InMemoryWorkflowRuntimeStore()
      var seededSession = persisted.record.session
      seededSession.status = .running
      seededSession.currentStepId = stepId
      await runtimeStore.seedSession(seededSession)
      await runtimeStore.seedWorkflowMessages(existingMessages)
      if let directMessage = try directCallMessageObject(parsed: parsed, workingDirectory: resolution.workingDirectory) {
        let sourceExecutionId = seededSession.executions.last?.executionId ?? "\(stepId)-direct-call-input"
        _ = try await runtimeStore.appendWorkflowMessage(WorkflowMessageAppendInput(
          workflowExecutionId: seededSession.sessionId,
          fromStepId: nil,
          toStepId: stepId,
          sourceStepExecutionId: sourceExecutionId,
          payload: directMessage,
          artifactRefs: []
        ))
      }
      if parsed.promptVariant != nil || parsed.resumeStepExecutionId != nil {
        let sourceExecutionId = seededSession.executions.last?.executionId ?? "\(stepId)-direct-call-overrides"
        _ = try await runtimeStore.appendWorkflowMessage(WorkflowMessageAppendInput(
          workflowExecutionId: seededSession.sessionId,
          fromStepId: nil,
          toStepId: stepId,
          sourceStepExecutionId: sourceExecutionId,
          payload: [
            "directCallPromptVariant": parsed.promptVariant.map(JSONValue.string) ?? .null,
            "directCallResumeStepExecutionId": parsed.resumeStepExecutionId.map(JSONValue.string) ?? .null,
          ],
          artifactRefs: []
        ))
      }
      let runner = DeterministicWorkflowRunner(
        store: runtimeStore,
        adapter: adapter,
        stdioNodeExecutor: LocalWorkflowStdioNodeExecutor()
      )
      let result = try await runner.run(
        DeterministicWorkflowRunRequest(
          workflow: workflow,
          nodePayloads: bundle.nodePayloads,
          variables: variables,
          maxSteps: 1,
          timeoutMs: parsed.timeoutMs,
          resumeSessionId: seededSession.sessionId
        )
      )
      let workflowMessages = try await runtimeStore.listMessages(for: result.session.sessionId, toStepId: nil)
      try CLIWorkflowSessionStore(rootDirectory: storeRoot).save(PersistedCLIWorkflowSession(
        workflowName: persisted.record.workflowName,
        session: result.session,
        resolution: persistedResolution,
        mockScenarioPath: parsed.mockScenarioPath
      ))
      try persistenceStore.save(
        WorkflowRuntimePersistenceProjector.snapshot(session: result.session, workflowMessages: workflowMessages)
      )
      let rendered = try jsonString(result)
      if options.output == .json {
        return CLICommandResult(exitCode: CLIExitCode(rawValue: result.exitCode) ?? .failure, stdout: rendered)
      }
      return CLICommandResult(exitCode: CLIExitCode(rawValue: result.exitCode) ?? .failure, stdout: "called step \(stepId)\nstatus: \(result.status.rawValue)\n")
    } catch let error as CLIUsageError {
      return failure(error.message, output: options.output, options: options)
    } catch {
      return failure("\(error)", output: options.output, options: options)
    }
  }

  private func directCallMessageObject(parsed: ParsedParityOptions, workingDirectory: String) throws -> JSONObject? {
    if let messageJSON = parsed.messageJSON {
      let data = Data(messageJSON.utf8)
      let value = try JSONDecoder().decode(JSONValue.self, from: data)
      guard case let .object(object) = value else {
        throw CLIUsageError("--message-json must decode to a JSON object for Swift deterministic input assembly")
      }
      return object
    }
    if let messageFile = parsed.messageFile {
      return try JSONReferenceLoader().object(from: messageFile, workingDirectory: workingDirectory)
    }
    return nil
  }

  private func hookVendor(_ raw: String) throws -> HookVendor {
    guard let vendor = HookVendor(rawValue: raw) else {
      throw CLIUsageError("invalid hook vendor '\(raw)'")
    }
    return vendor
  }

  private func hookPayload(options: CLICommandOptions, parsed: ParsedParityOptions) throws -> JSONObject {
    if let target = options.target {
      return try JSONReferenceLoader().object(from: target, workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath)
    }
    return [
      "session_id": .string("dry-run-session"),
      "hook_event_name": .string("SessionStart"),
      "cwd": .string(parsed.workingDirectory ?? FileManager.default.currentDirectoryPath)
    ]
  }

  private struct EventConfig: Codable {
    var sources: [EventSourceContract]
    var bindings: [EventBindingContract]
  }

  private struct PersistedEventReceipt: Codable, Equatable, Sendable {
    var receiptId: String
    var sourceId: String
    var eventId: String
    var status: String
    var duplicate: Bool
    var workflowExecutionId: String?
    var workflowName: String?
    var replayedFromReceiptId: String?
    var reason: String?
    var updatedAt: Date
    var envelope: ExternalEventEnvelope
  }

  private struct PersistedEventReply: Codable, Equatable, Sendable {
    var idempotencyKey: String
    var sourceId: String
    var status: String
    var workflowExecutionId: String?
  }

  private struct PersistedEventSchedule: Codable, Equatable, Sendable {
    var scheduleId: String
    var sourceId: String
    var status: String
    var workflowName: String
    var kind: String
    var timezone: String?
    var nextDueAt: String?
    var cancelledReason: String?
  }

  private func eventResult(options: CLICommandOptions, parsed: ParsedParityOptions) async throws -> ScopedParityCommandResult {
    let action = options.command ?? "validate"
    if let target = options.target,
      parsed.eventRoot == nil,
      FileManager.default.fileExists(atPath: absoluteURL(target, relativeTo: URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath)).path),
      (action == "validate" || action == "list" || parsed.variables != nil)
    {
      return try await legacyEventResult(options: options, parsed: parsed)
    }
    let root = eventRootURL(parsed: parsed)
    switch action {
    case "validate":
      try FileManager.default.createDirectory(at: receiptsRoot(eventRoot: root), withIntermediateDirectories: true)
      let config = try loadEventConfigIfPresent(eventRoot: root)
      let diagnostics = config.map { EventContractValidator.validate(sources: $0.sources, bindings: $0.bindings) } ?? []
      return ScopedParityCommandResult(
        scope: "events",
        command: action,
        target: options.target,
        status: diagnostics.isEmpty ? "ok" : "failed",
        records: diagnostics.isEmpty ? ["eventRoot=\(root.path)", "receipts=\(receiptsRoot(eventRoot: root).path)"] : diagnostics.map { "\($0.path): \($0.message)" }
      )
    case "emit":
      guard let sourceId = options.target, let eventFile = parsed.eventFile else {
        throw CLIUsageError("events emit requires <source-id> --event-file <path>")
      }
      let envelope = try eventEnvelope(from: JSONReferenceLoader().object(from: eventFile, workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath), sourceIdOverride: sourceId)
      let config = try loadEventConfigIfPresent(eventRoot: root)
      let triggerResult: EventDryRunResult?
      if let config {
        triggerResult = await awaitDryRun(config: config, envelope: envelope)
      } else {
        triggerResult = nil
      }
      let receiptId = safeReceiptId(sourceId: sourceId, eventId: envelope.eventId)
      if let existingReceipt = try existingEventReceipt(receiptId: receiptId, eventRoot: root) {
        return ScopedParityCommandResult(
          scope: "events",
          command: action,
          target: sourceId,
          status: "duplicate",
          records: [
            "receipt=\(existingReceipt.receiptId)",
            "status=\(existingReceipt.status)",
            "duplicate=true",
            "workflowExecutionId=\(existingReceipt.workflowExecutionId ?? "-")",
          ]
        )
      }
      let receipt = PersistedEventReceipt(
        receiptId: receiptId,
        sourceId: sourceId,
        eventId: envelope.eventId,
        status: triggerResult?.receipt?.status ?? (parsed.dryRun ? "dry-run" : "received"),
        duplicate: false,
        workflowExecutionId: nil,
        workflowName: triggerResult?.triggers.first?.workflowName,
        replayedFromReceiptId: nil,
        reason: nil,
        updatedAt: Date(timeIntervalSince1970: 0),
        envelope: envelope
      )
      try saveEventReceipt(receipt, eventRoot: root)
      return ScopedParityCommandResult(
        scope: "events",
        command: action,
        target: sourceId,
        status: receipt.status == "failed" ? "failed" : "ok",
        records: ["receipt=\(receipt.receiptId)", "status=\(receipt.status)", "duplicate=false", "workflowExecutionId=\(receipt.workflowExecutionId ?? "-")"]
      )
    case "list":
      let receipts = try listEventReceipts(eventRoot: root)
        .filter { receipt in
          if let target = options.target, receipt.sourceId != target {
            return false
          }
          if let status = parsed.status, receipt.status != status {
            return false
          }
          return true
        }
        .prefix(parsed.limit ?? Int.max)
      let records = receipts.map { "receipt=\($0.receiptId) source=\($0.sourceId) status=\($0.status) workflowExecutionId=\($0.workflowExecutionId ?? "-")" }
      return ScopedParityCommandResult(scope: "events", command: action, target: options.target, status: "ok", records: Array(records))
    case "replay":
      guard let receiptId = options.target else {
        throw CLIUsageError("events replay requires <receipt-id>")
      }
      let original = try loadEventReceipt(receiptId: receiptId, eventRoot: root)
      var replayEnvelope = original.envelope
      replayEnvelope.eventId = "\(original.eventId)-replay"
      let replay = PersistedEventReceipt(
        receiptId: safeReceiptId(sourceId: original.sourceId, eventId: replayEnvelope.eventId),
        sourceId: original.sourceId,
        eventId: replayEnvelope.eventId,
        status: parsed.dryRun ? "dry-run" : "replayed",
        duplicate: false,
        workflowExecutionId: original.workflowExecutionId,
        workflowName: original.workflowName,
        replayedFromReceiptId: original.receiptId,
        reason: parsed.reason,
        updatedAt: Date(timeIntervalSince1970: 0),
        envelope: replayEnvelope
      )
      try saveEventReceipt(replay, eventRoot: root)
      return ScopedParityCommandResult(scope: "events", command: action, target: receiptId, status: "ok", records: ["replayedFrom=\(original.receiptId)", "receipt=\(replay.receiptId)", "status=\(replay.status)"])
    case "serve":
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let serveRecord = root.appendingPathComponent("serve-record.json")
      try jsonString([
        "eventRoot": .string(root.path),
        "status": .string("ready"),
        "mode": .string("deterministic-local"),
      ] as JSONObject).write(to: serveRecord, atomically: true, encoding: .utf8)
      return ScopedParityCommandResult(scope: "events", command: action, target: options.target, status: "ok", records: ["eventRoot=\(root.path)", "serveRecord=\(serveRecord.path)", "status=ready"])
    case "replies":
      let replies = try listEventReplies(eventRoot: root)
        .filter { reply in
          if let target = options.target, reply.workflowExecutionId != target {
            return false
          }
          if let status = parsed.status, reply.status != status {
            return false
          }
          return true
        }
        .prefix(parsed.limit ?? Int.max)
      return ScopedParityCommandResult(
        scope: "events",
        command: action,
        target: options.target,
        status: "ok",
        records: replies.map { "reply=\($0.idempotencyKey) source=\($0.sourceId) status=\($0.status) workflowExecutionId=\($0.workflowExecutionId ?? "-")" }
      )
    case "schedules":
      let schedulesCommand = options.target ?? "list"
      let scheduleId = options.arguments.first(where: { !$0.hasPrefix("--") })
      switch schedulesCommand {
      case "list":
        let schedules = try listEventSchedules(eventRoot: root)
          .filter { schedule in
            if let status = parsed.status, schedule.status != status {
              return false
            }
            return true
          }
          .prefix(parsed.limit ?? Int.max)
        return ScopedParityCommandResult(scope: "events", command: action, target: schedulesCommand, status: "ok", records: schedules.map { "schedule=\($0.scheduleId) source=\($0.sourceId) status=\($0.status) workflow=\($0.workflowName)" })
      case "inspect":
        guard let scheduleId else {
          throw CLIUsageError("events schedules inspect requires <schedule-id>")
        }
        let schedule = try loadEventSchedule(scheduleId: scheduleId, eventRoot: root)
        return ScopedParityCommandResult(scope: "events", command: action, target: schedulesCommand, status: "ok", records: ["schedule=\(schedule.scheduleId)", "status=\(schedule.status)", "workflow=\(schedule.workflowName)"])
      case "cancel":
        guard let scheduleId else {
          throw CLIUsageError("events schedules cancel requires <schedule-id>")
        }
        var schedule = try loadEventSchedule(scheduleId: scheduleId, eventRoot: root)
        schedule.status = "cancelled"
        schedule.cancelledReason = parsed.reason
        try saveEventSchedule(schedule, eventRoot: root)
        return ScopedParityCommandResult(scope: "events", command: action, target: schedulesCommand, status: "ok", records: ["schedule=\(schedule.scheduleId)", "status=\(schedule.status)", "reason=\(parsed.reason ?? "-")"])
      default:
        throw CLIUsageError("unknown events schedules command '\(schedulesCommand)'")
      }
    default:
      throw CLIUsageError("unknown events command '\(action)'")
    }
  }

  private func awaitDryRun(config: EventConfig, envelope: ExternalEventEnvelope) async -> EventDryRunResult {
    await DeterministicEventDryRunTrigger().dryRun(EventDryRunRequest(sources: config.sources, bindings: config.bindings, envelope: envelope))
  }

  private func legacyEventResult(options: CLICommandOptions, parsed: ParsedParityOptions) async throws -> ScopedParityCommandResult {
    let action = options.command ?? "validate"
    guard let target = options.target else {
      throw CLIUsageError("events \(action) legacy compatibility requires an event configuration file")
    }
    let path = absoluteURL(target, relativeTo: URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath))
    let config = try JSONDecoder().decode(EventConfig.self, from: Data(contentsOf: path))
    let diagnostics = EventContractValidator.validate(sources: config.sources, bindings: config.bindings)
    if action == "validate" {
      return ScopedParityCommandResult(
        scope: "events",
        command: action,
        target: target,
        status: diagnostics.isEmpty ? "ok" : "failed",
        records: diagnostics.isEmpty ? ["valid"] : diagnostics.map { "\($0.path): \($0.message)" }
      )
    }
    if action == "list" {
      return ScopedParityCommandResult(
        scope: "events",
        command: action,
        target: target,
        status: diagnostics.isEmpty ? "ok" : "failed",
        records: ["sources=\(config.sources.map(\.id).joined(separator: ","))", "bindings=\(config.bindings.map(\.id).joined(separator: ","))"]
      )
    }
    guard diagnostics.isEmpty else {
      return ScopedParityCommandResult(
        scope: "events",
        command: action,
        target: target,
        status: "failed",
        records: diagnostics.map { "\($0.path): \($0.message)" }
      )
    }
    guard action == "emit" || action == "replay" else {
      throw CLIUsageError("unknown events command '\(action)'")
    }
    let envelope = try parsed.variables.map {
      try eventEnvelope(from: JSONReferenceLoader().object(from: $0, workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath))
    } ?? defaultEventEnvelope(config: config, action: action)
    let result = await DeterministicEventDryRunTrigger().dryRun(EventDryRunRequest(sources: config.sources, bindings: config.bindings, envelope: envelope))
    return ScopedParityCommandResult(
      scope: "events",
      command: action,
      target: target,
      status: result.accepted ? "ok" : "ignored",
      records: [
        "receipt=\(result.receipt?.status ?? "none")",
        "triggers=\(result.triggers.map(\.bindingId).joined(separator: ","))",
      ]
    )
  }

  private func eventRootURL(parsed: ParsedParityOptions) -> URL {
    let workingDirectory = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
    if let eventRoot = parsed.eventRoot {
      return absoluteURL(eventRoot, relativeTo: workingDirectory)
    }
    return workingDirectory.appendingPathComponent(".riela/events", isDirectory: true)
  }

  private func receiptsRoot(eventRoot: URL) -> URL {
    eventRoot.appendingPathComponent("receipts", isDirectory: true)
  }

  private func loadEventConfigIfPresent(eventRoot: URL) throws -> EventConfig? {
    let configURL = eventRoot.appendingPathComponent("events.json")
    guard FileManager.default.fileExists(atPath: configURL.path) else {
      return nil
    }
    return try JSONDecoder().decode(EventConfig.self, from: Data(contentsOf: configURL))
  }

  private func saveEventReceipt(_ receipt: PersistedEventReceipt, eventRoot: URL) throws {
    let root = receiptsRoot(eventRoot: eventRoot)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(receipt).write(to: eventRecordURL(id: receipt.receiptId, root: root, kind: "event receipt"), options: .atomic)
  }

  private func loadEventReceipt(receiptId: String, eventRoot: URL) throws -> PersistedEventReceipt {
    let url = try eventRecordURL(id: receiptId, root: receiptsRoot(eventRoot: eventRoot), kind: "event receipt")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw CLIUsageError("event receipt not found: \(receiptId)")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: url))
  }

  private func existingEventReceipt(receiptId: String, eventRoot: URL) throws -> PersistedEventReceipt? {
    let url = try eventRecordURL(id: receiptId, root: receiptsRoot(eventRoot: eventRoot), kind: "event receipt")
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: url))
  }

  private func listEventReceipts(eventRoot: URL) throws -> [PersistedEventReceipt] {
    let root = receiptsRoot(eventRoot: eventRoot)
    guard FileManager.default.fileExists(atPath: root.path) else {
      return []
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .map { try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: $0)) }
      .sorted { $0.receiptId < $1.receiptId }
  }

  private func repliesRoot(eventRoot: URL) -> URL {
    eventRoot.appendingPathComponent("replies", isDirectory: true)
  }

  private func schedulesRoot(eventRoot: URL) -> URL {
    eventRoot.appendingPathComponent("schedules", isDirectory: true)
  }

  private func listEventReplies(eventRoot: URL) throws -> [PersistedEventReply] {
    let root = repliesRoot(eventRoot: eventRoot)
    guard FileManager.default.fileExists(atPath: root.path) else {
      return []
    }
    let decoder = JSONDecoder()
    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .map { try decoder.decode(PersistedEventReply.self, from: Data(contentsOf: $0)) }
      .sorted { $0.idempotencyKey < $1.idempotencyKey }
  }

  private func saveEventSchedule(_ schedule: PersistedEventSchedule, eventRoot: URL) throws {
    let root = schedulesRoot(eventRoot: eventRoot)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(schedule).write(to: eventRecordURL(id: schedule.scheduleId, root: root, kind: "event schedule"), options: .atomic)
  }

  private func loadEventSchedule(scheduleId: String, eventRoot: URL) throws -> PersistedEventSchedule {
    let url = try eventRecordURL(id: scheduleId, root: schedulesRoot(eventRoot: eventRoot), kind: "event schedule")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw CLIUsageError("event schedule not found: \(scheduleId)")
    }
    return try JSONDecoder().decode(PersistedEventSchedule.self, from: Data(contentsOf: url))
  }

  private func listEventSchedules(eventRoot: URL) throws -> [PersistedEventSchedule] {
    let root = schedulesRoot(eventRoot: eventRoot)
    guard FileManager.default.fileExists(atPath: root.path) else {
      return []
    }
    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .map { try JSONDecoder().decode(PersistedEventSchedule.self, from: Data(contentsOf: $0)) }
      .sorted { $0.scheduleId < $1.scheduleId }
  }

  private func safeReceiptId(sourceId: String, eventId: String) -> String {
    let raw = "\(sourceId)\u{0}\(eventId)"
    let encoded = Data(raw.utf8)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "event-\(encoded)"
  }

  private func eventRecordURL(id: String, root: URL, kind: String) throws -> URL {
    guard isSafeEventRecordId(id) else {
      throw CLIUsageError("invalid \(kind) id '\(id)'")
    }
    let standardizedRoot = root.standardizedFileURL
    let url = standardizedRoot.appendingPathComponent("\(id).json").standardizedFileURL
    guard isURL(url, containedIn: standardizedRoot) else {
      throw CLIUsageError("invalid \(kind) id '\(id)'")
    }
    return url
  }

  private func isSafeEventRecordId(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard (1...128).contains(scalars.count), value != ".", value != "..", !value.contains("..") else {
      return false
    }
    return scalars.allSatisfy { scalar in
      isParityASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "-" || scalar == "_"
    }
  }

  private func defaultEventEnvelope(config: EventConfig, action: String) -> ExternalEventEnvelope {
    let source = config.sources.first
    return ExternalEventEnvelope(
      sourceId: source?.id ?? "source",
      eventId: "\(action)-dry-run",
      provider: source?.provider ?? "riela",
      eventType: action,
      receivedAt: Date(timeIntervalSince1970: 0),
      dedupeKey: action == "replay" ? "replay-dry-run" : nil,
      input: ["mode": .string("event-input")]
    )
  }

  private func eventEnvelope(from object: JSONObject) throws -> ExternalEventEnvelope {
    try eventEnvelope(from: object, sourceIdOverride: nil)
  }

  private func eventEnvelope(from object: JSONObject, sourceIdOverride: String?) throws -> ExternalEventEnvelope {
    guard case let .string(sourceId)? = object["sourceId"] else {
      if let sourceIdOverride {
        return ExternalEventEnvelope(
          sourceId: sourceIdOverride,
          eventId: object["eventId"]?.stringValue ?? "event-dry-run",
          provider: object["provider"]?.stringValue ?? "riela",
          eventType: object["eventType"]?.stringValue ?? "event-input",
          receivedAt: Date(timeIntervalSince1970: jsonNumberValue(object["receivedAt"]) ?? 0),
          dedupeKey: object["dedupeKey"]?.stringValue,
          input: jsonObjectValue(object["input"]) ?? [:]
        )
      }
      throw CLIUsageError("event envelope requires sourceId")
    }
    return ExternalEventEnvelope(
      sourceId: sourceIdOverride ?? sourceId,
      eventId: object["eventId"]?.stringValue ?? "event-dry-run",
      provider: object["provider"]?.stringValue ?? "riela",
      eventType: object["eventType"]?.stringValue ?? "event-input",
      receivedAt: Date(timeIntervalSince1970: jsonNumberValue(object["receivedAt"]) ?? 0),
      dedupeKey: object["dedupeKey"]?.stringValue,
      input: jsonObjectValue(object["input"]) ?? [:]
    )
  }

  private func jsonObjectValue(_ value: JSONValue?) -> JSONObject? {
    guard case let .object(object)? = value else {
      return nil
    }
    return object
  }

  private func jsonNumberValue(_ value: JSONValue?) -> Double? {
    guard case let .number(number)? = value else {
      return nil
    }
    return number
  }
}

struct ParsedParityOptions: Sendable {
  var scope: WorkflowScope = .project
  var workingDirectory: String?
  var workflowDefinitionDir: String?
  var source: String?
  var destination: String?
  var overwrite = false
  var dryRun = false
  var variables: String?
  var mockScenarioPath: String?
  var sessionStore: String?
  var artifactRoot: String?
  var messageJSON: String?
  var messageFile: String?
  var promptVariant: String?
  var continueSession = false
  var resumeStepExecutionId: String?
  var timeoutMs: Int?
  var eventRoot: String?
  var eventFile: String?
  var status: String?
  var limit: Int?
  var reason: String?
  var registry: String?
  var registryURL: String?
  var packageName: String?
  var packageID: String?
  var branch: String?
  var localPath: String?

  init(_ arguments: [String]) throws {
    var index = 0
    while index < arguments.count {
      let token = arguments[index]
      func value() throws -> String {
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
          throw CLIUsageError("\(token) requires a value")
        }
        index += 1
        return arguments[index]
      }
      switch token {
      case "--scope":
        let raw = try value()
        guard let parsed = WorkflowScope(rawValue: raw), parsed != .direct else {
          throw CLIUsageError("invalid --scope value '\(raw)'; expected auto, project, or user")
        }
        scope = parsed == .auto ? .project : parsed
      case "--working-dir", "--working-directory":
        workingDirectory = try value()
      case "--workflow-definition-dir":
        workflowDefinitionDir = try value()
      case "--source", "--from":
        source = try value()
      case "--destination", "--dest", "--to":
        destination = try value()
      case "--overwrite", "--force", "-f", "--yes":
        overwrite = true
      case "--dry-run":
        dryRun = true
      case "--variables":
        variables = try value()
      case "--mock-scenario":
        mockScenarioPath = try value()
      case "--session-store":
        sessionStore = try value()
      case "--artifact-root":
        artifactRoot = try value()
      case "--message-json":
        messageJSON = try value()
      case "--message-file":
        messageFile = try value()
      case "--prompt-variant":
        promptVariant = try value()
      case "--continue-session":
        continueSession = true
      case "--resume-step-exec":
        resumeStepExecutionId = try value()
      case "--timeout-ms":
        guard let parsed = Int(try value()), parsed > 0 else {
          throw CLIUsageError("--timeout-ms requires a positive integer")
        }
        timeoutMs = parsed
      case "--event-root":
        eventRoot = try value()
      case "--event-file", "--file":
        eventFile = try value()
      case "--status":
        status = try value()
      case "--limit":
        guard let parsed = Int(try value()), parsed > 0 else {
          throw CLIUsageError("--limit requires a positive integer")
        }
        limit = parsed
      case "--reason":
        reason = try value()
      case "--registry":
        registry = try value()
      case "--registry-url":
        registryURL = try value()
      case "--package-name":
        packageName = try value()
      case "--package-id":
        packageID = try value()
      case "--branch":
        branch = try value()
      case "--local-path", "--registry-local-path":
        localPath = try value()
      case "--output":
        _ = try value()
      default:
        if token.hasPrefix("--output=") {
          break
        }
        throw CLIUsageError("unknown option '\(token)'")
      }
      index += 1
    }
  }
}

private func scopedWorkflowRoot(scope: WorkflowScope, workingDirectory: URL) -> URL {
  switch scope {
  case .user:
    return URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory()).appendingPathComponent(".riela/workflows", isDirectory: true)
  case .auto, .project, .direct:
    return workingDirectory.appendingPathComponent(".riela/workflows", isDirectory: true)
  }
}

private func packageRoot(scope: WorkflowScope, workingDirectory: URL) -> URL {
  switch scope {
  case .user:
    return URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory()).appendingPathComponent(".riela/packages", isDirectory: true)
  case .auto, .project, .direct:
    return workingDirectory.appendingPathComponent(".riela/packages", isDirectory: true)
  }
}

private func packageRoots(parsed: ParsedParityOptions, workingDirectory: URL) -> [URL] {
  switch parsed.scope {
  case .user:
    return [packageRoot(scope: .user, workingDirectory: workingDirectory)]
  case .project:
    return [packageRoot(scope: .project, workingDirectory: workingDirectory)]
  case .auto, .direct:
    return [packageRoot(scope: .project, workingDirectory: workingDirectory), packageRoot(scope: .user, workingDirectory: workingDirectory)]
  }
}

private func packageManifestURLs(in root: URL) throws -> [URL] {
  let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
  var manifests: [URL] = []
  for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
    let directManifest = entry.appendingPathComponent("riela-package.json")
    if FileManager.default.fileExists(atPath: directManifest.path) {
      manifests.append(directManifest)
      continue
    }
    guard entry.lastPathComponent.hasPrefix("@") else {
      continue
    }
    let scopedEntries = try FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.isDirectoryKey])
    for scopedEntry in scopedEntries where (try? scopedEntry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      let scopedManifest = scopedEntry.appendingPathComponent("riela-package.json")
      if FileManager.default.fileExists(atPath: scopedManifest.path) {
        manifests.append(scopedManifest)
      }
    }
  }
  return manifests.sorted { $0.path < $1.path }
}

private func packageFilesystemKey(_ packageName: String) -> String {
  packageName.unicodeScalars.map { scalar in
    if isParityASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "-" || scalar == "_" {
      return String(Character(scalar))
    }
    let hex = String(scalar.value, radix: 16, uppercase: true)
    return "%" + String(repeating: "0", count: max(0, 2 - hex.count)) + hex
  }.joined()
}

private func registryConfigURL(parsed: ParsedParityOptions) -> URL {
  let workingDirectory = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
  return workingDirectory
    .appendingPathComponent(".riela/workflow-packages", isDirectory: true)
    .appendingPathComponent("registries.json")
}

private func isSafeRegistryId(_ id: String) -> Bool {
  guard let first = id.unicodeScalars.first, isParityASCIIAlphaNumeric(first), id.unicodeScalars.count <= 80 else {
    return false
  }
  return id.unicodeScalars.allSatisfy { scalar in
    isParityASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-"
  }
}

private func isSupportedRegistryURL(_ value: String) -> Bool {
  guard let url = URL(string: value), url.scheme == "https", url.host == "github.com" else {
    return false
  }
  let components = url.pathComponents.filter { $0 != "/" }
  return components.count == 2
}

private func directRegistryId(for registryURL: String) -> String {
  guard let url = URL(string: registryURL) else {
    return "github-registry"
  }
  let components = url.pathComponents.filter { $0 != "/" }
  let owner = components.first ?? "unknown"
  let repo = components.dropFirst().first ?? "registry"
  let raw = "github-\(owner)-\(repo)"
  return String(raw.unicodeScalars.map { scalar in
    isParityASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-"
      ? Character(scalar)
      : "-"
  })
}

private func isURL(_ url: URL, containedIn root: URL) -> Bool {
  let childPath = url.standardizedFileURL.path
  let rootPath = root.standardizedFileURL.path
  return childPath == rootPath || childPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/")
}

private func isParityASCIIAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
  let value = scalar.value
  return (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
}

private func renderRegistryConfig(
  _ config: WorkflowPackageRegistryConfig,
  output: WorkflowOutputFormat,
  text: String? = nil
) throws -> CLICommandResult {
  switch output {
  case .json:
    return CLICommandResult(exitCode: .success, stdout: try jsonString(config))
  case .text, .table:
    if let text {
      return CLICommandResult(exitCode: .success, stdout: text)
    }
    return CLICommandResult(
      exitCode: .success,
      stdout: config.registries.map { registry in
        [
          registry.id,
          registry.url,
          registry.defaultBranch,
          registry.localPath ?? "",
        ].joined(separator: "\t")
      }.joined(separator: "\n") + (config.registries.isEmpty ? "" : "\n")
    )
  }
}

private func render<T: Encodable>(
  _ value: T,
  options: CLICommandOptions,
  text: (T) -> String
) throws -> CLICommandResult {
  switch options.output {
  case .json:
    return CLICommandResult(exitCode: .success, stdout: try jsonString(value))
  case .text, .table:
    return CLICommandResult(exitCode: .success, stdout: text(value))
  }
}

private func renderPackage(_ result: WorkflowPackageCommandResult, output: WorkflowOutputFormat) throws -> CLICommandResult {
  switch output {
  case .json:
    return CLICommandResult(exitCode: .success, stdout: try jsonString(result))
  case .text:
    if result.packages.isEmpty {
      return CLICommandResult(exitCode: .success, stdout: result.message + "\n")
    }
    return CLICommandResult(exitCode: .success, stdout: result.packages.map { "\($0.name)\t\($0.version ?? "-")\t\($0.valid ? "valid" : "invalid")\t\($0.packageDirectory)" }.joined(separator: "\n") + "\n")
  case .table:
    let rows = result.packages.map { "\($0.name)\t\($0.version ?? "-")\t\($0.kind.rawValue)\t\($0.valid ? "valid" : "invalid")" }
    return CLICommandResult(exitCode: .success, stdout: (["PACKAGE\tVERSION\tKIND\tSTATUS"] + rows).joined(separator: "\n") + "\n")
  }
}

private func failure(_ message: String, output: WorkflowOutputFormat, options: CLICommandOptions) -> CLICommandResult {
  if output == .json {
    let payload = CLIUnsupportedCommandResult(
      scope: options.scope,
      command: options.command,
      target: options.target,
      exitCode: CLIExitCode.failure.rawValue,
      error: message
    )
    return CLICommandResult(exitCode: .failure, stdout: (try? jsonString(payload)) ?? "")
  }
  return CLICommandResult(exitCode: .failure, stderr: message)
}

private func scaffoldWorkflowJSON(workflowName: String) -> String {
  """
  {
    "workflowId": "\(workflowName)",
    "description": "Created by Riela Swift CLI",
    "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
    "entryStepId": "main-worker",
    "nodes": [{ "id": "main-worker", "nodeFile": "nodes/node-main-worker.json" }],
    "steps": [{ "id": "main-worker", "nodeId": "main-worker", "role": "worker" }]
  }
  """
}

private func scaffoldNodeJSON() -> String {
  """
  {
    "id": "main-worker",
    "executionBackend": "codex-agent",
    "model": "gpt-5-nano",
    "prompt": "Return a concise JSON object with a status field.",
    "variables": {}
  }
  """
}
