import Foundation
import RielaAddons

struct WorkflowPackageInstallation {
  var destination: URL
  var summary: WorkflowPackageSummary
  var dependencies: [WorkflowPackageSummary] = []
}

struct WorkflowPackageLockedInstallation {
  var lockfile: URL
  var packages: [WorkflowPackageSummary]
  var dependencies: [WorkflowPackageSummary] = []
}

private struct LockedPackageSource {
  var resolvedSource: WorkflowPackageCommandRunner.ResolvedPackageSource
  var sourceKind: String
  var sourceReference: String?
}

private final class WorkflowPackageInstallTransaction: @unchecked Sendable {
  private let lock = NSLock()
  private var packageDirectories: [URL] = []
  private var skillProjectionDestinations: [URL] = []
  private var lockEntries: [WorkflowPackageLockEntry] = []

  func recordCreatedPackageDirectory(_ url: URL) {
    lock.lock()
    packageDirectories.append(url)
    lock.unlock()
  }

  func recordCreatedSkillProjection(_ url: URL) {
    lock.lock()
    skillProjectionDestinations.append(url)
    lock.unlock()
  }

  func recordLockEntry(_ entry: WorkflowPackageLockEntry) {
    lock.lock()
    lockEntries.removeAll { $0.name == entry.name }
    lockEntries.append(entry)
    lock.unlock()
  }

  func recordedLockEntries() -> [WorkflowPackageLockEntry] {
    lock.lock()
    defer { lock.unlock() }
    return lockEntries
  }

  func rollbackCreatedArtifacts() {
    lock.lock()
    let skillProjectionDestinations = self.skillProjectionDestinations
    let packageDirectories = self.packageDirectories
    lock.unlock()
    for destination in skillProjectionDestinations.reversed() where FileManager.default.fileExists(atPath: destination.path) {
      try? FileManager.default.removeItem(at: destination)
    }
    for directory in packageDirectories.reversed() where FileManager.default.fileExists(atPath: directory.path) {
      try? FileManager.default.removeItem(at: directory)
    }
  }
}

extension WorkflowPackageCommandRunner {
  func installPackage(target: String?, parsed: ParsedParityOptions) async throws -> WorkflowPackageInstallation {
    let transaction = WorkflowPackageInstallTransaction()
    do {
      let installation = try await installPackage(
        target: target,
        parsed: parsed,
        dependencyStack: [],
        isDependency: false,
        transaction: transaction
      )
      if !parsed.dryRun {
        let workingDirectory = URL(
          fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath,
          isDirectory: true
        )
        try writeWorkflowPackageLock(
          entries: transaction.recordedLockEntries(),
          parsed: parsed,
          workingDirectory: workingDirectory
        )
      }
      return installation
    } catch {
      transaction.rollbackCreatedArtifacts()
      throw error
    }
  }

  func installLockedPackages(target: String?, parsed: ParsedParityOptions) async throws -> WorkflowPackageLockedInstallation {
    let workingDirectory = URL(
      fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath,
      isDirectory: true
    )
    let lockURL = workflowPackageLockURL(parsed: parsed, workingDirectory: workingDirectory)
    guard FileManager.default.fileExists(atPath: lockURL.path) else {
      throw CLIUsageError("package ci requires riela-lock.json: \(lockURL.path)")
    }
    let lock = try readWorkflowPackageLock(at: lockURL)
    let entries = lockedPackageEntries(lock, target: target)
    guard !entries.isEmpty else {
      throw CLIUsageError(target.map { "package ci target not found in lockfile: \($0)" } ?? "package ci lockfile is empty")
    }

    let transaction = WorkflowPackageInstallTransaction()
    var packages: [WorkflowPackageSummary] = []
    var dependencies: [WorkflowPackageSummary] = []
    do {
      for entry in entries {
        var installOptions = parsed
        installOptions.overwrite = true
        installOptions.noDependencies = true
        let lockedSource = try await resolvedLockedPackageSource(
          entry,
          parsed: parsed,
          workingDirectory: workingDirectory
        )
        let installation = try await installPackage(
          target: entry.name,
          parsed: installOptions,
          dependencyStack: [],
          isDependency: false,
          transaction: transaction,
          lockedSource: lockedSource,
          expectedLockEntry: entry
        )
        packages.append(installation.summary)
        dependencies.append(contentsOf: installation.dependencies)
      }
      if !parsed.dryRun {
        try writeWorkflowPackageLock(
          entries: transaction.recordedLockEntries(),
          parsed: parsed,
          workingDirectory: workingDirectory
        )
      }
      return WorkflowPackageLockedInstallation(lockfile: lockURL, packages: packages, dependencies: dependencies)
    } catch {
      transaction.rollbackCreatedArtifacts()
      throw error
    }
  }

