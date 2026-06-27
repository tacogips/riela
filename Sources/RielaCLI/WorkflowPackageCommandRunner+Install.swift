import Foundation
import RielaAddons

struct WorkflowPackageInstallation {
  var destination: URL
  var summary: WorkflowPackageSummary
}

extension WorkflowPackageCommandRunner {
  func installPackage(target: String?, parsed: ParsedParityOptions) async throws -> WorkflowPackageInstallation {
    let workingDirectory = URL(
      fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath,
      isDirectory: true
    )
    let resolvedSource = try await sourcePackageDirectory(
      target: target,
      parsed: parsed,
      workingDirectory: workingDirectory,
      allowRegistry: true
    )
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
    let destinationName = try installDestinationPackageName(
      target: target,
      parsed: parsed,
      workingDirectory: workingDirectory,
      manifestName: manifest.name
    )
    let destination = packageRoot(scope: parsed.scope, workingDirectory: workingDirectory)
      .appendingPathComponent(destinationName, isDirectory: true)
    let skillProjections = try packageSkillProjectionPlans(
      manifest: manifest,
      packageRoot: sourceURL,
      scope: parsed.scope,
      workingDirectory: workingDirectory
    )
    try preflightSkillProjections(skillProjections, overwrite: parsed.overwrite)
    let summary = WorkflowPackageSummary(
      name: manifest.name,
      version: manifest.version,
      kind: manifest.kind,
      packageDirectory: destination.path,
      workflowDirectory: manifest.workflowDirectory,
      valid: true,
      issues: []
    )
    if parsed.dryRun {
      return WorkflowPackageInstallation(destination: destination, summary: summary)
    }
    if FileManager.default.fileExists(atPath: destination.path) {
      guard parsed.overwrite else {
        throw CLIUsageError("package destination already exists: \(destination.path); pass --overwrite to replace it")
      }
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: sourceURL, to: destination)
    try installSkillProjections(skillProjections, installedPackageRoot: destination, overwrite: parsed.overwrite)
    return WorkflowPackageInstallation(destination: destination, summary: summary)
  }
}
