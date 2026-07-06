import Foundation
import RielaAddons

public struct PackageRegistryIndexResult: Codable, Equatable, Sendable {
  public var indexPath: String
  public var registryRoot: String
  public var packageCount: Int
  public var dryRun: Bool
  public var checked: Bool
  public var upToDate: Bool
  public var index: WorkflowPackageRegistryIndex
}

public struct WorkflowPackageRegistryIndex: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var registry: WorkflowPackageRegistryIndexRegistry
  public var packages: [WorkflowPackageRegistryIndexPackage]
}

public struct WorkflowPackageRegistryIndexRegistry: Codable, Equatable, Sendable {
  public var id: String
  public var url: String?
}

public struct WorkflowPackageRegistryIndexPackage: Codable, Equatable, Sendable {
  public var name: String
  public var directory: String
  public var archiveURL: String?
  public var archiveSHA256: String?
  public var version: String?
  public var kind: WorkflowPackageKind
  public var title: String?
  public var description: String?
  public var tags: [String]
  public var workflow: WorkflowPackageRegistryIndexWorkflow?
  public var workflowIds: [String]
  public var backends: [String]
  public var requiredEnvironment: [WorkflowPackageEnvironmentVariable]
  public var dependencies: [WorkflowPackageDependency]
  public var checksum: String?
  public var checksumAlgorithm: String?
  public var integrity: WorkflowPackageIntegrity?
  public var addons: [WorkflowPackageRegistryIndexAddon]
}

public struct WorkflowPackageRegistryIndexWorkflow: Codable, Equatable, Sendable {
  public var directory: String?
}

public struct WorkflowPackageRegistryIndexAddon: Codable, Equatable, Sendable {
  public var name: String
  public var version: String
  public var sourcePath: String
  public var contentDigest: String?
  public var execution: WorkflowPackageAddonExecutionDescriptor?
  public var capabilities: [WorkflowAddonCapability]
}

struct WorkflowPackageRegistryIndexGenerator: Sendable {
  func generate(registryRoot: URL, registryId: String, registryURL: String?) async throws -> WorkflowPackageRegistryIndex {
    let packagesRoot = registryRoot.appendingPathComponent("packages", isDirectory: true)
    guard FileManager.default.fileExists(atPath: packagesRoot.path) else {
      throw CLIUsageError("registry index generation requires a packages directory: \(packagesRoot.path)")
    }
    let loader = FileWorkflowPackageManifestLoader()
    var packages: [WorkflowPackageRegistryIndexPackage] = []
    for manifestURL in try packageManifestURLs(in: packagesRoot) {
      let packageDirectory = manifestURL.deletingLastPathComponent()
      let manifest = try await loader.loadManifest(from: manifestURL)
      let issues = await loader.validate(manifest, packageRoot: packageDirectory)
      guard issues.isEmpty else {
        let details = issues.map { "\($0.path): \($0.message)" }.joined(separator: "; ")
        throw CLIUsageError("package manifest is invalid for registry index: \(manifestURL.path): \(details)")
      }
      packages.append(indexPackage(
        manifest: manifest,
        packageDirectory: packageDirectory,
        registryRoot: registryRoot,
        registryURL: registryURL
      ))
    }
    return WorkflowPackageRegistryIndex(
      schemaVersion: 1,
      registry: WorkflowPackageRegistryIndexRegistry(id: registryId, url: registryURL),
      packages: packages.sorted { $0.name == $1.name ? $0.directory < $1.directory : $0.name < $1.name }
    )
  }

