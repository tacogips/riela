import Foundation
import RielaCore

extension WorkflowMutableRegistry {
  func catalogOriginIdentities() throws -> [WorkflowOriginIdentity] {
    guard let pinned = try existingPinnedRoot() else { return [] }
    try validateExistingLayout(pinned: pinned)
    return try withCatalogLock(pinned: pinned, createIfMissing: false) {
      try recoverAllLocked(pinned: pinned)
      return try pinned.names(in: root)
        .filter { $0 != Self.reservedStateName }
        .compactMap { workflowId in
          try validateWorkflowId(workflowId)
          let directory = root.appendingPathComponent(workflowId, isDirectory: true)
          guard try realDirectoryExists(
            directory,
            under: root,
            label: "mutable workflow destination",
            pinned: pinned
          ),
          let data = try pinned.readRegularIfPresent(directory.appendingPathComponent("workflow.json")),
          let workflow = validateAuthoredWorkflowData(data).workflow,
          workflow.workflowId == workflowId else {
            return nil
          }
          return workflowOriginIdentity(
            name: workflowId,
            workflowId: workflow.workflowId,
            scope: .user,
            sourceKind: .workflow,
            provenance: .mutable,
            locator: directory.path
          )
        }
    }
  }

  func snapshotCandidates() throws -> [URL] {
    guard let pinned = try existingPinnedRoot() else { return [] }
    try validateExistingLayout(pinned: pinned)
    return try withCatalogLock(pinned: pinned, createIfMissing: false) {
      try recoverAllLocked(pinned: pinned)
      return try pinned.names(in: root)
        .filter { $0 != Self.reservedStateName }
        .map { root.appendingPathComponent($0, isDirectory: true) }
    }
  }

  func withWorkflowRead<T>(workflowId: String, _ body: (URL) throws -> T) throws -> T {
    try validateWorkflowId(workflowId)
    guard let pinned = try existingPinnedRoot() else {
      throw CLIUsageError("mutable workflow registry is not initialized")
    }
    try validateExistingLayout(pinned: pinned)
    return try withWorkflowLock(pinned: pinned, workflowId: workflowId, createIfMissing: true) {
      try withDetachedRegistrySnapshot(pinned: pinned) { snapshotRoot in
        try hooks.beforeDetachedBundleLoad()
        return try body(snapshotRoot.appendingPathComponent(workflowId, isDirectory: true))
      }
    }
  }

  func withWorkflowAccess<T>(workflowId: String, _ body: () throws -> T) throws -> T {
    try withWorkflowPinnedAccess(workflowId: workflowId) { _ in try body() }
  }

  func withWorkflowPinnedAccess<T>(
    workflowId: String,
    _ body: (WorkflowMutableRegistryPinnedRoot?) throws -> T
  ) throws -> T {
    try validateWorkflowId(workflowId)
    guard let pinned = try existingPinnedRoot() else { return try body(nil) }
    try validateExistingLayout(pinned: pinned)
    return try withCatalogLock(pinned: pinned, createIfMissing: false) {
      let destination = root.appendingPathComponent(workflowId, isDirectory: true)
      let transaction = transactionsRoot.appendingPathComponent("\(workflowId).json")
      guard try registryItemExists(destination, pinned: pinned)
        || registryItemExists(transaction, pinned: pinned) else {
        return try body(pinned)
      }
      return try withWorkflowLock(pinned: pinned, workflowId: workflowId, createIfMissing: true) {
        try recoverLocked(pinned: pinned, workflowId: workflowId)
        return try body(pinned)
      }
    }
  }

