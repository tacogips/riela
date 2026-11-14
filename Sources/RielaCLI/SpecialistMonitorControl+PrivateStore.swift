import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension SpecialistMonitorControl {
  func preparePrivateStore() throws { _ = try SpecialistMonitorStorePin(stateRoot: stateRoot, repairPermissions: true) }
  func verifyPrivateStore() throws { _ = try SpecialistMonitorStorePin(stateRoot: stateRoot, repairPermissions: false) }
}

/// Pins every path component from `/` with openat/O_NOFOLLOW. The state root
/// must be owner-controlled and non-writable by other users; ancestors must
/// likewise prevent replacement (root-owned sticky temporary roots are safe).
/// SQLite's path-based API is bracketed by identity checks, while these access
/// restrictions prevent another UID from swapping a component between checks.
final class SpecialistMonitorStorePin: @unchecked Sendable {
  private enum Kind {
    case ancestor, stateRoot, runtimeDirectory, database
  }
  private struct Component {
    let parent: Int32
    let descriptor: Int32
    let name: String
    let kind: Kind
    let device: dev_t
    let inode: ino_t
  }
  private let filesystemRoot: Int32
  private let components: [Component]

  init(stateRoot: String, repairPermissions: Bool) throws {
    let root = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard root >= 0 else { throw CLIUsageError("specialist monitor filesystem root is unavailable") }
    var opened: [Component] = []
    do {
      let names = stateRoot.split(separator: "/").map(String.init)
      guard stateRoot.hasPrefix("/"), !names.isEmpty, !names.contains(".."), !names.contains(".") else {
        throw CLIUsageError("specialist monitor requires a canonical state root")
      }
      try Self.validate(root, kind: .ancestor, repairPermissions: false)
      let chain = names + ["runtime-records", SpecialistSupervisorStore.databaseFileName]
      var parent = root
      for (index, name) in chain.enumerated() {
        let kind: Kind
        if index < names.count - 1 {
          kind = .ancestor
        } else if index == names.count - 1 {
          kind = .stateRoot
        } else if index == names.count {
          kind = .runtimeDirectory
        } else {
          kind = .database
        }
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (kind == .database ? 0 : O_DIRECTORY)
        let descriptor = openat(parent, name, flags)
        guard descriptor >= 0 else { throw CLIUsageError("specialist monitor control path is missing or linked") }
        do {
          try Self.validate(descriptor, kind: kind, repairPermissions: repairPermissions)
          var metadata = stat()
          guard fstat(descriptor, &metadata) == 0 else { throw CLIUsageError("specialist monitor inode is unavailable") }
          opened.append(Component(parent: parent, descriptor: descriptor, name: name, kind: kind,
                                  device: metadata.st_dev, inode: metadata.st_ino))
          parent = descriptor
        } catch {
          _ = close(descriptor)
          throw error
        }
      }
      try Self.requireIdentity(opened)
      filesystemRoot = root
      components = opened
    } catch {
      for component in opened { _ = close(component.descriptor) }
      _ = close(root)
      throw error
    }
  }

  deinit {
    for component in components { _ = close(component.descriptor) }
    _ = close(filesystemRoot)
  }

  func withVerifiedIdentity<Result>(_ operation: () throws -> Result) throws -> Result {
    try requireIdentity()
    let result = try operation()
    try requireIdentity()
    return result
  }

  func requireIdentity() throws {
    try Self.requireIdentity(components)
  }

  private static func requireIdentity(_ components: [Component]) throws {
    for component in components {
      var current = stat()
      guard fstatat(component.parent, component.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
            current.st_dev == component.device, current.st_ino == component.inode else {
        throw CLIUsageError("specialist monitor control path identity changed")
      }
      try validate(component.descriptor, kind: component.kind, repairPermissions: false)
    }
  }

  private static func validate(_ descriptor: Int32, kind: Kind, repairPermissions: Bool) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          metadata.st_uid == geteuid() || (kind == .ancestor && metadata.st_uid == 0),
          metadata.st_mode & mode_t(S_IFMT) == mode_t(kind == .database ? S_IFREG : S_IFDIR),
          kind != .database || metadata.st_nlink == 1 else {
      throw CLIUsageError("specialist monitor control has unsafe inode ownership or type")
    }
    let protectedStickyAncestor = kind == .ancestor && metadata.st_uid == 0 && metadata.st_mode & mode_t(S_ISVTX) != 0
    guard metadata.st_mode & 0o022 == 0 || protectedStickyAncestor else {
      throw CLIUsageError("specialist monitor state root and ancestry must not be group/other writable")
    }
    guard kind == .runtimeDirectory || kind == .database else { return }
    let permissions = mode_t(kind == .runtimeDirectory ? 0o700 : 0o600)
    if repairPermissions {
      guard fchmod(descriptor, permissions) == 0 else {
        throw CLIUsageError("specialist monitor control permissions could not be secured")
      }
    } else if metadata.st_mode & 0o777 != permissions {
      throw CLIUsageError("specialist monitor control permissions are not private")
    }
  }
}
