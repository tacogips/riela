import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaAddons
import RielaCore

extension WorkflowPackageCommandRunner {
  struct ResolvedPackageSource {
    var directory: URL
    var temporaryRoot: URL?
    var archiveURL: URL?
    var sourceReference: String?

    init(
      directory: URL,
      temporaryRoot: URL?,
      archiveURL: URL? = nil,
      sourceReference: String? = nil
    ) {
      self.directory = directory
      self.temporaryRoot = temporaryRoot
      self.archiveURL = archiveURL
      self.sourceReference = sourceReference
    }
  }

  struct PackageValidation {
    var source: URL
    var summary: WorkflowPackageSummary
  }

  struct PackedPackage {
    var archiveURL: URL
    var summary: WorkflowPackageSummary
  }

  struct InitializedPackage {
    var manifestURL: URL
    var summary: WorkflowPackageSummary
  }

  func initializePackage(target: String?, parsed: ParsedParityOptions) async throws -> InitializedPackage {
    guard let target, !target.isEmpty else {
      throw CLIUsageError("package init requires a workflow or package directory")
    }
    let workingDirectory = URL(
      fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath,
      isDirectory: true
    )
    let packageDirectory = absoluteURL(target, relativeTo: workingDirectory).standardizedFileURL
    guard FileManager.default.fileExists(atPath: packageDirectory.path) else {
      throw CLIUsageError("package init directory does not exist: \(packageDirectory.path)")
    }
    let manifestURL = packageDirectory.appendingPathComponent(WorkflowPackageArchiveManager.manifestFileName)
    if FileManager.default.fileExists(atPath: manifestURL.path), !parsed.overwrite {
      throw CLIUsageError("package manifest already exists: \(manifestURL.path); pass --overwrite to replace it")
    }
    let workflowRelativePath = try initialWorkflowRelativePath(
      parsed.workflowDefinitionDir,
      packageDirectory: packageDirectory
    )
    let workflowDirectory = packageDirectory.appendingPathComponent(workflowRelativePath, isDirectory: true)
    guard FileManager.default.fileExists(atPath: workflowDirectory.appendingPathComponent("workflow.json").path) else {
      throw CLIUsageError("package init workflow directory must contain workflow.json: \(workflowDirectory.path)")
    }
    let bundle: ResolvedWorkflowBundle
    do {
      bundle = try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
        workflowName: workflowDirectory.lastPathComponent,
        scope: .direct,
        workflowDefinitionDir: workflowDirectory.path,
        workingDirectory: workingDirectory.path
      ))
    } catch {
      throw CLIUsageError(
        "package init workflow validation failed: \(packageInitWorkflowValidationErrorDescription(error))"
      )
    }
    let packageName = parsed.packageName ?? parsed.packageID ?? bundle.workflow.workflowId
    guard WorkflowPackageManifestValidator.isSafePackageName(packageName) else {
      throw CLIUsageError("invalid package name '\(packageName)'; pass --package-name <safe-name>")
    }
    let manifest = initialPackageManifest(
      packageName: packageName,
      workflowId: bundle.workflow.workflowId,
      workflowDirectory: workflowRelativePath,
      checksum: try initialPackageChecksum(packageRoot: packageDirectory)
    )
    let issues = WorkflowPackageManifestValidator.validatePackageSource(manifest, packageRoot: packageDirectory)
    let summary = WorkflowPackageSummary(
      name: manifest.name,
      version: manifest.version,
      kind: manifest.kind,
      tags: manifest.tags,
      packageDirectory: packageDirectory.path,
      workflowDirectory: manifest.workflowDirectory,
      valid: issues.isEmpty,
      issues: issues
    )
    guard issues.isEmpty else {
      throw CLIUsageError("generated package manifest is invalid: \(issues.map { "\($0.path): \($0.message)" }.joined(separator: "; "))")
    }
    if !parsed.dryRun {
      try writeInitialPackageManifest(manifest, to: manifestURL)
    }
    return InitializedPackage(manifestURL: manifestURL.standardizedFileURL, summary: summary)
  }

  func validatePackage(target: String?, parsed: ParsedParityOptions) async throws -> PackageValidation {
    let workingDirectory = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
    let resolvedSource = try await sourcePackageDirectory(
      target: target,
      parsed: parsed,
      workingDirectory: workingDirectory,
      allowRegistry: false
    )
    let source = validatePackageResultSource(
      target: target,
      parsed: parsed,
      workingDirectory: workingDirectory,
      resolvedDirectory: resolvedSource.directory
    )
    defer {
      if let temporaryRoot = resolvedSource.temporaryRoot {
        try? FileManager.default.removeItem(at: temporaryRoot)
      }
    }
    var validation = try await packageValidationSummary(packageDirectory: resolvedSource.directory)
    validation.packageDirectory = source.path
    return PackageValidation(source: source, summary: validation)
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
      ?? packageDirectory.deletingLastPathComponent()
        .appendingPathComponent("\(packageFilesystemKey(summary.name)).\(WorkflowPackageArchiveManager.packageExtension)")
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
    let issues = await loader.validate(manifest, packageRoot: packageDirectory, verifiesChecksum: true)
    return workflowPackageSummary(
      manifest: manifest,
      packageDirectory: packageDirectory,
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
      if allowRegistry, parsed.refresh {
        try await refreshRegistryIndexes(parsed: parsed, workingDirectory: workingDirectory)
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
      if allowRegistry,
        let archiveSource = try await registryPackageArchiveSource(
          named: target,
          parsed: parsed,
          workingDirectory: workingDirectory
        ) {
        return try await materializedRegistryArchiveSource(archiveSource, workingDirectory: workingDirectory)
      }
      if allowRegistry {
        let searched = try packageRegistryCandidateRootPaths(parsed: parsed, workingDirectory: workingDirectory)
        throw CLIUsageError(
          "package install could not resolve package '\(target)'; searched registry roots: \(searched.joined(separator: ", "))"
        )
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
      return ResolvedPackageSource(directory: packageRoot, temporaryRoot: temporaryRoot, archiveURL: sourceURL)
    }
    return ResolvedPackageSource(directory: sourceURL, temporaryRoot: nil)
  }

  func materializedRegistryArchiveSource(
    _ source: RegistryArchiveSource,
    workingDirectory: URL
  ) async throws -> ResolvedPackageSource {
    let temporaryRoot = temporaryPackageExtractionRoot(workingDirectory: workingDirectory)
    let downloadRoot = temporaryRoot.appendingPathComponent("archive", isDirectory: true)
    let extractionRoot = temporaryRoot.appendingPathComponent("extract", isDirectory: true)
    try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
    let archiveURL = try await downloadRegistryArchive(source.archiveURL, into: downloadRoot)
    let actualDigest = try sha256Digest(for: archiveURL)
    guard actualDigest == source.archiveSHA256 else {
      throw CLIUsageError(
        "registry package '\(source.packageName)' archiveSHA256 mismatch: expected \(source.archiveSHA256), got \(actualDigest)"
      )
    }
    let packageRoot = try WorkflowPackageArchiveManager().extractArchive(archiveURL, to: extractionRoot)
    return ResolvedPackageSource(
      directory: packageRoot,
      temporaryRoot: temporaryRoot,
      archiveURL: archiveURL,
      sourceReference: source.archiveURL.absoluteString
    )
  }

  func temporaryPackageExtractionRoot(workingDirectory: URL) -> URL {
    workingDirectory
      .appendingPathComponent(".riela/tmp/rielapkg", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  private func downloadRegistryArchive(_ sourceURL: URL, into temporaryRoot: URL) async throws -> URL {
    let destination = temporaryRoot.appendingPathComponent(sourceURL.lastPathComponent)
    if sourceURL.isFileURL {
      try FileManager.default.copyItem(at: sourceURL, to: destination)
      return destination
    }
    let (downloadedURL, response) = try await URLSession.shared.download(from: sourceURL)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw CLIUsageError("package archive download failed with HTTP \(http.statusCode): \(sourceURL.absoluteString)")
    }
    try FileManager.default.moveItem(at: downloadedURL, to: destination)
    return destination
  }

  private func validatePackageResultSource(
    target: String?,
    parsed: ParsedParityOptions,
    workingDirectory: URL,
    resolvedDirectory: URL
  ) -> URL {
    if let source = parsed.source {
      return absoluteURL(source, relativeTo: workingDirectory).standardizedFileURL
    }
    if let target, !target.isEmpty {
      let targetURL = absoluteURL(target, relativeTo: workingDirectory).standardizedFileURL
      if FileManager.default.fileExists(atPath: targetURL.path) || WorkflowPackageArchiveManager.isPackageArchive(targetURL) {
        return targetURL
      }
    }
    return resolvedDirectory.standardizedFileURL
  }

  private func initialWorkflowRelativePath(_ rawPath: String?, packageDirectory: URL) throws -> String {
    let candidate = try rawPath ?? inferredInitialWorkflowRelativePath(packageDirectory: packageDirectory)
    guard let normalized = WorkflowPackageManifestValidator.normalizePackageRelativePath(candidate) else {
      throw CLIUsageError(
        "package init --workflow-definition-dir must stay inside the package; use a relative path without '..': \(candidate)"
      )
    }
    return normalized
  }

  private func inferredInitialWorkflowRelativePath(packageDirectory: URL) throws -> String {
    if FileManager.default.fileExists(atPath: packageDirectory.appendingPathComponent("workflow.json").path) {
      return "."
    }
    let workflowsRoot = packageDirectory.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectories = directChildWorkflowDirectories(in: workflowsRoot)
    switch workflowDirectories.count {
    case 1:
      return "workflows/\(workflowDirectories[0].lastPathComponent)"
    case 2...:
      let candidates = workflowDirectories
        .map { "workflows/\($0.lastPathComponent)" }
        .joined(separator: ", ")
      throw CLIUsageError(
        "package init found multiple workflow directories; pass --workflow-definition-dir <relative-path>: \(candidates)"
      )
    default:
      return "."
    }
  }

  private func directChildWorkflowDirectories(in workflowsRoot: URL) -> [URL] {
    guard let children = try? FileManager.default.contentsOfDirectory(
      at: workflowsRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }
    return children
      .filter { child in
        let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return isDirectory && FileManager.default.fileExists(atPath: child.appendingPathComponent("workflow.json").path)
      }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func initialPackageManifest(
    packageName: String,
    workflowId: String,
    workflowDirectory: String,
    checksum: String
  ) -> WorkflowPackageManifest {
    WorkflowPackageManifest(
      name: packageName,
      version: "0.1.0",
      description: "Riela workflow package for \(workflowId)",
      tags: ["workflow"],
      registry: "local",
      checksum: checksum,
      checksumAlgorithm: "md5",
      workflowDirectory: workflowDirectory
    )
  }

  private func initialPackageChecksum(packageRoot: URL) throws -> String {
    try WorkflowPackageChecksum.md5(packageRoot: packageRoot)
  }

  private func writeInitialPackageManifest(_ manifest: WorkflowPackageManifest, to manifestURL: URL) throws {
    let payload: [String: Any] = [
      "checksum": manifest.checksum ?? "",
      "checksumAlgorithm": manifest.checksumAlgorithm ?? "",
      "description": manifest.description ?? "",
      "name": manifest.name,
      "registry": manifest.registry ?? "",
      "tags": manifest.tags,
      "version": manifest.version ?? "",
      "workflowDirectory": manifest.workflowDirectory ?? "."
    ]
    var data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    data.append(0x0A)
    try data.write(to: manifestURL, options: [.atomic])
  }

  private func packageInitWorkflowValidationErrorDescription(_ error: Error) -> String {
    let description = workflowResolutionErrorDescription(error)
    let hints = packageInitWorkflowValidationHints(error)
    guard !hints.isEmpty else {
      return description
    }
    return ([description] + hints.map { "Hint: \($0)" }).joined(separator: "\n")
  }

  private func packageInitWorkflowValidationHints(_ error: Error) -> [String] {
    guard let resolutionError = error as? WorkflowResolutionError,
      case let .invalidWorkflow(diagnostics) = resolutionError
    else {
      return []
    }
    var hints: [String] = []
    if diagnostics.contains(where: isLikelyInlineNodeDiagnostic) {
      hints.append(
        "workflow.json nodes must reference nodeFile, nodeRef, or addon; "
          + "move backend/model/prompt fields into a node JSON file and reference it with nodeFile."
      )
    }
    if diagnostics.contains(where: { $0.path == "workflow.workflowId" || $0.path == "workflow.defaults" }) {
      hints.append(
        "start from examples/worker-only-single-step for the current workflow schema, then rerun riela package init."
      )
    }
    return hints
  }

  private func isLikelyInlineNodeDiagnostic(_ diagnostic: WorkflowValidationDiagnostic) -> Bool {
    diagnostic.path.hasPrefix("workflow.nodes[")
      && (diagnostic.message.contains("unsupported step-addressed node registry field")
        || diagnostic.message.contains("must define exactly one of nodeFile, nodeRef, or addon"))
  }
}
