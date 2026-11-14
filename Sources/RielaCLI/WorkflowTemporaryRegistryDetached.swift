import Foundation
import RielaCore

extension WorkflowTemporaryRegistry {
  func loadBundle(
    workflowId: String,
    pinned: WorkflowTemporaryRegistryPinnedRoot,
    resolver: FileSystemWorkflowBundleResolver,
    scope: WorkflowScope
  ) throws -> ResolvedWorkflowBundle {
    try withDetachedRegistrySnapshot(pinned: pinned) { snapshotRoot in
      try hooks.beforeDetachedBundleLoad()
      let snapshotDirectory = snapshotRoot.appendingPathComponent(workflowId, isDirectory: true)
      var bundle = try resolver.loadBundle(
        at: snapshotDirectory,
        rootDirectory: snapshotRoot,
        scope: scope,
        temporary: true,
        expectedWorkflowId: workflowId
      )
      bundle = rebase(bundle, from: snapshotDirectory, to: root.appendingPathComponent(workflowId))
      return bundle
    }
  }

  private func rebase(
    _ source: ResolvedWorkflowBundle,
    from snapshotDirectory: URL,
    to configuredDirectory: URL
  ) -> ResolvedWorkflowBundle {
    var bundle = source
    bundle.workflowDirectory = configuredDirectory.path
    bundle.nodePayloads = bundle.nodePayloads.mapValues { payload in
      var payload = payload
      if var command = payload.command {
        command.executable = rebase(command.executable, from: snapshotDirectory, to: configuredDirectory)
        if let workingDirectory = command.workingDirectory {
          command.workingDirectory = rebase(workingDirectory, from: snapshotDirectory, to: configuredDirectory)
        }
        payload.command = command
      }
      if var container = payload.container, let workingDirectory = container.workingDirectory {
        container.workingDirectory = rebase(workingDirectory, from: snapshotDirectory, to: configuredDirectory)
        payload.container = container
      }
      return payload
    }
    return bundle
  }

  private func rebase(_ path: String, from source: URL, to destination: URL) -> String {
    let prefix = source.standardizedFileURL.path + "/"
    guard path.hasPrefix(prefix) else { return path }
    return destination.appendingPathComponent(String(path.dropFirst(prefix.count))).path
  }

  func withDetachedRegistrySnapshot<T>(
    pinned: WorkflowTemporaryRegistryPinnedRoot,
    _ body: (URL) throws -> T
  ) throws -> T {
    try withDetachedSnapshot(of: root, excludingState: true, pinned: pinned, body)
  }

  func withDetachedSnapshot<T>(
    of source: URL,
    excludingState: Bool = false,
    pinned: WorkflowTemporaryRegistryPinnedRoot,
    _ body: (URL) throws -> T
  ) throws -> T {
    let snapshot = try WorkflowDetachedOwnershipRoot.create()
    let detachedRoot = try WorkflowDetachedOwnershipPinnedRoot(candidate: snapshot, requireRoot: true)
    let transactionMarkerName = WorkflowTransactionStableMetadata.url(forOwnershipRoot: snapshot).lastPathComponent
    defer {
      let recordExists = (try? detachedRoot.entryExists(transactionMarkerName)) == true
      let sidecarExists = (try? detachedRoot.entryExists(transactionMarkerName + ".sha256")) == true
      if !recordExists, !sidecarExists {
        try? detachedRoot.destroyContainer()
      }
    }
    let entries = try pinned.bundleInventory(in: source).filter { entry in
      !excludingState
        || (entry.relativePath != Self.reservedStateName
          && !entry.relativePath.hasPrefix(Self.reservedStateName + "/"))
    }
    try detachedRoot.populateRoot(with: entries)
    try detachedRoot.requireConfiguredPathIdentity()
    return try body(try detachedRoot.stableDirectoryURL("root"))
  }
}