  private func installPackage(
    target: String?,
    parsed: ParsedParityOptions,
    dependencyStack: [String],
    isDependency: Bool,
    transaction: WorkflowPackageInstallTransaction,
    lockedSource: LockedPackageSource? = nil,
    expectedLockEntry: WorkflowPackageLockEntry? = nil
  ) async throws -> WorkflowPackageInstallation {
    let workingDirectory = URL(
      fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath,
      isDirectory: true
    )
    let resolvedSource: ResolvedPackageSource
    if let lockedSource {
      resolvedSource = lockedSource.resolvedSource
    } else {
      resolvedSource = try await sourcePackageDirectory(
        target: target,
        parsed: parsed,
        workingDirectory: workingDirectory,
        allowRegistry: true
      )
    }
    defer {
      if let temporaryRoot = resolvedSource.temporaryRoot {
        try? FileManager.default.removeItem(at: temporaryRoot)
      }
    }
    let sourceURL = resolvedSource.directory
    let loader = FileWorkflowPackageManifestLoader()
    let manifest = try await loader.loadManifest(
      from: sourceURL.appendingPathComponent(WorkflowPackageArchiveManager.manifestFileName)
    )
    let issues = await loader.validate(manifest, packageRoot: sourceURL, verifiesChecksum: true)
    guard issues.isEmpty else {
      let issueSummary = issues.map { "\($0.path): \($0.message)" }.joined(separator: "; ")
      throw CLIUsageError("package source validation failed: \(issueSummary)")
    }
    if let expectedLockEntry {
      try validateLockedManifest(manifest, matches: expectedLockEntry)
    }
    let destinationName = try installDestinationPackageName(
      target: target,
      parsed: parsed,
      workingDirectory: workingDirectory,
      manifestName: manifest.name
    )
    let destination = packageRoot(scope: parsed.scope, workingDirectory: workingDirectory)
      .appendingPathComponent(destinationName, isDirectory: true)
    if isDependency, FileManager.default.fileExists(atPath: destination.path) {
      let installedManifest = try await FileWorkflowPackageManifestLoader()
        .loadManifest(from: destination.appendingPathComponent(WorkflowPackageArchiveManager.manifestFileName))
      if let expectedRegistry = parsed.registry, installedManifest.registry != expectedRegistry {
        throw CLIUsageError(
          "installed dependency is not equivalent: \(installedManifest.name) registry \(installedManifest.registry ?? "-") != \(expectedRegistry)"
        )
      }
      var summary = try await packageValidationSummary(packageDirectory: destination)
      summary.installState = "satisfied"
      if !parsed.dryRun {
        let lockEntry = try workflowPackageLockEntry(
          manifest: installedManifest,
          sourceReference: installedManifest.name,
          sourceKind: "installed",
          archiveURL: nil
        )
        transaction.recordLockEntry(lockEntry)
      }
      return WorkflowPackageInstallation(destination: destination, summary: summary)
    }
    let dependencies = try await installPackageDependencies(
      manifest: manifest,
      parsed: parsed,
      dependencyStack: dependencyStack,
      transaction: transaction
    )
    let skillProjections = try packageSkillProjectionPlans(
      manifest: manifest,
      packageRoot: sourceURL,
      scope: parsed.scope,
      workingDirectory: workingDirectory
    )
    try preflightSkillProjections(skillProjections, overwrite: parsed.overwrite)
    var summary = workflowPackageSummary(
      manifest: manifest,
      packageDirectory: destination,
      valid: true,
      issues: []
    )
    summary.installState = parsed.dryRun ? "would-install" : "installed"
    if parsed.dryRun {
      return WorkflowPackageInstallation(destination: destination, summary: summary, dependencies: dependencies)
    }
    let destinationExisted = FileManager.default.fileExists(atPath: destination.path)
    if destinationExisted {
      guard parsed.overwrite else {
        throw CLIUsageError("package destination already exists: \(destination.path); pass --overwrite to replace it")
      }
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: sourceURL, to: destination)
    if !destinationExisted {
      transaction.recordCreatedPackageDirectory(destination)
    }
    try installSkillProjections(
      skillProjections,
      installedPackageRoot: destination,
      overwrite: parsed.overwrite,
      recordCreated: transaction.recordCreatedSkillProjection
    )
    let lockEntry = try workflowPackageLockEntry(
      manifest: manifest,
      sourceReference: lockedSource?.sourceReference ?? packageLockSourceReference(
        target: target,
        parsed: parsed,
        sourceURL: sourceURL,
        archiveURL: resolvedSource.archiveURL,
        sourceReference: resolvedSource.sourceReference
      ),
      sourceKind: lockedSource?.sourceKind ?? packageLockSourceKind(parsed: parsed, archiveURL: resolvedSource.archiveURL),
      archiveURL: resolvedSource.archiveURL
    )
    transaction.recordLockEntry(lockEntry)
    return WorkflowPackageInstallation(destination: destination, summary: summary, dependencies: dependencies)
  }

