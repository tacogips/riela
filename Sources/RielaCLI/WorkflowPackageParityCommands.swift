import Foundation
import RielaAdapters
import RielaAddons
import RielaCore
import RielaEvents
import RielaGraphQL
import RielaHook
import RielaServer

private let defaultWorkflowPackageRegistryId = "default"
private let defaultWorkflowPackageRegistryURL = "https://github.com/tacogips/riela-packages"
private let defaultWorkflowPackageRegistryBranch = "main"
private let defaultWorkflowPackageRegistryTimestamp = "2026-06-18T00:00:00Z"

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
        let installation = try await installPackage(target: options.target, parsed: parsed)
        let result = WorkflowPackageCommandResult(
          scope: options.scope,
          command: command.kind.rawValue,
          target: options.target,
          packages: [installation.summary],
          destinationDirectory: installation.destination.path,
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
        let result = WorkflowPackageCommandResult(
          scope: options.scope,
          command: command.kind.rawValue,
          target: target,
          packages: packages,
          destinationDirectory: nil,
          dryRun: parsed.dryRun,
          message: "package update checked \(target)",
          runSessionId: nil
        )
        return try renderPackage(result, output: options.output)
      case .remove:
        let destination = try removePackage(target: options.target, parsed: parsed)
        let result = WorkflowPackageCommandResult(
          scope: options.scope,
          command: command.kind.rawValue,
          target: options.target,
          packages: [],
          destinationDirectory: destination.path,
          dryRun: parsed.dryRun,
          message: parsed.dryRun ? "package remove dry run" : "package removed",
          runSessionId: nil
        )
        return try renderPackage(result, output: options.output)
      case .run, .tempRun:
        return try await runPackage(command: command, parsed: parsed)
      case .initialize:
        let initialized = try await initializePackage(target: options.target, parsed: parsed)
        let result = WorkflowPackageCommandResult(
          scope: options.scope,
          command: command.kind.rawValue,
          target: options.target,
          packages: [initialized.summary],
          destinationDirectory: initialized.manifestURL.path,
          dryRun: parsed.dryRun,
          message: parsed.dryRun ? "package init dry run" : "package manifest created",
          runSessionId: nil
        )
        return try renderPackage(result, output: options.output)
      case .validate:
        let validation = try await validatePackage(target: options.target, parsed: parsed)
        let result = WorkflowPackageCommandResult(
          scope: options.scope,
          command: command.kind.rawValue,
          target: options.target,
          packages: [validation.summary],
          destinationDirectory: validation.source.path,
          dryRun: parsed.dryRun,
          message: validation.summary.valid ? "package validation passed" : "package validation failed",
          runSessionId: nil
        )
        let rendered = try renderPackage(result, output: options.output)
        return CLICommandResult(
          exitCode: validation.summary.valid ? .success : .failure,
          stdout: rendered.stdout,
          stderr: rendered.stderr
        )
      case .pack:
        let packed = try await packPackage(target: options.target, parsed: parsed)
        let result = WorkflowPackageCommandResult(
          scope: options.scope,
          command: command.kind.rawValue,
          target: options.target,
          packages: [packed.summary],
          destinationDirectory: packed.archiveURL.path,
          dryRun: parsed.dryRun,
          message: parsed.dryRun ? "package pack dry run" : "package archive created",
          runSessionId: nil
        )
        return try renderPackage(result, output: options.output)
      case .publish:
        if parsed.dryRun {
          let published = try await publishPackage(target: options.target, parsed: parsed)
          let result = WorkflowPackageCommandResult(
            scope: options.scope,
            command: command.kind.rawValue,
            target: options.target,
            packages: [published.summary],
            destinationDirectory: published.registryRecord.path,
            dryRun: true,
            message: "package publish dry run completed",
            runSessionId: nil
          )
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
      return failure(packageCommandErrorDescription(error), output: options.output, options: options)
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

  private func packageCommandErrorDescription(_ error: Error) -> String {
    if let localized = error as? LocalizedError,
      let description = localized.errorDescription,
      !description.isEmpty {
      return description
    }
    return "\(error)"
  }

  private func runPackage(command: PackageCommand, parsed: ParsedParityOptions) async throws -> CLICommandResult {
    guard let target = command.options.target, !target.isEmpty else {
      throw CLIUsageError("\(command.options.scope) \(command.kind.rawValue) requires a package name")
    }
    let workingDirectoryURL = URL(
      fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath,
      isDirectory: true
    )
    let resolvedSource = try await runnablePackageSource(target: target, parsed: parsed, workingDirectory: workingDirectoryURL)
    defer {
      if let temporaryRoot = resolvedSource.temporaryRoot {
        try? FileManager.default.removeItem(at: temporaryRoot)
      }
    }
    let packageDirectory = resolvedSource.directory
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
          )
        ],
        destinationDirectory: packageDirectory.path,
        dryRun: true,
        message: "package \(command.kind.rawValue) dry run planned without workflow execution",
        runSessionId: nil
      )
      return try renderPackage(packageResult, output: command.options.output)
    }
    let variables = try parsed.variables.map { try JSONReferenceLoader().object(from: $0, workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath) } ?? [:]
    let workingDirectory = workingDirectoryURL.path
    let adapter = try makeScenarioBackedNodeAdapter(
      scenarioPath: parsed.mockScenarioPath,
      workingDirectory: workingDirectory
    )
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
    let workflowMessages = try await runtimeStore.listMessages(for: result.session.sessionId, toStepId: nil)
    try CLIWorkflowSessionStore(rootDirectory: storeRoot).save(
      PersistedCLIWorkflowSession(
        workflowName: workflowDirectory.lastPathComponent,
        session: result.session,
        resolution: persistedResolution,
        mockScenarioPath: parsed.mockScenarioPath
      ),
      runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: result.session, workflowMessages: workflowMessages)
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
    if command.options.output.isStructured {
      return CLICommandResult(exitCode: CLIExitCode(rawValue: result.exitCode) ?? .failure, stdout: try jsonString(packageResult))
    }
    return CLICommandResult(
      exitCode: CLIExitCode(rawValue: result.exitCode) ?? .failure,
      stdout: "package \(command.kind.rawValue) completed\nsessionId: \(result.session.sessionId)\nstatus: \(result.status.rawValue)\n"
    )
  }

  func packageDirectory(target: String, parsed: ParsedParityOptions) throws -> URL {
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
    let readinessIssues = packageLoopReadinessIssues(for: bundle.workflow.loop)
    let summary = WorkflowPackageSummary(
      name: packageName,
      version: "0.1.0",
      kind: .workflow,
      packageDirectory: workflowDirectory.path,
      workflowDirectory: ".",
      valid: readinessIssues.isEmpty,
      issues: readinessIssues
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
      "dryRun": .bool(parsed.dryRun)
    ] as JSONObject).write(to: registryRecord, atomically: true, encoding: .utf8)
    try jsonString(summary).write(to: cacheRecord, atomically: true, encoding: .utf8)
    try jsonString([
      "name": .string(packageName),
      "version": .string("0.1.0"),
      "registry": .string(registry.id),
      "registryUrl": .string(registry.url),
      "registryRef": .string(registry.branch),
      "checksum": .string("swift-deterministic-publish-record"),
      "checksumAlgorithm": .string("swift-deterministic")
    ] as JSONObject).write(to: lockRecord, atomically: true, encoding: .utf8)
    try jsonString([
      "packageName": .string(packageName),
      "nativeAddonCount": .number(0),
      "nativeAddonNames": .array([]),
      "dependencyNativeLockCount": .number(0),
      "evidence": .string("validated-manifest-native-addon-publish-record")
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
        "sourceBranch": .string(registry.branch)
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
      id: defaultWorkflowPackageRegistryId,
      url: defaultWorkflowPackageRegistryURL,
      branch: parsed.branch ?? defaultWorkflowPackageRegistryBranch,
      localPath: parsed.localPath
    )
  }

  private func loadRegistryConfig(parsed: ParsedParityOptions) throws -> WorkflowPackageRegistryConfig {
    let url = registryConfigURL(parsed: parsed)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return defaultRegistryConfig(parsed: parsed)
    }
    let data = try Data(contentsOf: url)
    return withImplicitDefaultRegistry(try JSONDecoder().decode(WorkflowPackageRegistryConfig.self, from: data), parsed: parsed)
  }

  private func defaultRegistryConfig(parsed: ParsedParityOptions) -> WorkflowPackageRegistryConfig {
    WorkflowPackageRegistryConfig(
      defaultRegistryId: defaultWorkflowPackageRegistryId,
      registries: [defaultRegistryEntry(parsed: parsed)]
    )
  }

  private func withImplicitDefaultRegistry(
    _ config: WorkflowPackageRegistryConfig,
    parsed: ParsedParityOptions
  ) -> WorkflowPackageRegistryConfig {
    var resolved = config
    let defaultEntry = defaultRegistryEntry(parsed: parsed)
    if let index = resolved.registries.firstIndex(where: { registry in
      registry.id == defaultWorkflowPackageRegistryId || registry.url == defaultWorkflowPackageRegistryURL
    }) {
      var configured = resolved.registries[index]
      if configured.id != defaultWorkflowPackageRegistryId {
        configured.id = defaultWorkflowPackageRegistryId
      }
      if configured.defaultBranch.isEmpty {
        configured.defaultBranch = defaultWorkflowPackageRegistryBranch
      }
      if configured.localPath == nil {
        configured.localPath = defaultEntry.localPath
      }
      resolved.registries[index] = configured
    } else {
      resolved.registries.append(defaultEntry)
    }
    if resolved.defaultRegistryId.isEmpty
      || !resolved.registries.contains(where: { $0.id == resolved.defaultRegistryId }) {
      resolved.defaultRegistryId = defaultWorkflowPackageRegistryId
    }
    return resolved
  }

  private func defaultRegistryEntry(parsed: ParsedParityOptions) -> WorkflowPackageRegistryEntry {
    let workingDirectory = URL(
      fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath,
      isDirectory: true
    )
    return WorkflowPackageRegistryEntry(
      id: defaultWorkflowPackageRegistryId,
      url: defaultWorkflowPackageRegistryURL,
      defaultBranch: defaultWorkflowPackageRegistryBranch,
      localPath: "\(workingDirectory.standardizedFileURL.path)-packages",
      registeredAt: defaultWorkflowPackageRegistryTimestamp,
      updatedAt: defaultWorkflowPackageRegistryTimestamp
    )
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
    let roots = try packageSummaryRoots(parsed: parsed, workingDirectory: workingDirectory)
    let loader = FileWorkflowPackageManifestLoader()
    var summaries: [WorkflowPackageSummary] = []
    for root in roots where FileManager.default.fileExists(atPath: root.path) {
      for manifestURL in try packageManifestURLs(in: root) {
        let url = manifestURL.deletingLastPathComponent()
        do {
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
        } catch {
          summaries.append(WorkflowPackageSummary(
            name: inferredPackageName(from: url),
            version: nil,
            kind: .workflow,
            packageDirectory: url.path,
            workflowDirectory: nil,
            valid: false,
            issues: [
              WorkflowPackageValidationIssue(
                code: "INVALID_MANIFEST",
                path: "riela-package.json",
                message: "\(error)"
              )
            ]
          ))
        }
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

  func registryPackageSource(
    named target: String,
    parsed: ParsedParityOptions,
    workingDirectory: URL
  ) async throws -> URL? {
    let loader = FileWorkflowPackageManifestLoader()
    for registry in try selectedPackageRegistries(parsed: parsed, workingDirectory: workingDirectory) {
      guard let localPath = registry.localPath else {
        continue
      }
      let registryRoot = absoluteURL(localPath, relativeTo: workingDirectory)
      let packagesRoot = registryRoot.appendingPathComponent("packages", isDirectory: true)
      guard FileManager.default.fileExists(atPath: packagesRoot.path) else {
        continue
      }
      for manifestURL in try packageManifestURLs(in: packagesRoot) {
        let packageDirectory = manifestURL.deletingLastPathComponent()
        do {
          let manifest = try await loader.loadManifest(from: manifestURL)
          if manifest.name == target {
            return packageDirectory
          }
        } catch {
          if inferredPackageName(from: packageDirectory) == target {
            throw CLIUsageError("package source validation failed: riela-package.json: \(error)")
          }
        }
      }
    }
    return nil
  }

  private func selectedPackageRegistries(
    parsed: ParsedParityOptions,
    workingDirectory: URL
  ) throws -> [WorkflowPackageRegistryEntry] {
    let config = try loadRegistryConfig(parsed: parsed)
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
      return [
        WorkflowPackageRegistryEntry(
          id: registered?.id ?? directRegistryId(for: explicitURL),
          url: explicitURL,
          defaultBranch: parsed.branch ?? registered?.defaultBranch ?? "main",
          localPath: parsed.localPath ?? registered?.localPath,
          registeredAt: registered?.registeredAt ?? defaultWorkflowPackageRegistryTimestamp,
          updatedAt: defaultWorkflowPackageRegistryTimestamp
        )
      ]
    }
    if let selector {
      guard let registered = config.registries.first(where: { $0.id == selector }) else {
        throw CLIUsageError("package registry not found: \(selector)")
      }
      var resolved = registered
      if let branch = parsed.branch {
        resolved.defaultBranch = branch
      }
      if let localPath = parsed.localPath {
        resolved.localPath = localPath
      }
      return [resolved]
    }
    if let localPath = parsed.localPath {
      return [
        WorkflowPackageRegistryEntry(
          id: defaultWorkflowPackageRegistryId,
          url: defaultWorkflowPackageRegistryURL,
          defaultBranch: parsed.branch ?? defaultWorkflowPackageRegistryBranch,
          localPath: localPath,
          registeredAt: defaultWorkflowPackageRegistryTimestamp,
          updatedAt: defaultWorkflowPackageRegistryTimestamp
        )
      ]
    }
    return config.registries
  }

  private func packageSummaryRoots(parsed: ParsedParityOptions, workingDirectory: URL) throws -> [URL] {
    let registryRoots = try selectedPackageRegistries(parsed: parsed, workingDirectory: workingDirectory)
      .compactMap(\.localPath)
      .map { absoluteURL($0, relativeTo: workingDirectory).appendingPathComponent("packages", isDirectory: true) }
    return uniquePackageRoots(packageRoots(parsed: parsed, workingDirectory: workingDirectory) + registryRoots)
  }

  private func uniquePackageRoots(_ urls: [URL]) -> [URL] {
    var seen = Set<String>()
    var result: [URL] = []
    for url in urls {
      let path = url.standardizedFileURL.path
      if seen.insert(path).inserted {
        result.append(url)
      }
    }
    return result
  }

  private func inferredPackageName(from packageDirectory: URL) -> String {
    let name = packageDirectory.lastPathComponent
    let scope = packageDirectory.deletingLastPathComponent().lastPathComponent
    if scope.hasPrefix("@") {
      return "\(scope)/\(name)"
    }
    return name
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
