import Foundation
import RielaAddons
import RielaCore
import RielaWorkflowRegistry

struct VerifiedInstalledAddon {
  let dependency: WorkflowPackageDependency
  let lock: WorkflowPackageManifestAddonDependencyLock
  let sourceScope: WorkflowScope
}

private struct InstalledDependencyRoot {
  let scope: WorkflowScope
  let packages: URL
  let lockfile: URL
}

func verifiedInstalledAddon(
  _ reference: WorkflowNodeAddonRef,
  in bundle: ResolvedWorkflowBundle,
  workingDirectory: String
) -> VerifiedInstalledAddon? {
  guard let owner = bundle.packageManifest,
    let ownerDirectory = bundle.packageDirectory else { return nil }
  let matches = owner.dependencies.flatMap { dependency in
    dependency.addons.compactMap { lock -> VerifiedInstalledAddon? in
      guard reference.name == lock.name || reference.name == "\(dependency.packageId)/\(lock.name)",
        reference.version == nil || reference.version == lock.version,
        dependency.kind == .nodeAddon,
        lock.executionKind == .nativeBundle || lock.executionKind == .container || lock.executionKind == .declarative
      else { return nil }
      return VerifiedInstalledAddon(dependency: dependency, lock: lock, sourceScope: bundle.sourceScope)
    }
  }
  guard matches.count == 1, let match = matches.first else { return nil }

  let project = URL(fileURLWithPath: workingDirectory, isDirectory: true)
  let home = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(), isDirectory: true)
  let projectRoot = project.appendingPathComponent(".riela/packages", isDirectory: true)
  let userRoot = home.appendingPathComponent(".riela/packages", isDirectory: true)
  let ownerURL = URL(fileURLWithPath: ownerDirectory, isDirectory: true).standardizedFileURL
  let roots: [InstalledDependencyRoot] = [
    InstalledDependencyRoot(scope: .project, packages: projectRoot,
      lockfile: project.appendingPathComponent("riela-lock.json")),
    InstalledDependencyRoot(scope: .user, packages: userRoot,
      lockfile: home.appendingPathComponent(".riela/riela-lock.json"))
  ]
  guard let selectedRoot = roots.first(where: { root in
    let canonicalRoot = root.packages.resolvingSymlinksInPath().standardizedFileURL.path
    let canonicalOwner = ownerURL.resolvingSymlinksInPath().standardizedFileURL.path
    return canonicalOwner.hasPrefix(canonicalRoot + "/")
      && (bundle.sourceScope == .direct || bundle.sourceScope == .auto || bundle.sourceScope == root.scope)
  }) else { return nil }
  guard owner.kind == .workflow,
    selectedRoot.packages.appendingPathComponent(owner.name, isDirectory: true)
      .standardizedFileURL == ownerURL,
    let ownerWorkflowPath = WorkflowPackageManifestValidator.normalizePackageRelativePath(
      owner.workflowDirectory ?? "."
    ),
    ownerURL.appendingPathComponent(ownerWorkflowPath, isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL.path == bundle.workflowDirectory,
    let ownerData = try? Data(contentsOf: ownerURL.appendingPathComponent("riela-package.json")),
    let installedOwner = try? JSONDecoder().decode(WorkflowPackageManifest.self, from: ownerData),
    installedOwner == owner,
    WorkflowPackageManifestValidator.validatePackageSource(
      owner, packageRoot: ownerURL, verifiesChecksum: true
    ).isEmpty
  else { return nil }
  guard match.lock.sourceScope == nil || match.lock.sourceScope == selectedRoot.scope.rawValue else { return nil }

  let dependencyURL = selectedRoot.packages.appendingPathComponent(match.dependency.packageId, isDirectory: true)
    .standardizedFileURL
  guard dependencyURL.resolvingSymlinksInPath().standardizedFileURL.path
    .hasPrefix(selectedRoot.packages.resolvingSymlinksInPath().standardizedFileURL.path + "/"),
    let manifestData = try? Data(contentsOf: dependencyURL.appendingPathComponent("riela-package.json")),
    let installed = try? JSONDecoder().decode(WorkflowPackageManifest.self, from: manifestData),
    installed.name == match.dependency.packageId,
    installed.kind == .nodeAddon,
    WorkflowPackageManifestValidator.validatePackageSource(
      installed, packageRoot: dependencyURL, verifiesChecksum: true
    ).isEmpty,
    let packageLock = try? readWorkflowPackageLock(at: selectedRoot.lockfile),
    let lockedPackage = packageLock.packages[match.dependency.packageId],
    lockedPackage.name == installed.name,
    lockedPackage.kind == installed.kind,
    lockedPackage.version == installed.version,
    lockedPackage.registry == installed.registry,
    match.dependency.registry == nil || match.dependency.registry == installed.registry,
    lockedPackage.checksum == installed.checksum,
    lockedPackage.checksumAlgorithm == installed.checksumAlgorithm,
    lockedPackage.integrity == installed.integrity
  else { return nil }
  let addons = installed.nodeAddons.filter { addon in
    addon.name == match.lock.name
      && addon.version == match.lock.version
      && addon.contentDigest == match.lock.contentDigest
      && addon.execution?.kind == match.lock.executionKind
  }
  guard addons.count == 1, let addon = addons.first else { return nil }
  let lockedAddons = lockedPackage.addons.filter { summary in
    summary.name == addon.name && summary.version == addon.version
      && summary.contentDigest == addon.contentDigest
      && summary.executionKind == addon.execution?.kind
      && summary.sourcePath == addon.sourcePath
  }
  guard lockedAddons.count == 1 else { return nil }
  if match.lock.executionKind == .nativeBundle {
    guard addon.execution?.abiVersion == match.lock.abiVersion,
      addon.execution?.bundleIdentifier == match.lock.bundleIdentifier,
      let entrypoint = addon.execution?.entrypoint,
      FileManager.default.fileExists(atPath: dependencyURL
        .appendingPathComponent(addon.sourcePath, isDirectory: true)
        .appendingPathComponent(entrypoint).path)
    else { return nil }
  }
  return VerifiedInstalledAddon(
    dependency: match.dependency, lock: match.lock, sourceScope: selectedRoot.scope
  )
}

