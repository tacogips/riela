import Foundation
import RielaCore

extension WorkflowMutableRegistry {
  func historyBundleDigest(
    at directory: URL,
    target: WorkflowBundleIdentity,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws -> String {
    try pinned.requireConfiguredPathIdentity()
    let discovered = try pinned.bundleInventory(in: directory).compactMap { entry -> WorkflowOwnedFile? in
      guard let bytes = entry.bytes else { return nil }
      let metadata = WorkflowBundleSnapshotFile(
        relativePath: entry.relativePath,
        contentDigest: WorkflowHistoryCanonicalCoding.sha256(bytes),
        byteCount: bytes.count,
        artifactKind: WorkflowHistoryIdentityResolver.artifactKind(entry.relativePath),
        executable: entry.mode & 0o111 != 0
      )
      return WorkflowOwnedFile(
        metadata: metadata,
        url: directory.appendingPathComponent(entry.relativePath),
        bytes: bytes,
        readRoot: directory
      )
    }
    var dependencyInventories: [String: [String: WorkflowMutableRegistryInventoryEntry]] = [:]
    let dependencyReader: WorkflowSharedNodeDependencyReader = { workflowId, relativePath in
      let inventory: [String: WorkflowMutableRegistryInventoryEntry]
      if let cached = dependencyInventories[workflowId] {
        inventory = cached
      } else {
        let dependencyDirectory = root.appendingPathComponent(workflowId, isDirectory: true)
        let loaded = try pinned.bundleInventory(in: dependencyDirectory)
        inventory = Dictionary(uniqueKeysWithValues: loaded.map { ($0.relativePath, $0) })
        dependencyInventories[workflowId] = inventory
      }
      guard let entry = inventory[relativePath], let bytes = entry.bytes else {
        throw CLIUsageError(
          "shared workflow '\(workflowId)' is missing regular file '\(relativePath)'"
        )
      }
      return WorkflowDescriptorRelativeRead(bytes: bytes, mode: entry.mode)
    }
    let inventory = try WorkflowHistoryIdentityResolver.inventory(
      for: target,
      discovered: discovered,
      dependencyReader: dependencyReader
    )
    try pinned.requireConfiguredPathIdentity()
    return inventory.bundleDigest
  }
}
