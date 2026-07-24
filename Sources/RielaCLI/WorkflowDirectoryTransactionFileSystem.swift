#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RielaCore

struct WorkflowDirectoryCommitFileSystem {
  let detachedRoot: WorkflowDetachedOwnershipPinnedRoot?

  func requireConfiguredPathIdentity() throws {
    try detachedRoot?.requireConfiguredPathIdentity()
  }

  func accessURL(_ url: URL) throws -> URL {
    guard let detachedRoot else { return url }
    return try detachedRoot.stableDirectoryURL(url.lastPathComponent)
  }

  func readWorkflowBytes(target: WorkflowBundleIdentity, live: URL) throws -> Data {
    if let detachedRoot {
      return try detachedRoot.readRegularFile("workflow.json", in: live.lastPathComponent)
    }
    let workflowDirectory = URL(fileURLWithPath: target.workflowDirectory, isDirectory: true)
    let workflowURL = workflowDirectory.appendingPathComponent("workflow.json")
    return try WorkflowDescriptorRelativeReader.read(workflowURL, within: workflowDirectory).bytes
  }

  func inventory(for target: WorkflowBundleIdentity, at root: URL) throws -> WorkflowBundleInventory {
    if let detachedRoot {
      return try detachedRoot.inventory(for: target, directory: root.lastPathComponent)
    }
    return try WorkflowHistoryIdentityResolver.inventory(for: target, rootOverride: root)
  }

  func writeStableMetadata<T: Encodable>(_ value: T, marker: URL, parent: URL) throws {
    if let detachedRoot {
      try detachedRoot.writeCanonical(value, name: marker.lastPathComponent)
    } else {
      try WorkflowHistorySecurePersistence.writeCanonical(value, to: marker, historyRoot: parent)
    }
  }

  func copyDirectory(from source: URL, to destination: URL) throws {
    if let detachedRoot {
      try detachedRoot.copyDirectory(from: source.lastPathComponent, to: destination.lastPathComponent)
    } else {
      try FileManager.default.copyItem(at: source, to: destination)
    }
  }

  func prepareStaging(
    target: WorkflowBundleIdentity,
    live: URL,
    staging: URL,
    expectedAfterDigest: String,
    expectedUnowned: [WorkflowBundleSnapshotFile],
    mutate: (URL) throws -> Void
  ) throws -> [LoopVerificationEvidence] {
    try requireConfiguredPathIdentity()
    try copyDirectory(from: live, to: staging)
    let stagingAccess = try accessURL(staging)
    try mutate(stagingAccess)
    let verification = try WorkflowStagedVerifier().verify(target: target, stagingRoot: stagingAccess)
      .sorted { $0.id < $1.id }
    let staged = try inventory(for: target, at: staging)
    guard staged.bundleDigest == expectedAfterDigest else {
      throw CLIUsageError("staged workflow digest does not match reviewed result")
    }
    guard staged.unownedFiles.map(\.metadata) == expectedUnowned else {
      throw CLIUsageError("staged workflow changed unowned files")
    }
    try syncTree(staging)
    return verification
  }

  func directoryExists(_ url: URL) throws -> Bool {
    if let detachedRoot { return try detachedRoot.directoryExists(url.lastPathComponent) }
    return try directoryExistsWithoutFollowingLinks(url)
  }

  func entryExists(_ url: URL) throws -> Bool {
    if let detachedRoot { return try detachedRoot.entryExists(url.lastPathComponent) }
    return try historyEntryExistsWithoutFollowingLinks(url)
  }

  func renameDirectory(from source: URL, to destination: URL, parent: URL) throws {
    if let detachedRoot {
      try detachedRoot.renameDirectory(from: source.lastPathComponent, to: destination.lastPathComponent)
    } else {
      try moveSiblingDirectory(from: source, to: destination, parent: parent)
    }
  }

  func removeDirectory(_ url: URL) throws {
    if let detachedRoot {
      try detachedRoot.removeDirectory(url.lastPathComponent)
    } else {
      try FileManager.default.removeItem(at: url)
    }
  }

  func syncParent(_ parent: URL) throws {
    if let detachedRoot {
      try detachedRoot.sync()
    } else {
      try syncDirectory(parent)
    }
  }

  func verifyTree(
    _ root: URL,
    target: WorkflowBundleIdentity,
    digest: String,
    unowned: [WorkflowUnownedInventoryEntry]
  ) throws {
    let inventory = try inventory(for: target, at: root)
    guard inventory.bundleDigest == digest,
          inventory.unownedFiles.map(WorkflowUnownedInventoryEntry.init) == unowned else {
      throw CLIUsageError("workflow transaction tree digest verification failed: \(root.path)")
    }
  }

  func syncTree(_ root: URL) throws {
    if let detachedRoot {
      try detachedRoot.syncTree(root.lastPathComponent)
      return
    }
    var enumerationError: Error?
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      errorHandler: { url, error in
        enumerationError = CLIUsageError("unable to enumerate transaction staging entry \(url.path): \(error)")
        return false
      }
    ) else {
      throw CLIUsageError("unable to enumerate transaction staging tree for fsync")
    }
    var directories = [root]
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey])
      if values.isDirectory == true { directories.append(url) } else { try syncFile(url) }
    }
    if let enumerationError { throw enumerationError }
    for directory in directories.reversed() { try syncDirectory(directory) }
  }

  private func syncFile(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw CLIUsageError("unable to open file for fsync: \(url.path)") }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else { throw CLIUsageError("unable to fsync file: \(url.path)") }
  }

  private func syncDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw CLIUsageError("unable to open directory for fsync: \(url.path)") }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else { throw CLIUsageError("unable to fsync directory: \(url.path)") }
  }
}
