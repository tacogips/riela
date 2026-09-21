import Foundation
import RielaAddons
import RielaCore

public typealias WorkflowInheritanceBaseResolver = @Sendable (
  _ workflowId: String,
  _ ancestry: [String]
) throws -> ResolvedWorkflowBundle

extension WorkflowRegistryBundleLoader {
  func loadInheritedBundle(
    declaration: WorkflowInheritanceDeclaration,
    directory: URL,
    scope: WorkflowScope,
    providedPackageManifest: WorkflowPackageManifest?,
    packageDirectory: URL?,
    provenance: WorkflowProvenance,
    expectedWorkflowId: String?,
    ancestry: [String],
    baseResolver: WorkflowInheritanceBaseResolver
  ) throws -> ResolvedWorkflowBundle {
    if let expectedWorkflowId, declaration.derivedWorkflowId != expectedWorkflowId {
      throw CLIUsageError(
        "mutable workflow registry key '\(expectedWorkflowId)' does not match decoded workflowId '\(declaration.derivedWorkflowId)'"
      )
    }
    let canonical = directory.resolvingSymlinksInPath().standardizedFileURL.path
    let marker = "\(declaration.derivedWorkflowId)@\(canonical)"
    if let cycleStart = ancestry.firstIndex(where: { $0 == marker || $0.hasPrefix("\(declaration.derivedWorkflowId)@") }) {
      let ids = ancestry[cycleStart...].map { String($0.split(separator: "@", maxSplits: 1)[0]) }
        + [declaration.derivedWorkflowId]
      throw WorkflowInheritanceError.cycle(ids)
    }
    let nextAncestry = ancestry + [marker]
    let base = try baseResolver(declaration.baseWorkflowId, nextAncestry)
    let transformed = try WorkflowInheritanceTransformation().apply(
      declaration,
      to: base.workflow,
      nodePayloads: base.nodePayloads
    )
    let manifest: WorkflowPackageManifest?
    let resolvedPackageDirectory: String?
    if provenance == .mutable {
      manifest = nil
      resolvedPackageDirectory = nil
    } else {
      manifest = try providedPackageManifest ?? packageManifestIfPresent(at: directory)
      resolvedPackageDirectory = packageDirectory?.path ?? (manifest == nil ? nil : directory.path)
    }
    return ResolvedWorkflowBundle(
      workflow: transformed.workflow,
      nodePayloads: transformed.nodePayloads,
      sourceScope: scope,
      workflowDirectory: directory.path,
      diagnostics: transformed.diagnostics,
      packageManifest: manifest,
      packageDirectory: resolvedPackageDirectory,
      provenance: provenance
    )
  }

  private func packageManifestIfPresent(at directory: URL) throws -> WorkflowPackageManifest? {
    let manifestURL = directory.appendingPathComponent("riela-package.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
    return try JSONDecoder().decode(WorkflowPackageManifest.self, from: Data(contentsOf: manifestURL))
  }
}