  func withWorkflowMutationAccess<T>(
    workflowId: String,
    expectedDigest: String,
    shouldPublish: (T) -> Bool = { _ in true },
    _ body: (URL, (URL) throws -> Void) throws -> T
  ) throws -> T {
    try validateWorkflowId(workflowId)
    guard let pinned = try existingPinnedRoot() else {
      throw CLIUsageError("mutable workflow registry is not initialized")
    }
    try validateExistingLayout(pinned: pinned)
    return try withCatalogLock(pinned: pinned, createIfMissing: false) {
      try withWorkflowLock(pinned: pinned, workflowId: workflowId, createIfMissing: true) {
        try recoverLocked(pinned: pinned, workflowId: workflowId)
        let destination = root.appendingPathComponent(workflowId, isDirectory: true)
        guard try realDirectoryExists(
          destination,
          under: root,
          label: "mutable workflow destination",
          pinned: pinned
        ) else {
          throw CLIUsageError("mutable workflow '\(workflowId)' disappeared before mutation")
        }
        guard try bundleDigest(at: destination, pinned: pinned) == expectedDigest else {
          throw CLIUsageError("mutable workflow '\(workflowId)' changed before mutation; resolve it again")
        }
        let result = try withDetachedSnapshot(of: destination, pinned: pinned) { workspace in
          try hooks.afterMutationWorkspaceExport()
          try pinned.requireConfiguredPathIdentity()
          var published = false
          let result = try body(workspace) { preparedWorkflow in
            try replaceLocked(workflowId: workflowId, input: preparedWorkflow, pinned: pinned)
            published = true
          }
          if shouldPublish(result), !published {
            throw CLIUsageError("mutable workflow mutation completed without registry publication")
          }
          return result
        }
        try pinned.requireConfiguredPathIdentity()
        return result
      }
    }
  }

  func withCoordinatorCatalogLock<T>(_ body: () throws -> T) throws -> T {
    if Thread.current.threadDictionary[Self.coordinatorCatalogKey] as? Bool == true {
      return try body()
    }
    let pinned = try pinnedRoot(create: true)
    try ensureLayout(pinned: pinned)
    return try withCatalogLock(pinned: pinned, createIfMissing: false) {
      Thread.current.threadDictionary[Self.coordinatorCatalogKey] = true
      defer { Thread.current.threadDictionary.removeObject(forKey: Self.coordinatorCatalogKey) }
      return try body()
    }
  }

  func withCoordinatorCatalogReadLock<T>(_ body: () throws -> T) throws -> T {
    if Thread.current.threadDictionary[Self.coordinatorCatalogKey] as? Bool == true {
      return try body()
    }
    let pinned: WorkflowMutableRegistryPinnedRoot
    if let existing = try existingPinnedRoot() {
      try validateExistingLayout(pinned: existing)
      pinned = existing
    } else {
      let rielaRoot = root.deletingLastPathComponent()
      let writableParent = FileManager.default.fileExists(atPath: rielaRoot.path)
        ? rielaRoot
        : rielaRoot.deletingLastPathComponent()
      guard FileManager.default.isWritableFile(atPath: writableParent.path) else {
        Thread.current.threadDictionary[Self.coordinatorCatalogKey] = true
        defer { Thread.current.threadDictionary.removeObject(forKey: Self.coordinatorCatalogKey) }
        return try body()
      }
      pinned = try pinnedRoot(create: true)
      try ensureLayout(pinned: pinned)
    }
    return try withCatalogLock(pinned: pinned, createIfMissing: false) {
      Thread.current.threadDictionary[Self.coordinatorCatalogKey] = true
      defer { Thread.current.threadDictionary.removeObject(forKey: Self.coordinatorCatalogKey) }
      return try body()
    }
  }

  func withCoordinatorWorkflowLocks<T>(
    workflowIds: [String],
    originIds: [String]? = nil,
    _ body: () throws -> T
  ) throws -> T {
    let heldWorkflowIds = Set(workflowIds)
    for workflowId in heldWorkflowIds { try validateWorkflowId(workflowId) }
    let alreadyHeld = Thread.current.threadDictionary[Self.coordinatorOriginsKey] as? Set<String> ?? []
    if heldWorkflowIds.isSubset(of: alreadyHeld) {
      return try body()
    }
    let orderedOrigins = Array(Set(originIds ?? workflowIds.map(mutableOriginId))).sorted()
    let pinned = try pinnedRoot(create: true)
    try ensureLayout(pinned: pinned)
    func acquire(_ index: Int) throws -> T {
      guard index < orderedOrigins.count else {
        Thread.current.threadDictionary[Self.coordinatorOriginsKey] = heldWorkflowIds
        defer { Thread.current.threadDictionary.removeObject(forKey: Self.coordinatorOriginsKey) }
        return try body()
      }
      let originId = orderedOrigins[index]
      return try withFileLock(
        pinned: pinned,
        locksRoot.appendingPathComponent(originLockName(originId: originId)),
        lock: .workflow(originId),
        createIfMissing: true
      ) {
        return try acquire(index + 1)
      }
    }
    return try acquire(0)
  }
}
