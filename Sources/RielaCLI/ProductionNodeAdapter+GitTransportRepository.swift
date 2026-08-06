import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if canImport(Glibc)
@_silgen_name("renameat2")
private func gitTransportLinuxRenameAt2(
  _ oldDirectory: Int32,
  _ oldName: UnsafePointer<CChar>,
  _ newDirectory: Int32,
  _ newName: UnsafePointer<CChar>,
  _ flags: UInt32
) -> Int32
#endif

struct GitOwnedTransportRepository: Sendable {
  var url: URL
  var device: UInt64
  var inode: UInt64
  var modificationSeconds: Int64
  var modificationNanoseconds: Int64

  func isOlder(than cutoff: Date) -> Bool {
    let modifiedAt = Double(modificationSeconds) + Double(modificationNanoseconds) / 1_000_000_000
    return modifiedAt < cutoff.timeIntervalSince1970
  }
}

func captureOwnedTransportRepository(
  in parentDescriptor: Int32,
  name: String,
  url: URL
) throws -> GitOwnedTransportRepository {
  let descriptor = openat(
    parentDescriptor,
    name,
    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
  )
  guard descriptor >= 0 else {
    throw policyError("git transport repository identity could not be established")
  }
  defer { close(descriptor) }
  var status = stat()
  guard fstat(descriptor, &status) == 0,
        status.st_mode & S_IFMT == S_IFDIR else {
    throw policyError("git transport repository identity could not be established")
  }
  return ownedTransportRepository(url: url, status: status)
}