  private func installPackageDependencies(
    manifest: WorkflowPackageManifest,
    parsed: ParsedParityOptions,
    dependencyStack: [String],
    transaction: WorkflowPackageInstallTransaction
  ) async throws -> [WorkflowPackageSummary] {
    guard !parsed.noDependencies else {
      return []
    }
    guard !manifest.dependencies.isEmpty else {
      return []
    }
    var summaries: [WorkflowPackageSummary] = []
    let stack = dependencyStack + [manifest.name]
    for dependency in manifest.dependencies {
      guard !stack.contains(dependency.packageId) else {
        throw CLIUsageError("package dependency cycle detected: \((stack + [dependency.packageId]).joined(separator: " -> "))")
      }
      var dependencyOptions = parsed
      if let registry = dependency.registry, !registry.isEmpty {
        dependencyOptions.registry = registry
      }
      if let branch = dependency.branch, !branch.isEmpty {
        dependencyOptions.branch = branch
      }
      let installed: WorkflowPackageInstallation
      do {
        installed = try await installPackage(
          target: dependency.packageId,
          parsed: dependencyOptions,
          dependencyStack: stack,
          isDependency: true,
          transaction: transaction
        )
      } catch let error as CLIUsageError where parsed.dryRun {
        summaries.append(missingDependencySummary(dependency: dependency, chain: stack, error: error))
        continue
      } catch let error as CLIUsageError {
        throw CLIUsageError("package dependency '\(dependency.packageId)' unresolved in chain \((stack + [dependency.packageId]).joined(separator: " -> ")): \(error.message)")
      }
      summaries.append(contentsOf: installed.dependencies)
      summaries.append(installed.summary)
    }
    return summaries
  }

  private func missingDependencySummary(
    dependency: WorkflowPackageDependency,
    chain: [String],
    error: CLIUsageError
  ) -> WorkflowPackageSummary {
    WorkflowPackageSummary(
      name: dependency.packageId,
      kind: dependency.kind ?? .workflow,
      tags: [],
      installState: "missing",
      packageDirectory: "",
      valid: false,
      issues: [
        WorkflowPackageValidationIssue(
          code: "PACKAGE_DEPENDENCY_MISSING",
          path: dependency.packageId,
          message: "dependency missing in chain \((chain + [dependency.packageId]).joined(separator: " -> ")): \(error.message)"
        )
      ]
    )
  }

  private func packageLockSourceKind(parsed: ParsedParityOptions, archiveURL: URL?) -> String {
    if archiveURL != nil {
      return "archive"
    }
    if parsed.source != nil {
      return "source"
    }
    if parsed.localPath != nil || parsed.registry != nil || parsed.registryURL != nil {
      return "registry"
    }
    return "registry"
  }

  private func packageLockSourceReference(
    target: String?,
    parsed: ParsedParityOptions,
    sourceURL: URL,
    archiveURL: URL?,
    sourceReference: String?
  ) -> String? {
    if let sourceReference {
      return sourceReference
    }
    if let archiveURL {
      return archiveURL.path
    }
    if let source = parsed.source {
      return source
    }
    if let target, !target.isEmpty {
      return target
    }
    return sourceURL.path
  }

  private func lockedPackageEntries(
    _ lock: WorkflowPackageLockFile,
    target: String?
  ) -> [WorkflowPackageLockEntry] {
    if let target, !target.isEmpty {
      return lock.packages[target].map { [$0] } ?? []
    }
    return lock.packages.keys.sorted().compactMap { lock.packages[$0] }
  }

