#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

package struct WorkflowDetachedOwnershipRootIdentity: Equatable, Sendable {
  package var root: URL
  package var containerDevice: UInt64
  package var containerInode: UInt64
}

package enum WorkflowDetachedOwnershipRoot {
  static let containerPrefix = "riela-temporary-snapshot-"

  package static func create() throws -> URL {
    let namespace = canonicalNamespaceRoot
    let pinned = try WorkflowHistoryPinnedRoot(namespace, create: false)
    let container = containerPrefix + UUID().uuidString.lowercased()
    guard mkdirat(pinned.descriptor, container, S_IRWXU) == 0 else {
      throw CLIUsageError("unable to create detached workflow ownership container")
    }
    let descriptor = openat(pinned.descriptor, container, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      _ = unlinkat(pinned.descriptor, container, AT_REMOVEDIR)
      throw CLIUsageError("unable to pin detached workflow ownership container")
    }
    defer { _ = close(descriptor) }
    guard mkdirat(descriptor, "root", S_IRWXU) == 0, fsync(descriptor) == 0 else {
      _ = unlinkat(pinned.descriptor, container, AT_REMOVEDIR)
      throw CLIUsageError("unable to create detached workflow ownership root")
    }
    let root = namespace.appendingPathComponent(container, isDirectory: true)
      .appendingPathComponent("root", isDirectory: true)
    return try validate(root, requireRoot: true).root
  }

  package static func validate(
    _ candidate: URL,
    requireRoot: Bool
  ) throws -> WorkflowDetachedOwnershipRootIdentity {
    try WorkflowDetachedOwnershipPinnedRoot(candidate: candidate, requireRoot: requireRoot).identity
  }

  package static func validateCanonicalPath(_ candidate: URL) throws -> URL {
    let root = candidate.standardizedFileURL
    let container = root.deletingLastPathComponent()
    let namespace = canonicalNamespaceRoot
    let name = container.lastPathComponent
    let identifier = String(name.dropFirst(containerPrefix.count))
    guard candidate.path == root.path,
          root.lastPathComponent == "root",
          container.deletingLastPathComponent().path == namespace.path,
          name.hasPrefix(containerPrefix),
          let uuid = UUID(uuidString: identifier),
          uuid.uuidString.lowercased() == identifier else {
      throw CLIUsageError("detached workflow ownership root is outside its canonical temporary namespace")
    }
    return root
  }

  static var canonicalNamespaceRoot: URL {
    FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
  }
}