  func write(
    _ index: WorkflowPackageRegistryIndex,
    to destination: URL,
    registryRoot: URL,
    dryRun: Bool,
    check: Bool
  ) throws -> PackageRegistryIndexResult {
    let data = try encodedIndexData(index)
    let upToDate = (try? Data(contentsOf: destination)) == data
    if check, !upToDate {
      throw CLIUsageError("registry index is stale: \(destination.path); run `riela package registry index \(registryRoot.path)`")
    }
    if !dryRun && !check {
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: destination, options: .atomic)
    }
    return PackageRegistryIndexResult(
      indexPath: destination.path,
      registryRoot: registryRoot.path,
      packageCount: index.packages.count,
      dryRun: dryRun,
      checked: check,
      upToDate: upToDate,
      index: index
    )
  }

  func render(_ result: PackageRegistryIndexResult, output: WorkflowOutputFormat) throws -> CLICommandResult {
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: try jsonString(result))
    case .text, .table:
      let action: String
      if result.checked {
        action = result.upToDate ? "verified" : "stale"
      } else {
        action = result.dryRun ? "would generate" : "generated"
      }
      return CLICommandResult(
        exitCode: .success,
        stdout: "\(action) registry index: \(result.indexPath)\npackages: \(result.packageCount)\n"
      )
    }
  }

  private func indexPackage(
    manifest: WorkflowPackageManifest,
    packageDirectory: URL,
    registryRoot: URL,
    registryURL: String?
  ) -> WorkflowPackageRegistryIndexPackage {
    let summary = workflowPackageSummary(
      manifest: manifest,
      packageDirectory: packageDirectory,
      valid: true,
      issues: []
    )
    return WorkflowPackageRegistryIndexPackage(
      name: manifest.name,
      directory: packageRelativePath(for: packageDirectory, packageRoot: registryRoot),
      archiveURL: releaseArchiveURL(registryURL: registryURL, manifest: manifest),
      archiveSHA256: archiveSHA256(manifest: manifest, packageDirectory: packageDirectory, registryRoot: registryRoot),
      version: manifest.version,
      kind: manifest.kind,
      title: summary.title,
      description: summary.description,
      tags: summary.tags,
      workflow: WorkflowPackageRegistryIndexWorkflow(directory: manifest.workflowDirectory),
      workflowIds: summary.workflowIds ?? [],
      backends: summary.backends ?? [],
      requiredEnvironment: manifest.environmentVariables.filter(\.required),
      dependencies: manifest.dependencies,
      checksum: manifest.checksum,
      checksumAlgorithm: manifest.checksumAlgorithm,
      integrity: manifest.integrity,
      addons: manifest.nodeAddons.map { addon in
        WorkflowPackageRegistryIndexAddon(
          name: addon.name,
          version: addon.version,
          sourcePath: addon.sourcePath,
          contentDigest: addon.contentDigest,
          execution: addon.execution,
          capabilities: addon.capabilities
        )
      }
    )
  }

  private func encodedIndexData(_ index: WorkflowPackageRegistryIndex) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(index)
  }

  private func releaseArchiveURL(registryURL: String?, manifest: WorkflowPackageManifest) -> String? {
    guard let registryURL, let version = manifest.version, !version.isEmpty else {
      return nil
    }
    return registryReleaseArchiveURL(registryURL: registryURL, packageName: manifest.name, version: version)?.absoluteString
  }

  private func archiveSHA256(
    manifest: WorkflowPackageManifest,
    packageDirectory: URL,
    registryRoot: URL
  ) -> String? {
    guard let version = manifest.version, !version.isEmpty else {
      return nil
    }
    let archive = registryRoot
      .appendingPathComponent("releases/download", isDirectory: true)
      .appendingPathComponent(version, isDirectory: true)
      .appendingPathComponent(registryReleaseArchiveAssetName(packageName: manifest.name, version: version))
    guard FileManager.default.fileExists(atPath: archive.path) else {
      return manifest.integrity?.digestAlgorithm == "sha256" ? manifest.integrity?.digest : nil
    }
    return try? sha256Digest(for: archive)
  }
}

func registryReleaseArchiveAssetName(packageName: String, version: String) -> String {
  "\(packageFilesystemKey(packageName))-\(packageFilesystemKey(version)).\(WorkflowPackageArchiveManager.packageExtension)"
}

func registryReleaseArchiveURL(registryURL: String, packageName: String, version: String) -> URL? {
  guard var components = URLComponents(string: registryURL) else {
    return nil
  }
  components.path = components.path
    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    .split(separator: "/")
    .reduce(into: "") { path, component in path += "/\(component)" }
  components.path += "/releases/download/\(version)/\(registryReleaseArchiveAssetName(packageName: packageName, version: version))"
  return components.url
}
