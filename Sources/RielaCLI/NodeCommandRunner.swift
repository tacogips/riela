import Foundation
import RielaAddons
import RielaCore

public struct NodeRunCommandResult: Codable, Equatable, Sendable {
  public var scope: String
  public var command: String
  public var target: String
  public var provider: String
  public var model: String
  public var payload: JSONObject
}

public struct NodeCommandRunner: Sendable {
  private var packageRunner: WorkflowPackageCommandRunner

  public init(packageRunner: WorkflowPackageCommandRunner = WorkflowPackageCommandRunner()) {
    self.packageRunner = packageRunner
  }

  public func run(_ command: NodeCommand) async -> CLICommandResult {
    let options = command.options
    do {
      let parsed = try ParsedParityOptions(options.arguments)
      switch command.kind {
      case .search, .list:
        return try await search(command: command, parsed: parsed)
      case .install:
        return try await install(command: command, parsed: parsed)
      case .run:
        return try await runAddon(command: command, parsed: parsed)
      }
    } catch let error as CLIUsageError {
      return failure(error.message, output: options.output, options: options)
    } catch {
      return failure("\(error)", output: options.output, options: options)
    }
  }

  private func search(command: NodeCommand, parsed: ParsedParityOptions) async throws -> CLICommandResult {
    let packages = try await nodeAddonPackages(options: command.options, parsed: parsed)
    let filtered = filterNodePackages(packages, query: command.options.target, limit: parsed.limit)
    let result = WorkflowPackageCommandResult(
      scope: command.options.scope,
      command: command.kind.rawValue,
      target: command.options.target,
      packages: filtered,
      destinationDirectory: nil,
      dryRun: parsed.dryRun,
      message: filtered.isEmpty ? "no node add-ons found" : "node add-ons found: \(filtered.count)",
      runSessionId: nil
    )
    return try renderPackage(result, output: command.options.output)
  }

  private func install(command: NodeCommand, parsed: ParsedParityOptions) async throws -> CLICommandResult {
    guard let target = command.options.target, !target.isEmpty else {
      throw CLIUsageError("node install requires an add-on or package name")
    }
    let resolvedTarget: String
    if parsed.source == nil {
      resolvedTarget = try await packageName(forNodeTarget: target, options: command.options, parsed: parsed)
    } else {
      resolvedTarget = target
    }
    let installation = try await packageRunner.installPackage(target: resolvedTarget, parsed: parsed)
    var sharedDestinations: [URL] = []
    if !parsed.dryRun {
      let manifestURL = installation.destination.appendingPathComponent(WorkflowPackageArchiveManager.manifestFileName)
      let manifest = try await FileWorkflowPackageManifestLoader().loadManifest(from: manifestURL)
      let plans = try sharedAddonProjectionPlans(manifest: manifest, packageRoot: installation.destination)
      sharedDestinations = try await installSharedAddonProjections(
        plans,
        overwrite: parsed.overwrite,
        dryRun: parsed.dryRun
      )
    }
    let message: String
    if parsed.dryRun {
      message = "node install dry run"
    } else if sharedDestinations.isEmpty {
      message = "node package install completed"
    } else {
      message = "node install completed; shared add-ons: \(sharedDestinations.count)"
    }
    let result = WorkflowPackageCommandResult(
      scope: command.options.scope,
      command: command.kind.rawValue,
      target: command.options.target,
      packages: [installation.summary],
      dependencies: installation.dependencies,
      destinationDirectory: installation.destination.path,
      dryRun: parsed.dryRun,
      message: packageMessageWithContainerSetupHint(message, packages: [installation.summary]),
      runSessionId: nil
    )
    return try renderPackage(result, output: command.options.output)
  }

