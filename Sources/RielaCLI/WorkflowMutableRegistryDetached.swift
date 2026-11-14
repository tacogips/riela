import Foundation
import RielaCore

extension WorkflowMutableRegistry {
  func loadCandidateBundle(
    at candidate: URL,
    expectedWorkflowId: String? = nil,
    pinned: WorkflowMutableRegistryPinnedRoot,
    resolver: FileSystemWorkflowBundleResolver = FileSystemWorkflowBundleResolver()
  ) throws -> (bundle: ResolvedWorkflowBundle, registryDigest: String) {
    try pinned.requireConfiguredPathIdentity()
    let candidateEntries = try pinned.bundleInventory(in: candidate)
    let workflowId = try candidateWorkflowId(in: candidateEntries)
    if let expectedWorkflowId, expectedWorkflowId != workflowId {
      throw CLIUsageError(
        "mutable workflow registry key '\(expectedWorkflowId)' "
          + "does not match decoded workflowId '\(workflowId)'"
      )
    }

    let targetPrefix = workflowId + "/"
    var entries = try pinned.bundleInventory(in: root).filter { entry in
      entry.relativePath != Self.reservedStateName
        && !entry.relativePath.hasPrefix(Self.reservedStateName + "/")
        && entry.relativePath != workflowId
        && !entry.relativePath.hasPrefix(targetPrefix)
    }
    entries.append(WorkflowMutableRegistryInventoryEntry(
      relativePath: workflowId,
      bytes: nil,
      mode: 0o700
    ))
    entries.append(contentsOf: candidateEntries.map { entry in
      WorkflowMutableRegistryInventoryEntry(
        relativePath: targetPrefix + entry.relativePath,
        bytes: entry.bytes,
        mode: entry.mode
      )
    })
    entries.sort { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }

    let loaded = try withDetachedInventorySnapshot(entries: entries) { snapshotRoot in
      try hooks.beforeDetachedBundleLoad()
      return try resolver.loadBundle(
        at: snapshotRoot.appendingPathComponent(workflowId, isDirectory: true),
        rootDirectory: snapshotRoot,
        scope: .user,
        provenance: .mutable,
        expectedWorkflowId: workflowId
      )
    }
    try pinned.requireConfiguredPathIdentity()
    return (loaded, registryDigest(for: candidateEntries))
  }

  func candidateWorkflowId(
    at candidate: URL,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws -> String {
    try candidateWorkflowId(in: pinned.bundleInventory(in: candidate))
  }

  private func candidateWorkflowId(
    in entries: [WorkflowMutableRegistryInventoryEntry]
  ) throws -> String {
    guard let declaration = entries.first(where: {
      $0.relativePath == "workflow.json"
    })?.bytes else {
      throw CLIUsageError("mutable workflow candidate is missing workflow.json")
    }
    let validation = validateAuthoredWorkflowData(declaration)
    guard let workflow = validation.workflow else {
      throw WorkflowResolutionError.invalidWorkflow(validation.diagnostics)
    }
    try validateWorkflowId(workflow.workflowId)
    return workflow.workflowId
  }

  private func registryDigest(
    for entries: [WorkflowMutableRegistryInventoryEntry]
  ) -> String {
    let records = entries.map { entry in
      if let bytes = entry.bytes {
        return "file\t\(entry.relativePath)\t\(WorkflowHistoryCanonicalCoding.sha256(bytes))"
      }
      return "directory\t\(entry.relativePath)"
    }.sorted()
    return WorkflowHistoryCanonicalCoding.sha256(Data(records.joined(separator: "\n").utf8))
  }

  func loadBundle(
    workflowId: String,
    pinned: WorkflowMutableRegistryPinnedRoot,
    resolver: FileSystemWorkflowBundleResolver,
    scope: WorkflowScope,
    sharedNodeActivationPolicy: WorkflowSharedNodeActivationPolicy = .includeDeactivated
  ) throws -> ResolvedWorkflowBundle {
    try withDetachedRegistrySnapshot(pinned: pinned) { snapshotRoot in
      try hooks.beforeDetachedBundleLoad()
      let snapshotDirectory = snapshotRoot.appendingPathComponent(workflowId, isDirectory: true)
      var bundle = try resolver.loadBundle(
        at: snapshotDirectory,
        rootDirectory: snapshotRoot,
        scope: scope,
        provenance: .mutable,
        expectedWorkflowId: workflowId,
        sharedNodeActivationPolicy: sharedNodeActivationPolicy,
        sharedNodeActivationRootDirectory: root
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
    pinned: WorkflowMutableRegistryPinnedRoot,
    _ body: (URL) throws -> T
  ) throws -> T {
    try withDetachedSnapshot(of: root, excludingState: true, pinned: pinned, body)
  }

  private func withDetachedInventorySnapshot<T>(
    entries: [WorkflowMutableRegistryInventoryEntry],
    _ body: (URL) throws -> T
  ) throws -> T {
    let snapshot = try WorkflowDetachedOwnershipRoot.create()
    let detachedRoot = try WorkflowDetachedOwnershipPinnedRoot(candidate: snapshot, requireRoot: true)
    defer { try? detachedRoot.destroyContainer() }
    try detachedRoot.populateRoot(with: entries)
    try detachedRoot.requireConfiguredPathIdentity()
    return try body(try detachedRoot.stableDirectoryURL("root"))
  }

  func withDetachedSnapshot<T>(
    of source: URL,
    excludingState: Bool = false,
    pinned: WorkflowMutableRegistryPinnedRoot,
    _ body: (URL) throws -> T
  ) throws -> T {
    let snapshot = try WorkflowDetachedOwnershipRoot.create()
    let detachedRoot = try WorkflowDetachedOwnershipPinnedRoot(candidate: snapshot, requireRoot: true)
    let transactionMarkerName = WorkflowTransactionStableMetadata.url(forOwnershipRoot: snapshot).lastPathComponent
    var preserveForInjectedRecovery = false
    defer {
      let recordExists = (try? detachedRoot.entryExists(transactionMarkerName)) == true
      let sidecarExists = (try? detachedRoot.entryExists(transactionMarkerName + ".sha256")) == true
      if !recordExists, !sidecarExists, !preserveForInjectedRecovery {
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
    do {
      return try body(try detachedRoot.stableDirectoryURL("root"))
    } catch {
      // An injected interruption models process death. Preserve the detached
      // tree even if the interruption precedes stable-marker publication so
      // the next public resolution exercises the same recovery state.
      preserveForInjectedRecovery = error is WorkflowDirectoryInjectedInterruption
      throw error
    }
  }
}