// Executable preflight receives the decoded workflow and manifest, before a
// resolved bundle is available. Preserve its independent readiness inspection.
func nativeBundleAddonInspections(
  workflow: WorkflowDefinition,
  packageManifest: WorkflowPackageManifest?,
  sourceScope: WorkflowScope
) -> [NativeBundleAddonInspection] {
  guard let packageManifest else { return [] }
  let nativeLocks = packageManifest.dependencies.flatMap { dependency in
    dependency.addons.compactMap { lock -> VerifiedInstalledAddon? in
      lock.executionKind == .nativeBundle
        ? VerifiedInstalledAddon(dependency: dependency, lock: lock, sourceScope: sourceScope) : nil
    }
  }
  return workflow.nodeRegistry.compactMap { node in
    guard let addon = node.addon else { return nil }
    let matches = nativeLocks.filter { match in
      (addon.name == match.lock.name || addon.name == "\(match.dependency.packageId)/\(match.lock.name)")
        && (addon.version == nil || addon.version == match.lock.version)
    }
    guard matches.count == 1, let match = matches.first else { return nil }
    let lock = match.lock
    return NativeBundleAddonInspection(
      nodeId: node.id,
      addon: addon.name,
      sourceKind: WorkflowPackageAddonExecutionKind.nativeBundle.rawValue,
      sourceScope: lock.sourceScope ?? sourceScope.rawValue,
      packageName: match.dependency.packageId,
      bundleIdentifier: lock.bundleIdentifier ?? "",
      abiVersion: lock.abiVersion ?? 0,
      contentDigest: lock.contentDigest ?? "",
      dependencyClosureDigest: lock.dependencyClosureDigest ?? "",
      signingRequired: lock.codeSignatureRequirementDigest != nil,
      signingVerified: nil,
      cacheStatus: "not_loaded",
      preflightHelperStatus: nil
    )
  }
}