  private func runAddon(command: NodeCommand, parsed: ParsedParityOptions) async throws -> CLICommandResult {
    guard let target = command.options.target, !target.isEmpty else {
      throw CLIUsageError("node run requires an add-on name")
    }
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    let variables = try parsed.variables.map {
      try JSONReferenceLoader().object(from: $0, workingDirectory: workingDirectory)
    } ?? [:]
    if parsed.mockScenarioPath == nil {
      try await preflightInstalledAddonExecution(
        target: target,
        parsed: parsed,
        workingDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true),
        environment: environment
      )
    }
    let resolver = try await makeScenarioBackedAddonResolver(
      scenarioPath: parsed.mockScenarioPath,
      workingDirectory: workingDirectory,
      environment: environment
    )
    let output = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "node-run",
        stepId: "node-run",
        nodeId: "node-run",
        addon: WorkflowNodeAddonRef(name: target, version: nil, inputs: variables),
        variables: variables,
        resolvedInputPayload: variables
      ),
      context: AdapterExecutionContext(deadline: deadline(timeoutMs: parsed.timeoutMs))
    )
    let result = NodeRunCommandResult(
      scope: command.options.scope,
      command: command.kind.rawValue,
      target: target,
      provider: output.provider,
      model: output.model,
      payload: output.payload
    )
    return try render(result, options: command.options) { result in
      var lines = [
        "node run completed",
        "Add-on: \(result.target)",
        "Provider: \(result.provider)"
      ]
      if !result.payload.isEmpty {
        lines.append("Payload: \((try? jsonString(result.payload).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "{}")")
      }
      return lines.joined(separator: "\n") + "\n"
    }
  }

  private func nodeAddonPackages(options: CLICommandOptions, parsed: ParsedParityOptions) async throws -> [WorkflowPackageSummary] {
    let packageOptions = CLICommandOptions(
      scope: "package",
      command: PackageCommandKind.search.rawValue,
      target: options.target,
      arguments: options.arguments,
      output: options.output
    )
    return try await packageRunner.packageSummariesForNodeCommand(options: packageOptions, parsed: parsed)
      .filter { $0.kind == .nodeAddon }
  }

  private func packageName(
    forNodeTarget target: String,
    options: CLICommandOptions,
    parsed: ParsedParityOptions
  ) async throws -> String {
    let packages = try await nodeAddonPackages(options: options, parsed: parsed)
    if packages.contains(where: { $0.name == target }) {
      return target
    }
    let matches = packages.filter { package in
      package.addons?.contains(where: { $0.name == target }) == true
    }
    if matches.count == 1, let match = matches.first {
      return match.name
    }
    if matches.count > 1 {
      throw CLIUsageError("node target '\(target)' matched multiple packages: \(matches.map(\.name).joined(separator: ", "))")
    }
    throw CLIUsageError("node target '\(target)' was not found in node add-on packages")
  }

  private func filterNodePackages(
    _ packages: [WorkflowPackageSummary],
    query: String?,
    limit: Int?
  ) -> [WorkflowPackageSummary] {
    let filtered: [WorkflowPackageSummary]
    if let query, !query.isEmpty {
      filtered = packages.compactMap { package in
        let fields = matchingNodeFields(package, query: query)
        guard !fields.isEmpty else {
          return nil
        }
        var matched = package
        matched.matchMetadata = WorkflowPackageMatchMetadata(query: query, fields: fields)
        return matched
      }
    } else {
      filtered = packages
    }
    guard let limit else {
      return filtered
    }
    return Array(filtered.prefix(limit))
  }

  private func matchingNodeFields(_ package: WorkflowPackageSummary, query: String) -> [String] {
    let fields: [(String, [String])] = [
      ("package", [package.name]),
      ("title", [package.title].compactMap { $0 }),
      ("description", [package.description].compactMap { $0 }),
      ("tags", package.tags),
      ("addons", package.addons?.map(\.name) ?? []),
      ("addonExecution", package.addons?.compactMap { $0.executionKind?.rawValue } ?? [])
    ]
    return fields.compactMap { field, values in
      values.contains { $0.localizedCaseInsensitiveContains(query) } ? field : nil
    }
  }

  private func deadline(timeoutMs: Int?) -> Date? {
    timeoutMs.map { Date().addingTimeInterval(Double($0) / 1000.0) }
  }
}

private struct InstalledNodeAddonMatch {
  var packageRoot: URL
  var manifest: WorkflowPackageManifest
  var addon: WorkflowPackageNodeAddon
}

private extension NodeCommandRunner {
  func preflightInstalledAddonExecution(
    target: String,
    parsed: ParsedParityOptions,
    workingDirectory: URL,
    environment: [String: String]
  ) async throws {
    let matches = try await installedNodeAddonMatches(
      target: target,
      parsed: parsed,
      workingDirectory: workingDirectory,
      environment: environment
    )
    guard !matches.isEmpty else {
      return
    }
    try validateRequiredEnvironment(matches: matches, target: target, environment: environment)
    try validateRuntimeHints(matches: matches, target: target, environment: environment)
    try validateContainerRuntime(matches: matches, target: target, environment: environment)
  }

