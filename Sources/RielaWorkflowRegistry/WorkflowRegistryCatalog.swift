import Foundation
import RielaAddons
import RielaCore

struct WorkflowRegistryCatalog {
  var registry: WorkflowMutableRegistry

  func list(
    filter: WorkflowRegistryFilter,
    workingDirectory: String
  ) throws -> [WorkflowCatalogEntry] {
    try filter.validate()
    let scope = WorkflowScope(rawValue: filter.scope?.rawValue ?? WorkflowScope.auto.rawValue) ?? .auto
    var entries = try authoredEntries(scope: scope, workingDirectory: workingDirectory)
    entries.append(contentsOf: try packageEntries(scope: scope, workingDirectory: workingDirectory))
    if scope != .project {
      entries.append(contentsOf: try mutableEntries())
    }
    entries = try entries.map(applyingActivation)
    return entries.filter { entry in
      if let query = filter.query?.lowercased(), !query.isEmpty,
         !entry.workflowName.lowercased().contains(query),
         !entry.workflowId.lowercased().contains(query),
         !(entry.description?.lowercased().contains(query) ?? false) {
        return false
      }
      if let description = filter.description?.lowercased(), !description.isEmpty,
         !(entry.description?.lowercased().contains(description) ?? false) {
        return false
      }
      if let sourceKind = filter.sourceKind, sourceKind.rawValue != entry.sourceKind.rawValue {
        return false
      }
      if let provenance = filter.provenance, provenance != entry.provenance {
        return false
      }
      if let mutable = filter.mutable, mutable != entry.mutable {
        return false
      }
      if let activationState = filter.activationState, activationState != entry.activationState {
        return false
      }
      return true
    }.sorted(by: catalogOrder)
  }

  func originIdentities(workingDirectory: String) throws -> [WorkflowOriginIdentity] {
    try list(filter: WorkflowRegistryFilter(), workingDirectory: workingDirectory).map {
      workflowOriginIdentity(
        name: $0.workflowName,
        workflowId: $0.workflowId,
        scope: $0.scope,
        sourceKind: $0.sourceKind,
        provenance: $0.provenance,
        locator: $0.workflowDirectory
      )
    }
  }

  private func authoredEntries(
    scope: WorkflowScope,
    workingDirectory: String
  ) throws -> [WorkflowCatalogEntry] {
    var entries: [WorkflowCatalogEntry] = []
    for (sourceScope, root) in workflowRoots(scope: scope, workingDirectory: workingDirectory) {
      for name in try directoryNames(in: root) {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        do {
          let bundle = try WorkflowRegistryBundleLoader().loadBundle(
            at: directory,
            rootDirectory: root,
            scope: sourceScope
          )
          entries.append(entry(name: name, bundle: bundle))
        } catch {
          entries.append(invalidEntry(
            name: name,
            scope: sourceScope,
            sourceKind: .workflow,
            directory: directory,
            error: error
          ))
        }
      }
    }
    return entries
  }

  private func mutableEntries() throws -> [WorkflowCatalogEntry] {
    try registry.snapshotCandidates().map { candidate in
      let workflowId = candidate.lastPathComponent
      do {
        return try registry.withWorkflowRead(workflowId: workflowId) { snapshot in
          let bundle = try WorkflowRegistryBundleLoader().loadBundle(
            at: snapshot,
            rootDirectory: snapshot.deletingLastPathComponent(),
            scope: .user,
            provenance: .mutable,
            expectedWorkflowId: workflowId
          )
          var entry = entry(name: workflowId, bundle: bundle)
          entry.workflowDirectory = candidate.path
          entry.originId = workflowOriginIdentity(
            name: workflowId,
            workflowId: entry.workflowId,
            scope: .user,
            sourceKind: .workflow,
            provenance: .mutable,
            locator: candidate.path
          ).originId
          return entry
        }
      } catch {
        return invalidEntry(
          name: workflowId,
          scope: .user,
          sourceKind: .workflow,
          directory: candidate,
          provenance: .mutable,
          error: error
        )
      }
    }
  }

  private func packageEntries(
    scope: WorkflowScope,
    workingDirectory: String
  ) throws -> [WorkflowCatalogEntry] {
    var entries: [WorkflowCatalogEntry] = []
    for (sourceScope, root) in packageRoots(scope: scope, workingDirectory: workingDirectory) {
      for manifestURL in try packageManifestURLs(in: root) {
        let packageDirectory = manifestURL.deletingLastPathComponent().standardizedFileURL
        do {
          let manifest = try JSONDecoder().decode(
            WorkflowPackageManifest.self,
            from: Data(contentsOf: manifestURL)
          )
          guard manifest.kind == .workflow else { continue }
          let normalized = WorkflowPackageManifestValidator.normalizePackageRelativePath(
            manifest.workflowDirectory ?? "."
          )
          let workflowDirectory = normalized.map {
            packageDirectory.appendingPathComponent($0, isDirectory: true).standardizedFileURL
          } ?? packageDirectory
          let issues = WorkflowPackageManifestValidator.validate(manifest)
            + WorkflowPackageManifestValidator.validateWorkflowBundle(
              manifest,
              packageRoot: packageDirectory
            )
          let validation = validateAuthoredWorkflowData(
            try Data(contentsOf: workflowDirectory.appendingPathComponent("workflow.json"))
          )
          let diagnostics = issues.map {
            WorkflowValidationDiagnostic(severity: .error, path: $0.path, message: $0.message)
          } + validation.diagnostics
          entries.append(WorkflowCatalogEntry(
            workflowName: manifest.name,
            workflowId: validation.workflow?.workflowId,
            description: validation.workflow?.description,
            scope: sourceScope,
            sourceKind: .package,
            workflowDirectory: workflowDirectory.path,
            packageName: manifest.name,
            packageVersion: manifest.version,
            packageDirectory: packageDirectory.path,
            provenance: .immutable,
            valid: !diagnostics.contains { $0.severity == .error },
            diagnostics: diagnostics
          ))
        } catch {
          entries.append(invalidEntry(
            name: relativeName(packageDirectory, root: root),
            scope: sourceScope,
            sourceKind: .package,
            directory: packageDirectory,
            packageDirectory: packageDirectory.path,
            error: error
          ))
        }
      }
    }
    return entries
  }