  private func resolvedLockedPackageSource(
    _ entry: WorkflowPackageLockEntry,
    parsed: ParsedParityOptions,
    workingDirectory: URL
  ) async throws -> LockedPackageSource? {
    switch entry.source.kind {
    case "archive":
      guard let reference = entry.source.reference, !reference.isEmpty else {
        throw CLIUsageError("package ci locked archive is missing source.reference: \(entry.name)")
      }
      let source = try await materializedLockedArchiveSource(
        reference: reference,
        expectedDigest: entry.source.archiveDigest,
        workingDirectory: workingDirectory
      )
      return LockedPackageSource(resolvedSource: source, sourceKind: "archive", sourceReference: reference)
    case "source":
      guard let reference = entry.source.reference, !reference.isEmpty else {
        throw CLIUsageError("package ci locked source is missing source.reference: \(entry.name)")
      }
      let sourceURL = absoluteURL(reference, relativeTo: workingDirectory)
      let resolved = try materializedPackageSource(sourceURL, workingDirectory: workingDirectory)
      return LockedPackageSource(resolvedSource: resolved, sourceKind: "source", sourceReference: reference)
    case "registry", "installed":
      return nil
    default:
      throw CLIUsageError("package ci unsupported lock source kind '\(entry.source.kind)' for \(entry.name)")
    }
  }

  private func materializedLockedArchiveSource(
    reference: String,
    expectedDigest: String?,
    workingDirectory: URL
  ) async throws -> ResolvedPackageSource {
    let temporaryRoot = temporaryPackageExtractionRoot(workingDirectory: workingDirectory)
    do {
      try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
      let archiveURL = try await lockedArchiveURL(reference: reference, into: temporaryRoot, workingDirectory: workingDirectory)
      if let expectedDigest, !expectedDigest.isEmpty {
        let actualDigest = try sha256Digest(for: archiveURL)
        guard actualDigest == expectedDigest else {
          throw CLIUsageError("package ci archiveSHA256 mismatch for \(reference): expected \(expectedDigest), got \(actualDigest)")
        }
      }
      let packageRoot = try WorkflowPackageArchiveManager().extractArchive(archiveURL, to: temporaryRoot)
      return ResolvedPackageSource(
        directory: packageRoot,
        temporaryRoot: temporaryRoot,
        archiveURL: archiveURL,
        sourceReference: reference
      )
    } catch {
      try? FileManager.default.removeItem(at: temporaryRoot)
      throw error
    }
  }

  private func lockedArchiveURL(
    reference: String,
    into temporaryRoot: URL,
    workingDirectory: URL
  ) async throws -> URL {
    if let url = URL(string: reference), let scheme = url.scheme, !scheme.isEmpty {
      switch scheme {
      case "file":
        return url.standardizedFileURL
      case "http", "https":
        let destination = temporaryRoot.appendingPathComponent(url.lastPathComponent.isEmpty ? "package.rielapkg" : url.lastPathComponent)
        let (downloadedURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
          throw CLIUsageError("package ci archive download failed with HTTP \(http.statusCode): \(reference)")
        }
        try FileManager.default.moveItem(at: downloadedURL, to: destination)
        return destination
      default:
        throw CLIUsageError("package ci unsupported archive URL scheme '\(scheme)': \(reference)")
      }
    }
    return absoluteURL(reference, relativeTo: workingDirectory).standardizedFileURL
  }

  private func validateLockedManifest(
    _ manifest: WorkflowPackageManifest,
    matches entry: WorkflowPackageLockEntry
  ) throws {
    var mismatches: [String] = []
    if manifest.name != entry.name {
      mismatches.append("name \(manifest.name) != \(entry.name)")
    }
    if manifest.version != entry.version {
      mismatches.append("version \(manifest.version ?? "-") != \(entry.version ?? "-")")
    }
    if manifest.kind != entry.kind {
      mismatches.append("kind \(manifest.kind.rawValue) != \(entry.kind.rawValue)")
    }
    if let expected = entry.registry, manifest.registry != expected {
      mismatches.append("registry \(manifest.registry ?? "-") != \(expected)")
    }
    if let expected = entry.checksum, manifest.checksum != expected {
      mismatches.append("checksum \(manifest.checksum ?? "-") != \(expected)")
    }
    if let expected = entry.checksumAlgorithm, manifest.checksumAlgorithm != expected {
      mismatches.append("checksumAlgorithm \(manifest.checksumAlgorithm ?? "-") != \(expected)")
    }
    if let expected = entry.integrity, manifest.integrity != expected {
      mismatches.append("integrity mismatch")
    }
    var addons: [WorkflowPackageAddonSummary] = []
    for addon in manifest.nodeAddons {
      addons.append(WorkflowPackageAddonSummary(
        name: addon.name,
        version: addon.version,
        sourcePath: addon.sourcePath,
        executionKind: addon.execution?.kind,
        contentDigest: addon.contentDigest
      ))
    }
    addons.sort { left, right in
      left.name == right.name ? left.version < right.version : left.name < right.name
    }
    if !entry.addons.isEmpty && addons != entry.addons {
      mismatches.append("addons mismatch")
    }
    guard mismatches.isEmpty else {
      throw CLIUsageError("package ci lock mismatch for \(entry.name): \(mismatches.joined(separator: "; "))")
    }
  }

