#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RielaCore

struct WorkflowDirectoryRecoveryFileSystem {
  var target: WorkflowBundleIdentity
  var parent: URL
  var detachedRoot: WorkflowDetachedOwnershipPinnedRoot?

  func directoryExists(_ url: URL) throws -> Bool {
    if let detachedRoot { return try detachedRoot.directoryExists(url.lastPathComponent) }
    return try directoryExistsWithoutFollowingLinks(url)
  }

  func verify(
    _ url: URL,
    digest: String,
    unowned: [WorkflowUnownedInventoryEntry]
  ) throws {
    let inventory = if let detachedRoot {
      try detachedRoot.inventory(for: target, directory: url.lastPathComponent)
    } else {
      try WorkflowHistoryIdentityResolver.inventory(for: target, rootOverride: url)
    }
    guard inventory.bundleDigest == digest,
          inventory.unownedFiles.map(WorkflowUnownedInventoryEntry.init) == unowned else {
      throw CLIUsageError("workflow transaction tree digest verification failed: \(url.path)")
    }
  }

  func remove(_ url: URL) throws {
    if let detachedRoot {
      try detachedRoot.removeDirectory(url.lastPathComponent)
    } else {
      try FileManager.default.removeItem(at: url)
    }
  }

  func move(_ source: URL, to destination: URL) throws {
    if let detachedRoot {
      try detachedRoot.renameDirectory(from: source.lastPathComponent, to: destination.lastPathComponent)
    } else {
      try moveSiblingDirectory(from: source, to: destination, parent: parent)
    }
  }

  func syncParent() throws {
    if let detachedRoot {
      try detachedRoot.sync()
      return
    }
    let descriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw CLIUsageError("unable to open workflow transaction parent for fsync") }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else { throw CLIUsageError("unable to fsync workflow transaction parent") }
  }
}