  private func entry(name: String, bundle: ResolvedWorkflowBundle) -> WorkflowCatalogEntry {
    let diagnostics = bundle.diagnostics
      + DefaultWorkflowValidator().validate(bundle.workflow, nodePayloads: bundle.nodePayloads)
    return WorkflowCatalogEntry(
      workflowName: name,
      workflowId: bundle.workflow.workflowId,
      description: bundle.workflow.description,
      scope: bundle.sourceScope,
      sourceKind: bundle.packageManifest == nil ? .workflow : .package,
      workflowDirectory: bundle.workflowDirectory,
      packageName: bundle.packageManifest?.name,
      packageVersion: bundle.packageManifest?.version,
      packageDirectory: bundle.packageDirectory,
      provenance: bundle.provenance,
      valid: !diagnostics.contains { $0.severity == .error },
      diagnostics: diagnostics
    )
  }

  private func invalidEntry(
    name: String,
    scope: WorkflowScope,
    sourceKind: WorkflowSourceKind,
    directory: URL,
    packageDirectory: String? = nil,
    provenance: WorkflowProvenance = .immutable,
    error: Error
  ) -> WorkflowCatalogEntry {
    WorkflowCatalogEntry(
      workflowName: name,
      scope: scope,
      sourceKind: sourceKind,
      workflowDirectory: directory.path,
      packageDirectory: packageDirectory,
      provenance: provenance,
      valid: false,
      diagnostics: [
        WorkflowValidationDiagnostic(
          severity: .error,
          path: sourceKind == .package ? "riela-package.json" : "workflow.json",
          message: "\(error)"
        )
      ]
    )
  }

  private func applyingActivation(_ entry: WorkflowCatalogEntry) throws -> WorkflowCatalogEntry {
    var result = entry
    let origin = workflowOriginIdentity(
      name: entry.workflowName,
      workflowId: entry.workflowId,
      scope: entry.scope,
      sourceKind: entry.sourceKind,
      provenance: entry.provenance,
      locator: entry.workflowDirectory
    )
    result.originId = origin.originId
    result.activationState = try WorkflowActivationStore().state(for: origin)
    return result
  }

  private func workflowRoots(
    scope: WorkflowScope,
    workingDirectory: String
  ) -> [(WorkflowScope, URL)] {
    scopedRoots(
      scope: scope,
      project: URL(fileURLWithPath: workingDirectory).appendingPathComponent(".riela/workflows"),
      user: URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory()).appendingPathComponent(".riela/workflows")
    )
  }

  private func packageRoots(
    scope: WorkflowScope,
    workingDirectory: String
  ) -> [(WorkflowScope, URL)] {
    scopedRoots(
      scope: scope,
      project: URL(fileURLWithPath: workingDirectory).appendingPathComponent(".riela/packages"),
      user: URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory()).appendingPathComponent(".riela/packages")
    )
  }

  private func scopedRoots(
    scope: WorkflowScope,
    project: URL,
    user: URL
  ) -> [(WorkflowScope, URL)] {
    switch scope {
    case .project: [(.project, project)]
    case .user: [(.user, user)]
    case .auto, .direct: [(.project, project), (.user, user)]
    }
  }

  private func directoryNames(in root: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey]
    ).compactMap { url in
      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        ? url.lastPathComponent
        : nil
    }.sorted()
  }

  private func packageManifestURLs(in root: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }
    var urls: [URL] = []
    for case let url as URL in enumerator where url.lastPathComponent == "riela-package.json" {
      urls.append(url)
      enumerator.skipDescendants()
    }
    return urls.sorted { $0.path < $1.path }
  }

  private func relativeName(_ directory: URL, root: URL) -> String {
    let path = directory.standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    return path.hasPrefix(rootPath + "/")
      ? String(path.dropFirst(rootPath.count + 1))
      : directory.lastPathComponent
  }

  private func catalogOrder(_ left: WorkflowCatalogEntry, _ right: WorkflowCatalogEntry) -> Bool {
    if left.scope.rawValue != right.scope.rawValue {
      return left.scope.rawValue < right.scope.rawValue
    }
    if left.workflowName != right.workflowName {
      return left.workflowName < right.workflowName
    }
    return left.sourceKind.rawValue < right.sourceKind.rawValue
  }
}