  func updatePackages(target: String?, parsed: ParsedParityOptions) async throws -> [WorkflowPackageSummary] {
    let workingDirectory = URL(
      fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath,
      isDirectory: true
    )
    let installedTargets: [String]
    if parsed.all {
      installedTargets = try installedPackageNames(parsed: parsed, workingDirectory: workingDirectory)
    } else if let target, !target.isEmpty {
      installedTargets = [target]
    } else {
      throw CLIUsageError("\(parsed.scope.rawValue) update requires a package name or --all")
    }
    guard !installedTargets.isEmpty else {
      throw CLIUsageError("installed package not found")
    }

    var updates: [WorkflowPackageSummary] = []
    for packageName in installedTargets {
      let installedDirectory = try packageDirectory(target: packageName, parsed: parsed)
      guard FileManager.default.fileExists(atPath: installedDirectory.path) else {
        throw CLIUsageError("installed package not found: \(packageName)")
      }
      let installedManifest = try await FileWorkflowPackageManifestLoader()
        .loadManifest(from: installedDirectory.appendingPathComponent(WorkflowPackageArchiveManager.manifestFileName))
      let resolvedSource: ResolvedPackageSource
      do {
        resolvedSource = try await sourcePackageDirectory(
          target: installedManifest.name,
          parsed: parsed,
          workingDirectory: workingDirectory,
          allowRegistry: true
        )
      } catch {
        let searched = try packageRegistryCandidateRootPaths(parsed: parsed, workingDirectory: workingDirectory)
        var failed = workflowPackageSummary(
          manifest: installedManifest,
          packageDirectory: installedDirectory,
          valid: false,
          issues: [
            WorkflowPackageValidationIssue(
              code: "PACKAGE_UPDATE_SOURCE_NOT_FOUND",
              path: installedManifest.name,
              message: "package update source not found in selected registries; searched: \(searched.joined(separator: ", ")): \(error)"
            )
          ]
        )
        failed.previousVersion = installedManifest.version
        failed.previousChecksum = installedManifest.checksum
        failed.updateState = "failed"
        updates.append(failed)
        continue
      }
      let sourceManifest: WorkflowPackageManifest
      do {
        defer {
          if let temporaryRoot = resolvedSource.temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
          }
        }
        sourceManifest = try await FileWorkflowPackageManifestLoader()
          .loadManifest(from: resolvedSource.directory.appendingPathComponent(WorkflowPackageArchiveManager.manifestFileName))
      }
      let isChanged = installedManifest.version != sourceManifest.version
        || installedManifest.checksum != sourceManifest.checksum
        || installedManifest.integrity != sourceManifest.integrity
      var summary = workflowPackageSummary(
        manifest: sourceManifest,
        packageDirectory: installedDirectory,
        valid: true,
        issues: []
      )
      summary.previousVersion = installedManifest.version
      summary.previousChecksum = installedManifest.checksum
      if isChanged {
        if parsed.dryRun {
          summary.updateState = "would-update"
        } else {
          var installOptions = parsed
          installOptions.overwrite = true
          let installed = try await installPackage(target: sourceManifest.name, parsed: installOptions)
          summary = installed.summary
          summary.previousVersion = installedManifest.version
          summary.previousChecksum = installedManifest.checksum
          summary.updateState = "updated"
        }
      } else {
        summary.updateState = "up-to-date"
      }
      updates.append(summary)
    }
    return updates
  }

  private func installedPackageNames(parsed: ParsedParityOptions, workingDirectory: URL) throws -> [String] {
    let root = packageRoot(scope: parsed.scope, workingDirectory: workingDirectory)
    guard FileManager.default.fileExists(atPath: root.path) else {
      return []
    }
    return try packageManifestURLs(in: root).map { manifestURL in
      manifestURL.deletingLastPathComponent().lastPathComponent
    }.sorted()
  }
}