  func installedNodeAddonMatches(
    target: String,
    parsed: ParsedParityOptions,
    workingDirectory: URL,
    environment: [String: String]
  ) async throws -> [InstalledNodeAddonMatch] {
    let loader = FileWorkflowPackageManifestLoader()
    var matches: [InstalledNodeAddonMatch] = []
    for root in packageRoots(parsed: parsed, workingDirectory: workingDirectory)
      where FileManager.default.fileExists(atPath: root.path) {
      for manifestURL in try packageManifestURLs(in: root) {
        try await appendNodeAddonMatches(
          target: target,
          manifestURL: manifestURL,
          loader: loader,
          matches: &matches
        )
      }
    }
    for manifestURL in try sharedAddonManifestURLs(environment: environment) {
      try await appendNodeAddonMatches(
        target: target,
        manifestURL: manifestURL,
        loader: loader,
        matches: &matches
      )
    }
    return matches
  }

  func appendNodeAddonMatches(
    target: String,
    manifestURL: URL,
    loader: FileWorkflowPackageManifestLoader,
    matches: inout [InstalledNodeAddonMatch]
  ) async throws {
    let packageRoot = manifestURL.deletingLastPathComponent()
    let manifest = try await loader.loadManifest(from: manifestURL)
    for addon in manifest.nodeAddons where addon.name == target {
      matches.append(InstalledNodeAddonMatch(
        packageRoot: packageRoot,
        manifest: manifest,
        addon: addon
      ))
    }
  }

  func validateRequiredEnvironment(
    matches: [InstalledNodeAddonMatch],
    target: String,
    environment: [String: String]
  ) throws {
    let missing = uniqueSortedDiagnostics(matches.flatMap { match in
      match.manifest.environmentVariables.filter(\.required).compactMap { requirement -> String? in
        if let value = environment[requirement.name]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty {
          return nil
        }
        return "\(requirement.name) (\(match.manifest.name))"
      }
    })
    guard missing.isEmpty else {
      throw CLIUsageError(
        "node run preflight failed for '\(target)': missing required environment variables: "
          + missing.joined(separator: ", ")
          + ". Configure the variables or run 'riela doctor'."
      )
    }
  }

  func validateRuntimeHints(
    matches: [InstalledNodeAddonMatch],
    target: String,
    environment: [String: String]
  ) throws {
    let searchPath = executableSearchPath(environment: environment)
    let missing = uniqueSortedDiagnostics(matches.flatMap { match in
      (match.addon.execution?.runtimeHints ?? []).compactMap { hint -> String? in
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, resolveExecutable(trimmed, searchPath: searchPath) == nil else {
          return nil
        }
        return "\(trimmed) (\(match.manifest.name)/\(match.addon.name))"
      }
    })
    guard missing.isEmpty else {
      throw CLIUsageError(
        "node run preflight failed for '\(target)': missing required host tools: "
          + missing.joined(separator: ", ")
          + ". Install the tools or run 'riela doctor'."
      )
    }
  }

  func validateContainerRuntime(
    matches: [InstalledNodeAddonMatch],
    target: String,
    environment: [String: String]
  ) throws {
    let containerAddons = matches.filter { $0.addon.execution?.kind == .container }
    guard !containerAddons.isEmpty else {
      return
    }
    let discovery = ContainerRuntimeDiscovery(environment: environment)
    guard discovery.configuredDriver() == nil, discovery.selectedAvailableDriver() == nil else {
      return
    }
    let labels = uniqueSortedDiagnostics(containerAddons.map { "\($0.manifest.name)/\($0.addon.name)" })
    throw CLIUsageError(
      "node run preflight failed for '\(target)': container runtime is missing for "
        + labels.joined(separator: ", ")
        + ". Run 'riela setup container', or install Apple Container, Docker, or Podman and start the runtime."
    )
  }

  func uniqueSortedDiagnostics(_ values: [String]) -> [String] {
    Array(Set(values)).sorted()
  }
}
