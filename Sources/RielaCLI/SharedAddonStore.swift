import Foundation
import RielaAddons

struct SharedAddonProjectionPlan {
  var addon: WorkflowPackageNodeAddon
  var source: URL
  var destination: URL
  var manifest: WorkflowPackageManifest
}

func sharedAddonStoreRoot(
  environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
) -> URL {
  URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment), isDirectory: true)
    .appendingPathComponent(".riela/addons", isDirectory: true)
}

func sharedAddonStoreDirectory(
  addonName: String,
  version: String,
  environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
) throws -> URL {
  let components = addonName.split(separator: "/").map(String.init)
  guard !components.isEmpty else {
    throw CLIUsageError("add-on name must not be empty")
  }
  var destination = sharedAddonStoreRoot(environment: environment)
  for component in components {
    destination.appendPathComponent(packageFilesystemKey(component), isDirectory: true)
  }
  destination.appendPathComponent(packageFilesystemKey(version), isDirectory: true)
  return destination
}

func sharedAddonProjectionPlans(
  manifest: WorkflowPackageManifest,
  packageRoot: URL,
  environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
) throws -> [SharedAddonProjectionPlan] {
  try manifest.nodeAddons.map { addon in
    guard let normalizedSourcePath = WorkflowPackageManifestValidator.normalizePackageRelativePath(addon.sourcePath) else {
      throw CLIUsageError("addons.\(addon.name).sourcePath: path must be package-relative")
    }
    let source = packageRoot.appendingPathComponent(normalizedSourcePath, isDirectory: true)
    guard FileManager.default.fileExists(atPath: source.path) else {
      throw CLIUsageError("add-on source missing: \(source.path)")
    }
    let sharedAddon = try sharedStoreAddon(addon, packageRoot: packageRoot, addonRoot: source)
    let sharedManifest = WorkflowPackageManifest(
      name: manifest.name,
      version: manifest.version,
      kind: .nodeAddon,
      description: manifest.description,
      tags: manifest.tags,
      registry: manifest.registry,
      nodeAddons: [sharedAddon],
      title: manifest.title,
      authors: manifest.authors,
      license: manifest.license,
      homepage: manifest.homepage,
      repository: manifest.repository,
      minimumRielaVersion: manifest.minimumRielaVersion,
      environmentVariables: manifest.environmentVariables
    )
    return SharedAddonProjectionPlan(
      addon: sharedAddon,
      source: source,
      destination: try sharedAddonStoreDirectory(
        addonName: addon.name,
        version: addon.version,
        environment: environment
      ),
      manifest: sharedManifest
    )
  }
}

func installSharedAddonProjections(
  _ plans: [SharedAddonProjectionPlan],
  overwrite: Bool,
  dryRun: Bool
) async throws -> [URL] {
  var installed: [URL] = []
  for plan in plans {
    if dryRun {
      installed.append(plan.destination)
      continue
    }
    if FileManager.default.fileExists(atPath: plan.destination.path) {
      if try sharedAddonDestinationMatches(plan) {
        installed.append(plan.destination)
        continue
      }
      guard overwrite else {
        throw CLIUsageError("shared add-on store entry already exists with different content: \(plan.destination.path); pass --overwrite to replace it")
      }
      try FileManager.default.removeItem(at: plan.destination)
    }
    try FileManager.default.createDirectory(at: plan.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: plan.source, to: plan.destination)
    let manifestURL = plan.destination.appendingPathComponent(WorkflowPackageArchiveManager.manifestFileName)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(plan.manifest)
    try data.write(to: manifestURL, options: [.atomic])
    installed.append(plan.destination)
  }
  return installed
}

func sharedAddonManifestURLs(
  environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
) throws -> [URL] {
  var manifests: [URL] = []
  for root in sharedAddonStoreRoots(environment: environment) {
    manifests.append(contentsOf: try manifestURLs(inSharedAddonRoot: root))
  }
  return manifests.sorted { $0.path < $1.path }
}

