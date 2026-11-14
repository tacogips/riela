import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A minimal snapshot outside writable guest state. Directory-only runtimes
/// can mount this tree read-only even when the selected credential is one file.
final class SandboxCredentialProjection: Sendable {
  let root: URL
  let links: [(homePath: String, source: URL)]

  init(credentials: [WorkflowSandboxCredential], parent: URL, writableRoots: [URL]) throws {
    let root = parent.appendingPathComponent("riela-credentials-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    self.root = root
    var budget = CopyBudget()
    var links: [(String, URL)] = []
    do {
      for (index, credential) in credentials.enumerated() {
        let source = try Self.physical(credential.source)
        for writable in writableRoots {
          let write = try Self.physical(writable.path)
          guard !Self.overlaps(source, write), !Self.overlaps(credential.source, writable.path),
                !Self.overlaps(root.path, write) else { throw Self.denied() }
        }
        let entry = root.appendingPathComponent(String(index), isDirectory: true)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let destination = entry.appendingPathComponent("value")
        try Self.copy(source: URL(fileURLWithPath: source), destination: destination, depth: 0, budget: &budget)
        links.append((credential.homePath, destination))
      }
      self.links = links
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  func install(in home: URL) throws {
    for link in links {
      let components = link.homePath.split(separator: "/").map(String.init)
      guard let leaf = components.last else { throw Self.denied() }
      let parent = try SandboxPinnedDirectory(path: home.path, children: Array(components.dropLast()))
      // Removing a private symlink/local refreshed file never follows it back
      // to a host credential. A planted directory/symlink parent is refused.
      if unlinkat(parent.descriptor, leaf, 0) != 0, errno != ENOENT { throw Self.denied() }
      guard symlinkat(link.source.path, parent.descriptor, leaf) == 0 else { throw Self.denied() }
    }
  }

  private struct CopyBudget {
    var bytes = BuiltinAddonContainerRequest.maximumRecordBytes
    var entries = 1_024
  }

  private static func copy(source: URL, destination: URL, depth: Int, budget: inout CopyBudget) throws {
    budget.entries -= 1
    guard depth < 32, budget.entries >= 0 else { throw denied() }
    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
    switch attributes[.type] as? FileAttributeType {
    case .typeRegular:
      let bytes = try NativeAddonPinnedFile(path: source.path).readData()
      budget.bytes -= bytes.count
      guard budget.bytes >= 0 else { throw denied() }
      try bytes.write(to: destination, options: .withoutOverwriting)
      try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
    case .typeDirectory:
      let pinned = try SandboxPinnedDirectory(path: source.path)
      defer { withExtendedLifetime(pinned) {} }
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
        try copy(source: child, destination: destination.appendingPathComponent(child.lastPathComponent), depth: depth + 1, budget: &budget)
      }
    default: throw denied()
    }
  }

  private static func physical(_ path: String) throws -> String {
    guard let value = realpath(path, nil) else { throw denied() }
    defer { free(value) }
    return String(cString: value)
  }

  private static func overlaps(_ left: String, _ right: String) -> Bool {
    left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
  }

  private static func denied() -> AdapterExecutionError {
    .init(.policyBlocked, "credential projection requires bounded regular files outside writable shares and symlink-free private HOME directories")
  }
}

/// Pin every parent while installing credential aliases into a guest-writable
/// HOME; previous vendor runs must not redirect host-side file preparation.
private final class SandboxPinnedDirectory {
  let descriptor: Int32

  init(path: String, children: [String] = []) throws {
    var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard directory >= 0 else { throw Self.denied() }
    do {
      for component in path.split(separator: "/").map(String.init) {
        let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else { throw Self.denied() }
        close(directory)
        directory = next
      }
      for component in children {
        if mkdirat(directory, component, 0o700) != 0, errno != EEXIST { throw Self.denied() }
        let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else { throw Self.denied() }
        close(directory)
        directory = next
      }
      descriptor = directory
    } catch {
      close(directory)
      throw error
    }
  }

  deinit { close(descriptor) }
  private static func denied() -> AdapterExecutionError { .init(.policyBlocked, "credential HOME directory contains an inaccessible or symbolic-link parent") }
}
