import Foundation
import RielaAddons
import RielaCore

// Publish transport for WorkflowPackageCommandRunner: real checksum + normalized
// manifest, backend-hint derivation, and git-integrated direct/PR publishing.
extension WorkflowPackageCommandRunner {
  struct PublishedPackageRecord {
    var summary: WorkflowPackageSummary
    var registryRecord: URL
    var checksum: String
    var checksumAlgorithm: String
    var backends: [String]
    var mode: WorkflowPackagePublishMode
    var commitSha: String?
    var prUrl: String?
  }

  private struct PublishRegistryResolution {
    var id: String
    var url: String
    var branch: String
    var localPath: String?
  }

  func publishPackage(target: String?, parsed: ParsedParityOptions) async throws -> PublishedPackageRecord {
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
    // Advisory portability warnings (command notification channels) ride the
    // issues list but never gate validity.
    let notificationWarnings = packageLoopNotificationWarnings(for: bundle.workflow.loop)
    let backends = publishBackendHints(nodePayloads: bundle.nodePayloads)
    let checksum = try WorkflowPackageChecksum.md5(packageRoot: workflowDirectory)
    let checksumAlgorithm = WorkflowPackageChecksum.supportedAlgorithm
    let summary = WorkflowPackageSummary(
      name: packageName,
      version: "0.1.0",
      kind: .workflow,
      tags: ["workflow"],
      backends: backends.isEmpty ? nil : backends,
      packageDirectory: workflowDirectory.path,
      workflowDirectory: ".",
      valid: readinessIssues.isEmpty,
      issues: readinessIssues + notificationWarnings
    )
    if parsed.dryRun {
      return PublishedPackageRecord(
        summary: summary,
        registryRecord: registryRecord,
        checksum: checksum,
        checksumAlgorithm: checksumAlgorithm,
        backends: backends,
        mode: parsed.createPR ? .pullRequest : .direct,
        commitSha: nil,
        prUrl: nil
      )
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
    // A git registry checkout must be verified clean BEFORE staging package
    // files into it; a bare local staging directory keeps copy-only behavior.
    var gitCheckout: (git: WorkflowPackagePublishGit, root: URL)?
    if let registryLocalPath = registry.localPath {
      let localRegistryRoot = absoluteURL(registryLocalPath, relativeTo: workingDirectory)
      if FileManager.default.fileExists(atPath: localRegistryRoot.appendingPathComponent(".git").path) {
        let git = WorkflowPackagePublishGit(executor: publishCommandExecutor)
        try git.ensureCheckout(remoteURL: registry.url, branch: registry.branch, checkout: localRegistryRoot)
        try git.assertCleanWorktree(checkout: localRegistryRoot)
        gitCheckout = (git, localRegistryRoot)
      }
    }
    try jsonString(summary).write(to: cacheRecord, atomically: true, encoding: .utf8)
    try jsonString([
      "name": .string(packageName),
      "version": .string("0.1.0"),
      "registry": .string(registry.id),
      "registryUrl": .string(registry.url),
      "registryRef": .string(registry.branch),
      "checksum": .string(checksum),
      "checksumAlgorithm": .string(checksumAlgorithm)
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
      // Normalized manifest so a published package is checkout/search-verifiable.
      // It is written INSIDE the staged `workflow/` copy (which checkout reads),
      // NOT at the package-key root: writing it at the root would make
      // `package list`'s manifest scan treat the registry-cache key directory as
      // an installed package and surface it as a duplicate.
      let stagedChecksum = try WorkflowPackageChecksum.md5(packageRoot: workflowTarget)
      let stagedManifest = workflowTarget.appendingPathComponent("riela-package.json")
      if !FileManager.default.fileExists(atPath: stagedManifest.path) {
        try jsonString([
          "name": .string(packageName),
          "version": .string("0.1.0"),
          "kind": .string("workflow"),
          "workflowDirectory": .string("."),
          "tags": .array([.string("workflow")]),
          "backends": .array(backends.map { .string($0) }),
          "registry": .string(registry.id),
          "checksum": .string(stagedChecksum),
          "checksumAlgorithm": .string(checksumAlgorithm)
        ] as JSONObject).write(to: stagedManifest, atomically: true, encoding: .utf8)
      }
      let registryIndex = localRegistryRoot.appendingPathComponent("registry", isDirectory: true)
      try FileManager.default.createDirectory(at: registryIndex, withIntermediateDirectories: true)
      try jsonString([
        "packageName": .string(packageName),
        "workflowName": .string(bundle.workflow.workflowId),
        "sourcePath": .string("packages/\(packageKey)"),
        "registryId": .string(registry.id),
        "registryUrl": .string(registry.url),
        "sourceBranch": .string(registry.branch),
        "checksum": .string(stagedChecksum),
        "backends": .array(backends.map { .string($0) })
      ] as JSONObject).write(to: registryIndex.appendingPathComponent("\(packageKey).json"), atomically: true, encoding: .utf8)
    }
    // Commit/push/PR the staged registry checkout (after files are staged into it).
    var transport = WorkflowPackagePublishTransportOutcome(
      mode: parsed.createPR ? .pullRequest : .direct
    )
    if let gitCheckout {
      transport = try finalizePublishGitTransport(
        parsed: parsed,
        registry: registry,
        packageName: packageName,
        git: gitCheckout.git,
        checkout: gitCheckout.root
      )
    }
    try jsonString([
      "packageName": .string(packageName),
      "packageId": .string(packageName),
      "workflowName": .string(bundle.workflow.workflowId),
      "workflowDirectory": .string(workflowDirectory.path),
      "registry": .string(registry.id),
      "registryUrl": .string(registry.url),
      "registryRef": .string(registry.branch),
      "checksum": .string(checksum),
      "checksumAlgorithm": .string(checksumAlgorithm),
      "backends": .array(backends.map { .string($0) }),
      "mode": .string(transport.mode.rawValue),
      "commitSha": transport.commitSha.map { .string($0) } ?? .null,
      "prUrl": transport.prUrl.map { .string($0) } ?? .null,
      "dryRun": .bool(parsed.dryRun)
    ] as JSONObject).write(to: registryRecord, atomically: true, encoding: .utf8)
    return PublishedPackageRecord(
      summary: summary,
      registryRecord: registryRecord,
      checksum: checksum,
      checksumAlgorithm: checksumAlgorithm,
      backends: backends,
      mode: transport.mode,
      commitSha: transport.commitSha,
      prUrl: transport.prUrl
    )
  }

  private struct WorkflowPackagePublishTransportOutcome {
    var mode: WorkflowPackagePublishMode
    var commitSha: String?
    var prUrl: String?
  }

  /// Commit + push (direct) or branch + push + PR (`--create-pr`) a checkout
  /// that has already been ensured clean and had package files staged into it.
  private func finalizePublishGitTransport(
    parsed: ParsedParityOptions,
    registry: PublishRegistryResolution,
    packageName: String,
    git: WorkflowPackagePublishGit,
    checkout: URL
  ) throws -> WorkflowPackagePublishTransportOutcome {
    let commitMessage = "Publish workflow package \(packageName)"
    if parsed.createPR {
      let publishBranch = "riela/publish-\(packageFilesystemKey(packageName))"
      let base = parsed.prBase ?? registry.branch
      try git.checkoutBranch(publishBranch, checkout: checkout)
      let commitSha = try git.commitAll(message: commitMessage, checkout: checkout)
      try git.push(branch: publishBranch, checkout: checkout)
      let adapter = publishPullRequestAdapterFactory(publishCommandExecutor)
      let prURL = try adapter.createPullRequest(WorkflowPackagePullRequestRequest(
        checkoutDirectory: checkout,
        branch: publishBranch,
        base: base,
        title: "Publish \(packageName)",
        body: "Automated workflow package publish for \(packageName)."
      ))
      return WorkflowPackagePublishTransportOutcome(mode: .pullRequest, commitSha: commitSha, prUrl: prURL)
    }
    // Direct mode: probe push permission non-destructively before committing.
    guard try git.canPush(branch: registry.branch, checkout: checkout) else {
      throw CLIUsageError(WorkflowPackagePublishGitError.pushPermissionDenied(branch: registry.branch).description)
    }
    let commitSha = try git.commitAll(message: commitMessage, checkout: checkout)
    try git.push(branch: registry.branch, checkout: checkout)
    return WorkflowPackagePublishTransportOutcome(mode: .direct, commitSha: commitSha)
  }

  private func publishBackendHints(nodePayloads: [String: AgentNodePayload]) -> [String] {
    var seen = Set<String>()
    var backends: [String] = []
    for payload in nodePayloads.values {
      guard let backend = payload.executionBackend?.rawValue else {
        continue
      }
      if seen.insert(backend).inserted {
        backends.append(backend)
      }
    }
    return backends.sorted()
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
}