extension GitFinalizationStore {
  func requireOwnedTransportRepository(_ repository: GitOwnedTransportRepository) throws {
    guard repository.url.deletingLastPathComponent().standardizedFileURL.path
      == transportDirectory.path else {
      throw policyError("git transport repository is outside the managed layout")
    }
    try managedDirectorySet.withDescriptor(at: transportDirectory) { parentDescriptor in
      let descriptor = openat(
        parentDescriptor,
        repository.url.lastPathComponent,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard descriptor >= 0 else {
        throw policyError("git transport repository identity changed")
      }
      defer { close(descriptor) }
      var status = stat()
      guard fstat(descriptor, &status) == 0,
            matchesOwnedTransportRepository(status, repository: repository) else {
        throw policyError("git transport repository identity changed")
      }
    }
  }

  @discardableResult
  func removeOwnedTransportRepository(
    _ repository: GitOwnedTransportRepository,
    maximumEntries: Int = 4_096,
    maximumDepth: Int = 16
  ) throws -> Bool {
    guard repository.url.deletingLastPathComponent().standardizedFileURL.path
      == transportDirectory.path else {
      throw policyError("git transport repository is outside the managed layout")
    }
    return try managedDirectorySet.withDescriptor(at: transportDirectory) { parentDescriptor in
      let sourceName = repository.url.lastPathComponent
      let quarantineName = ".cleanup-\(UUID().uuidString)"
      guard exclusiveTransportRename(
        from: parentDescriptor,
        name: sourceName,
        to: parentDescriptor,
        newName: quarantineName
      ) == 0 else {
        if errno == ENOENT { return false }
        throw policyError("git transport repository could not be quarantined")
      }

      let descriptor = openat(
        parentDescriptor,
        quarantineName,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard descriptor >= 0 else {
        try restoreTransportEntry(
          parentDescriptor: parentDescriptor,
          quarantineName: quarantineName,
          originalName: sourceName
        )
        return false
      }
      defer { close(descriptor) }
      var status = stat()
      guard fstat(descriptor, &status) == 0,
            matchesOwnedTransportRepository(status, repository: repository) else {
        try restoreTransportEntry(
          parentDescriptor: parentDescriptor,
          quarantineName: quarantineName,
          originalName: sourceName
        )
        return false
      }

      var removedEntries = 0
      try removeTransportDirectoryContents(
        descriptor: descriptor,
        depth: 0,
        removedEntries: &removedEntries,
        maximumEntries: maximumEntries,
        maximumDepth: maximumDepth
      )
      var pathStatus = stat()
      guard fstatat(parentDescriptor, quarantineName, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0,
            matchesOwnedTransportRepository(pathStatus, repository: repository) else {
        return false
      }
      guard unlinkat(parentDescriptor, quarantineName, AT_REMOVEDIR) == 0,
            fsync(parentDescriptor) == 0 else {
        throw policyError("git transport repository could not be removed")
      }
      return true
    }
  }

  func garbageCollectOrphanTransportRepositories(
    cutoff: Date,
    remaining: Int,
    entryLimit: Int
  ) throws -> Int {
    var remaining = remaining
    let candidates = try managedDirectoryEntries(
      at: transportDirectory,
      maximumEntries: entryLimit,
      includingHidden: true
    )
    for candidate in candidates where remaining > 0 {
      try checkGitFinalizationFilesystemDeadline()
      guard let repository = try ownedTransportRepositoryIfPresent(at: candidate),
            repository.isOlder(than: cutoff),
            try removeOwnedTransportRepository(
              repository,
              maximumEntries: entryLimit
            ) else {
        continue
      }
      remaining -= 1
    }
    return remaining
  }

  private func ownedTransportRepositoryIfPresent(
    at url: URL
  ) throws -> GitOwnedTransportRepository? {
    try managedDirectorySet.withDescriptor(at: transportDirectory) { parentDescriptor in
      let descriptor = openat(
        parentDescriptor,
        url.lastPathComponent,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
      )
      guard descriptor >= 0 else {
        if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { return nil }
        throw policyError("git transport repository could not be inspected")
      }
      defer { close(descriptor) }
      var status = stat()
      guard fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFDIR else {
        return nil
      }
      return ownedTransportRepository(url: url, status: status)
    }
  }
}

private func removeTransportDirectoryContents(
  descriptor: Int32,
  depth: Int,
  removedEntries: inout Int,
  maximumEntries: Int,
  maximumDepth: Int
) throws {
  guard depth <= maximumDepth else {
    throw policyError("git transport repository exceeds its cleanup depth limit")
  }
  let duplicate = dup(descriptor)
  guard duplicate >= 0, let directory = fdopendir(duplicate) else {
    let directoryError = errno
    if duplicate >= 0 { close(duplicate) }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(directoryError))
  }
  defer { closedir(directory) }
  while true {
    try checkGitFinalizationFilesystemDeadline()
    errno = 0
    guard let entry = readdir(directory) else {
      if errno != 0 {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      break
    }
    let name = withUnsafePointer(to: entry.pointee.d_name) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
        String(cString: $0)
      }
    }
    if name == "." || name == ".." { continue }
    removedEntries += 1
    guard removedEntries <= maximumEntries else {
      throw policyError("git transport repository exceeds its cleanup entry limit")
    }
    var initialStatus = stat()
    guard fstatat(descriptor, name, &initialStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { continue }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    if initialStatus.st_mode & S_IFMT == S_IFDIR {
      let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard child >= 0 else {
        throw policyError("git transport repository changed during cleanup")
      }
      var openedStatus = stat()
      guard fstat(child, &openedStatus) == 0,
            sameTransportEntry(initialStatus, openedStatus) else {
        close(child)
        throw policyError("git transport repository changed during cleanup")
      }
      do {
        try removeTransportDirectoryContents(
          descriptor: child,
          depth: depth + 1,
          removedEntries: &removedEntries,
          maximumEntries: maximumEntries,
          maximumDepth: maximumDepth
        )
      } catch {
        close(child)
        throw error
      }
      close(child)
      var finalStatus = stat()
      guard fstatat(descriptor, name, &finalStatus, AT_SYMLINK_NOFOLLOW) == 0,
            sameTransportEntry(openedStatus, finalStatus),
            unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else {
        throw policyError("git transport repository changed during cleanup")
      }
    } else if unlinkat(descriptor, name, 0) != 0, errno != ENOENT {
      throw policyError("git transport repository entry could not be removed")
    }
  }
  guard fsync(descriptor) == 0 else {
    throw policyError("git transport repository cleanup could not be synchronized")
  }
}

private func ownedTransportRepository(url: URL, status: stat) -> GitOwnedTransportRepository {
  #if canImport(Darwin)
  let modificationSeconds = status.st_mtimespec.tv_sec
  let modificationNanoseconds = status.st_mtimespec.tv_nsec
  #else
  let modificationSeconds = status.st_mtim.tv_sec
  let modificationNanoseconds = status.st_mtim.tv_nsec
  #endif
  return GitOwnedTransportRepository(
    url: url,
    device: UInt64(status.st_dev),
    inode: UInt64(status.st_ino),
    modificationSeconds: Int64(modificationSeconds),
    modificationNanoseconds: Int64(modificationNanoseconds)
  )
}

private func matchesOwnedTransportRepository(
  _ status: stat,
  repository: GitOwnedTransportRepository
) -> Bool {
  status.st_mode & S_IFMT == S_IFDIR
    && UInt64(status.st_dev) == repository.device
    && UInt64(status.st_ino) == repository.inode
}

private func sameTransportEntry(_ lhs: stat, _ rhs: stat) -> Bool {
  lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT
    && lhs.st_dev == rhs.st_dev
    && lhs.st_ino == rhs.st_ino
}

private func restoreTransportEntry(
  parentDescriptor: Int32,
  quarantineName: String,
  originalName: String
) throws {
  let result = exclusiveTransportRename(
    from: parentDescriptor,
    name: quarantineName,
    to: parentDescriptor,
    newName: originalName
  )
  guard result == 0 || errno == EEXIST else {
    throw policyError("git transport repository replacement could not be restored")
  }
  guard fsync(parentDescriptor) == 0 else {
    throw policyError("git transport repository restoration could not be synchronized")
  }
}

private func exclusiveTransportRename(
  from sourceDirectory: Int32,
  name sourceName: String,
  to destinationDirectory: Int32,
  newName destinationName: String
) -> Int32 {
  sourceName.withCString { source in
    destinationName.withCString { destination in
      #if canImport(Darwin)
      renameatx_np(
        sourceDirectory,
        source,
        destinationDirectory,
        destination,
        UInt32(RENAME_EXCL)
      )
      #else
      gitTransportLinuxRenameAt2(
        sourceDirectory,
        source,
        destinationDirectory,
        destination,
        1
      )
      #endif
    }
  }
}