private func sharedAddonStoreRoots(
  environment: [String: String]
) -> [URL] {
  [
    sharedAddonStoreRoot(environment: environment),
    legacySharedAddonStoreRoot(environment: environment)
  ]
}

private func legacySharedAddonStoreRoot(
  environment: [String: String]
) -> URL {
  URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment), isDirectory: true)
    .appendingPathComponent(".riela/content-ad/addons", isDirectory: true)
}

private func manifestURLs(inSharedAddonRoot root: URL) throws -> [URL] {
  guard FileManager.default.fileExists(atPath: root.path) else {
    return []
  }
  guard let enumerator = FileManager.default.enumerator(
    at: root,
    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
    options: [.skipsHiddenFiles]
  ) else {
    return []
  }
  var manifests: [URL] = []
  for case let url as URL in enumerator where url.lastPathComponent == WorkflowPackageArchiveManager.manifestFileName {
    manifests.append(url)
  }
  return manifests
}

private func sharedStoreAddon(
  _ addon: WorkflowPackageNodeAddon,
  packageRoot: URL,
  addonRoot: URL
) throws -> WorkflowPackageNodeAddon {
  WorkflowPackageNodeAddon(
    name: addon.name,
    version: addon.version,
    sourcePath: ".",
    execution: try addon.execution.map {
      try sharedStoreExecution($0, packageRoot: packageRoot, addonRoot: addonRoot)
    },
    capabilities: addon.capabilities,
    contentDigest: addon.contentDigest
  )
}

private func sharedStoreExecution(
  _ execution: WorkflowPackageAddonExecutionDescriptor,
  packageRoot: URL,
  addonRoot: URL
) throws -> WorkflowPackageAddonExecutionDescriptor {
  WorkflowPackageAddonExecutionDescriptor(
    kind: execution.kind,
    entrypoint: execution.entrypoint,
    containerfilePath: try execution.containerfilePath.map {
      try sharedStoreRelativePath($0, label: "containerfilePath", packageRoot: packageRoot, addonRoot: addonRoot)
    },
    image: execution.image,
    imageDigest: execution.imageDigest,
    abiVersion: execution.abiVersion,
    bundleIdentifier: execution.bundleIdentifier,
    codeSignatureRequirement: execution.codeSignatureRequirement,
    runtimeHints: execution.runtimeHints
  )
}

private func sharedStoreRelativePath(
  _ path: String,
  label: String,
  packageRoot: URL,
  addonRoot: URL
) throws -> String {
  guard let normalized = WorkflowPackageManifestValidator.normalizePackageRelativePath(path) else {
    throw CLIUsageError("add-on \(label): path must be package-relative")
  }
  let addonCandidate = addonRoot.appendingPathComponent(normalized)
  if FileManager.default.fileExists(atPath: addonCandidate.path) {
    return packageRelativePath(for: addonCandidate, packageRoot: addonRoot)
  }
  let packageCandidate = packageRoot.appendingPathComponent(normalized)
  guard FileManager.default.fileExists(atPath: packageCandidate.path),
    isURL(packageCandidate.standardizedFileURL, containedIn: addonRoot.standardizedFileURL)
  else {
    throw CLIUsageError("add-on \(label) must resolve inside sourcePath for shared store projection: \(path)")
  }
  return packageRelativePath(for: packageCandidate, packageRoot: addonRoot)
}

private func sharedAddonDestinationMatches(_ plan: SharedAddonProjectionPlan) throws -> Bool {
  let manifestURL = plan.destination.appendingPathComponent(WorkflowPackageArchiveManager.manifestFileName)
  guard FileManager.default.fileExists(atPath: manifestURL.path) else {
    return false
  }
  let existing = try JSONDecoder().decode(WorkflowPackageManifest.self, from: Data(contentsOf: manifestURL))
  guard let existingAddon = existing.nodeAddons.first, existing.nodeAddons.count == 1 else {
    return false
  }
  return existing.name == plan.manifest.name
    && existing.version == plan.manifest.version
    && existingAddon.name == plan.addon.name
    && existingAddon.version == plan.addon.version
    && existingAddon.contentDigest == plan.addon.contentDigest
}
