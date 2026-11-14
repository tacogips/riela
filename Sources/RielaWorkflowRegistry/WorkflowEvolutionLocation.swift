import Foundation
import RielaCore

/// Registry history remains anchored when a later workflow definition changes
/// its suggested historyRoot. The first selected location owns the lineage.
enum WorkflowEvolutionLocation {
  private struct Location: Codable {
    let schemaVersion: Int
    let workflowId: String
    let ownershipRoot: String
    let relativeHistoryRoot: String
  }

  static func recordedRoot(for target: WorkflowBundleIdentity) throws -> String? {
    let registry = WorkflowMutableRegistry()
    guard target.sourceMutable, target.sourceScope == .user,
      target.ownershipRoot == registry.root.appendingPathComponent(target.workflowId).path,
      let pinned = try registry.existingPinnedRoot() else { return nil }
    return try read(target: target, registry: registry, pinned: pinned)?.relativeHistoryRoot
  }

  static func anchor(
    target: WorkflowBundleIdentity, requestedRoot: String?, registry: WorkflowMutableRegistry,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws {
    if try read(target: target, registry: registry, pinned: pinned) != nil { return }
    let relative = requestedRoot ?? ".riela/workflow-history"
    // Validate scope containment and disjoint ownership before persisting.
    _ = try WorkflowHistoryIdentityResolver.historyRoot(for: target, workingDirectory: registry.root, configuredRoot: relative)
    let value = Location(schemaVersion: 1, workflowId: target.workflowId,
      ownershipRoot: target.ownershipRoot, relativeHistoryRoot: relative)
    let destination = locationURL(target: target, registry: registry)
    let temporary = registry.stateRoot.appendingPathComponent(".history-location-\(UUID().uuidString)")
    do {
      try pinned.writeNewRegularFile(WorkflowHistoryCanonicalCoding.encode(value), to: temporary)
      try pinned.rename(temporary, to: destination)
      try pinned.syncDirectory(registry.stateRoot)
    } catch {
      try? pinned.unlink(temporary)
      throw error
    }
  }

  private static func read(
    target: WorkflowBundleIdentity, registry: WorkflowMutableRegistry, pinned: WorkflowMutableRegistryPinnedRoot
  ) throws -> Location? {
    guard try pinned.entryType(registry.stateRoot) != nil else { return nil }
    guard let data = try pinned.readRegularIfPresent(locationURL(target: target, registry: registry)) else { return nil }
    let value = try WorkflowHistoryCanonicalCoding.decode(Location.self, from: data)
    guard value.schemaVersion == 1, value.workflowId == target.workflowId, value.ownershipRoot == target.ownershipRoot else {
      throw CLIUsageError("workflow history location identity mismatch")
    }
    try WorkflowHistoryCanonicalCoding.validateRelativePath(value.relativeHistoryRoot)
    return value
  }

  private static func locationURL(target: WorkflowBundleIdentity, registry: WorkflowMutableRegistry) -> URL {
    registry.stateRoot.appendingPathComponent("history-root-\(target.workflowId).json")
  }
}
