import Foundation
import RielaAddons

extension WorkflowPackageCommandRunner {
  struct ResolvedPackageSource {
    var directory: URL
    var temporaryRoot: URL?
  }

  struct PackageValidation {
    var packageDirectory: URL
    var summary: WorkflowPackageSummary
  }

  struct PackedPackage {
    var archiveURL: URL
    var summary: WorkflowPackageSummary
  }

  func validatePackage(target: String?, parsed: ParsedParityOptions) async throws -> PackageValidation {
    let workingDirectory = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
    let resolvedSource = try await sourcePackageDirectory(
      target: target,
      parsed: parsed,
      workingDirectory: workingDirectory,
      allowRegistry: false
    )
    defer {
      if let temporaryRoot = resolvedSource.temporaryRoot {
        try? FileManager.default.removeItem(at: temporaryRoot)
      }
    }
    let validation = try await packageValidationSummary(packageDirectory: resolvedSource.directory)
    return PackageValidation(packageDirectory: resolvedSource.directory, summary: validation)
  }

  func packPackage(target: String?, parsed: ParsedParityOptions) async throws -> PackedPackage {
    guard let target, !target.isEmpty else {
      throw CLIUsageError("package pack requires a package directory")
    }
    let workingDirectory = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
    let packageDirectory = absoluteURL(target, relativeTo: workingDirectory).standardizedFileURL
    guard !WorkflowPackageArchiveManager.isPackageArchive(packageDirectory) else {
      throw CLIUsageError("package pack requires an unpacked package directory")
    }
    let summary = try await packageValidationSummary(packageDirectory: packageDirectory)
    guard summary.valid else {
      throw CLIUsageError("package source validation failed: \(summary.issues.map { "\($0.path): \($0.message)" }.joined(separator: "; "))")
    }
    let destination = parsed.destination.map { absoluteURL($0, relativeTo: workingDirectory) }
      ?? workingDirectory.appendingPathComponent("\(packageFilesystemKey(summary.name)).\(WorkflowPackageArchiveManager.packageExtension)")
    if !parsed.dryRun {
      try WorkflowPackageArchiveManager().createArchive(
        from: packageDirectory,
        to: destination,
        overwrite: parsed.overwrite
      )
    }
    return PackedPackage(archiveURL: destination.standardizedFileURL, summary: summary)
  }

  func packageValidationSummary(packageDirectory: URL) async throws -> WorkflowPackageSummary {
    let manifestURL = packageDirectory.appendingPathComponent(WorkflowPackageArchiveManager.manifestFileName)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      throw CLIUsageError("package source must contain riela-package.json: \(packageDirectory.path)")
    }
    let loader = FileWorkflowPackageManifestLoader()
    let manifest = try await loader.loadManifest(from: manifestURL)
    let issues = await loader.validate(manifest, packageRoot: packageDirectory)
    return WorkflowPackageSummary(
      name: manifest.name,
      version: manifest.version,
      kind: manifest.kind,
      packageDirectory: packageDirectory.path,
      workflowDirectory: manifest.workflowDirectory,
      valid: issues.isEmpty,
      issues: issues
    )
  }

  func installDestinationPackageName(
    target: String?,
    parsed: ParsedParityOptions,
    workingDirectory: URL,
    manifestName: String
  ) throws -> String {
    let targetIsPackageIdentifier: Bool
    if let target, !target.isEmpty, parsed.source == nil {
      let targetURL = absoluteURL(target, relativeTo: workingDirectory)
      targetIsPackageIdentifier = WorkflowPackageManifestValidator.isSafePackageName(target)
        && !FileManager.default.fileExists(atPath: targetURL.path)
        && !WorkflowPackageArchiveManager.isPackageArchive(targetURL)
    } else {
      targetIsPackageIdentifier = false
    }
    guard targetIsPackageIdentifier, let target else {
      guard WorkflowPackageManifestValidator.isSafePackageName(manifestName) else {
        throw CLIUsageError("invalid package name '\(manifestName)'")
      }
      return manifestName
    }
    return target
  }

  func runnablePackageSource(
    target: String,
    parsed: ParsedParityOptions,
    workingDirectory: URL
  ) async throws -> ResolvedPackageSource {
    if let source = parsed.source {
      return try materializedPackageSource(absoluteURL(source, relativeTo: workingDirectory), workingDirectory: workingDirectory)
    }
    let targetURL = absoluteURL(target, relativeTo: workingDirectory)
    if FileManager.default.fileExists(atPath: targetURL.path) || WorkflowPackageArchiveManager.isPackageArchive(targetURL) {
      return try materializedPackageSource(targetURL, workingDirectory: workingDirectory)
    }
    return ResolvedPackageSource(directory: try packageDirectory(target: target, parsed: parsed), temporaryRoot: nil)
  }

  func sourcePackageDirectory(
    target: String?,
    parsed: ParsedParityOptions,
    workingDirectory: URL,
    allowRegistry: Bool
  ) async throws -> ResolvedPackageSource {
    if let source = parsed.source {
      return try materializedPackageSource(absoluteURL(source, relativeTo: workingDirectory), workingDirectory: workingDirectory)
    }
    if let target, !target.isEmpty {
      let targetURL = absoluteURL(target, relativeTo: workingDirectory)
      if FileManager.default.fileExists(atPath: targetURL.path) || WorkflowPackageArchiveManager.isPackageArchive(targetURL) {
        return try materializedPackageSource(targetURL, workingDirectory: workingDirectory)
      }
      guard WorkflowPackageManifestValidator.isSafePackageName(target) else {
        throw CLIUsageError("invalid package name '\(target)'")
      }
      if !allowRegistry {
        let installedDirectory = try packageDirectory(target: target, parsed: parsed)
        if FileManager.default.fileExists(atPath: installedDirectory.path) {
          return ResolvedPackageSource(directory: installedDirectory, temporaryRoot: nil)
        }
      }
      if allowRegistry,
        let registrySource = try await registryPackageSource(named: target, parsed: parsed, workingDirectory: workingDirectory) {
        return ResolvedPackageSource(directory: registrySource, temporaryRoot: nil)
      }
    }
    let command = allowRegistry ? "install" : "validate"
    throw CLIUsageError("package \(command) requires a package directory, .rielapkg archive, or --source <package-source>")
  }

  func materializedPackageSource(_ sourceURL: URL, workingDirectory: URL) throws -> ResolvedPackageSource {
    let sourceURL = sourceURL.standardizedFileURL
    if WorkflowPackageArchiveManager.isPackageArchive(sourceURL) {
      let temporaryRoot = temporaryPackageExtractionRoot(workingDirectory: workingDirectory)
      let packageRoot = try WorkflowPackageArchiveManager().extractArchive(sourceURL, to: temporaryRoot)
      return ResolvedPackageSource(directory: packageRoot, temporaryRoot: temporaryRoot)
    }
    return ResolvedPackageSource(directory: sourceURL, temporaryRoot: nil)
  }

  func temporaryPackageExtractionRoot(workingDirectory: URL) -> URL {
    workingDirectory
      .appendingPathComponent(".riela/tmp/rielapkg", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }
}
