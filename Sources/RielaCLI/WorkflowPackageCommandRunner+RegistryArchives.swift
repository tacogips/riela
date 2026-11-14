import Foundation

struct RegistryArchiveSource {
  var packageName: String
  var archiveURL: URL
  var archiveSHA256: String
}

extension WorkflowPackageCommandRunner {
  func registryPackageArchiveSource(
    named target: String,
    parsed: ParsedParityOptions,
    workingDirectory: URL
  ) async throws -> RegistryArchiveSource? {
    for registry in try selectedPackageRegistries(parsed: parsed, workingDirectory: workingDirectory) {
      guard let localPath = registry.localPath else {
        continue
      }
      let registryRoot = absoluteURL(localPath, relativeTo: workingDirectory)
      let indexURL = registryRoot.appendingPathComponent("registry-index.json")
      guard FileManager.default.fileExists(atPath: indexURL.path) else {
        continue
      }
      let index: RegistryArchiveIndex
      do {
        index = try JSONDecoder().decode(RegistryArchiveIndex.self, from: Data(contentsOf: indexURL))
      } catch {
        throw CLIUsageError("registry index validation failed: \(indexURL.path): \(error)")
      }
      guard let package = index.packages.first(where: { $0.name == target }) else {
        continue
      }
      guard let archiveURL = package.archiveURL, !archiveURL.isEmpty else {
        throw CLIUsageError("registry package '\(target)' does not include an archive URL")
      }
      guard let archiveSHA256 = package.archiveSHA256, !archiveSHA256.isEmpty else {
        throw CLIUsageError("registry package '\(target)' does not include archiveSHA256")
      }
      guard let url = URL(string: archiveURL) else {
        throw CLIUsageError("registry package '\(target)' has invalid archive URL: \(archiveURL)")
      }
      return RegistryArchiveSource(packageName: target, archiveURL: url, archiveSHA256: archiveSHA256)
    }
    return nil
  }
}

private struct RegistryArchiveIndex: Decodable {
  var packages: [RegistryArchivePackage]
}

private struct RegistryArchivePackage: Decodable {
  var name: String
  var archiveURL: String?
  var archiveSHA256: String?
}
