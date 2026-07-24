import Foundation
import RielaAddons
import RielaCore

extension WorkflowPackageCommandRunner {
  func packageSummaryRoots(
    parsed: ParsedParityOptions,
    workingDirectory: URL
  ) throws -> [PackageSummaryRoot] {
    let installedRoots = packageRoots(parsed: parsed, workingDirectory: workingDirectory).map {
      PackageSummaryRoot(url: $0, source: "installed")
    }
    let registryRoots = try selectedPackageRegistries(parsed: parsed, workingDirectory: workingDirectory)
      .flatMap { registry in
        registryPackageRoots(registry: registry, parsed: parsed, workingDirectory: workingDirectory)
      }
    return uniquePackageRoots(installedRoots + registryRoots)
  }

  func registryPackageRoots(
    registry: WorkflowPackageRegistryEntry,
    parsed: ParsedParityOptions,
    workingDirectory: URL
  ) -> [PackageSummaryRoot] {
    if let localPath = parsed.localPath {
      return [registryPackagesRoot(localPath, relativeTo: workingDirectory, source: "flag")]
    }
    var roots: [PackageSummaryRoot] = []
    if let localPath = registry.localPath {
      roots.append(registryPackagesRoot(localPath, relativeTo: workingDirectory, source: "configured"))
    }
    roots.append(PackageSummaryRoot(
      url: URL(fileURLWithPath: "\(workingDirectory.path)-packages", isDirectory: true)
        .appendingPathComponent("packages", isDirectory: true),
      source: "sibling"
    ))
    roots.append(PackageSummaryRoot(
      url: managedRegistryCacheRoot(id: registry.id).appendingPathComponent("packages", isDirectory: true),
      source: "managed"
    ))
    return uniquePackageRoots(roots)
  }

  private func registryPackagesRoot(
    _ localPath: String,
    relativeTo workingDirectory: URL,
    source: String
  ) -> PackageSummaryRoot {
    PackageSummaryRoot(
      url: absoluteURL(localPath, relativeTo: workingDirectory)
        .appendingPathComponent("packages", isDirectory: true),
      source: source
    )
  }

  private func uniquePackageRoots(_ roots: [PackageSummaryRoot]) -> [PackageSummaryRoot] {
    var seen = Set<String>()
    return roots.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
  }

  func inferredPackageName(from packageDirectory: URL) -> String {
    let name = packageDirectory.lastPathComponent
    let scope = packageDirectory.deletingLastPathComponent().lastPathComponent
    return scope.hasPrefix("@") ? "\(scope)/\(name)" : name
  }

  func removePackage(target: String?, parsed: ParsedParityOptions) throws -> URL {
    guard let target, !target.isEmpty else {
      throw CLIUsageError("package remove requires a package name")
    }
    guard WorkflowPackageManifestValidator.isSafePackageName(target) else {
      throw CLIUsageError("invalid package name '\(target)'")
    }
    let workingDirectory = URL(
      fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath,
      isDirectory: true
    )
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
      try removeWorkflowPackageLockEntry(
        packageName: target,
        parsed: parsed,
        workingDirectory: workingDirectory
      )
    }
    return destination
  }
}
