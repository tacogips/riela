import Foundation
import RielaCore
#if canImport(Darwin)
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif
#else
import Glibc
#endif

#if canImport(Glibc)
@_silgen_name("renameat2")
private func gitFinalizationLinuxRenameAt2(
  _ oldDirectory: Int32,
  _ oldName: UnsafePointer<CChar>,
  _ newDirectory: Int32,
  _ newName: UnsafePointer<CChar>,
  _ flags: UInt32
) -> Int32
#endif

struct GitFinalizationFileSnapshot: Equatable {
  var device: UInt64
  var inode: UInt64
  var mode: mode_t
  var linkCount: nlink_t
  var size: off_t
  var modificationSeconds: Int64
  var modificationNanoseconds: Int64

  var isRegularFile: Bool { mode & S_IFMT == S_IFREG }

  init(_ status: stat) {
    #if canImport(Darwin)
    let modificationSeconds = status.st_mtimespec.tv_sec
    let modificationNanoseconds = status.st_mtimespec.tv_nsec
    #else
    let modificationSeconds = status.st_mtim.tv_sec
    let modificationNanoseconds = status.st_mtim.tv_nsec
    #endif
    device = UInt64(status.st_dev)
    inode = UInt64(status.st_ino)
    mode = status.st_mode
    linkCount = status.st_nlink
    size = status.st_size
    self.modificationSeconds = Int64(modificationSeconds)
    self.modificationNanoseconds = Int64(modificationNanoseconds)
  }

  func isOlder(than cutoff: Date) -> Bool {
    let modifiedAt = Double(modificationSeconds) + Double(modificationNanoseconds) / 1_000_000_000
    return modifiedAt < cutoff.timeIntervalSince1970
  }
}

func boundedGitFinalizationDirectoryEntries(
  at directoryURL: URL,
  maximumEntries: Int,
  includingHidden: Bool = false
) throws -> [URL] {
  guard maximumEntries >= 0 else {
    throw policyError("git finalization directory entry limit is invalid")
  }
  let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  guard descriptor >= 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  defer { close(descriptor) }
  let duplicate = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  guard duplicate >= 0, let directory = fdopendir(duplicate) else {
    let directoryError = errno
    if duplicate >= 0 { close(duplicate) }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(directoryError))
  }
  defer { closedir(directory) }

  var entryCount = 0
  var entries: [URL] = []
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
    entryCount += 1
    guard entryCount <= maximumEntries else {
      throw policyError("git finalization directory exceeds its entry limit")
    }
    if includingHidden || !name.hasPrefix(".") {
      entries.append(directoryURL.appendingPathComponent(name))
    }
  }
  return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func gitFinalizationFileSnapshot(at url: URL) throws -> GitFinalizationFileSnapshot? {
  let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
  guard descriptor >= 0 else {
    if errno == ENOENT { return nil }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  defer { close(descriptor) }
  var status = stat()
  guard fstat(descriptor, &status) == 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  return gitFinalizationFileSnapshot(status)
}

@discardableResult
func removeGitFinalizationEntryIfUnchanged(
  at url: URL,
  expected: GitFinalizationFileSnapshot,
  afterPathValidation: (URL) throws -> Void = { _ in }
) throws -> Bool {
  guard expected.isRegularFile else { return false }
  let directoryURL = url.deletingLastPathComponent()
  let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  guard descriptor >= 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  defer { close(descriptor) }
  return try removeGitFinalizationEntryIfUnchanged(
    directoryDescriptor: descriptor,
    url: url,
    expected: expected,
    afterPathValidation: afterPathValidation
  )
}

@discardableResult
func removeGitFinalizationEntryIfUnchanged(
  directoryDescriptor descriptor: Int32,
  url: URL,
  expected: GitFinalizationFileSnapshot,
  afterPathValidation: (URL) throws -> Void = { _ in }
) throws -> Bool {
  guard expected.isRegularFile else { return false }
  let name = url.lastPathComponent
  let opened = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
  guard opened >= 0 else {
    if errno == ENOENT { return false }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  defer { close(opened) }
  var openedStatus = stat()
  guard fstat(opened, &openedStatus) == 0,
        gitFinalizationFileSnapshot(openedStatus) == expected else {
    return false
  }

  try checkGitFinalizationFilesystemDeadline()
  var pathStatus = stat()
  guard fstatat(descriptor, name, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0,
        gitFinalizationFileSnapshot(pathStatus) == expected else {
    return false
  }
  try afterPathValidation(url)

  let quarantineName = ".gc-\(UUID().uuidString)"
  guard mkdirat(descriptor, quarantineName, 0o700) == 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  let quarantine = openat(descriptor, quarantineName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  guard quarantine >= 0 else {
    let quarantineError = errno
    _ = unlinkat(descriptor, quarantineName, AT_REMOVEDIR)
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(quarantineError))
  }
  defer {
    close(quarantine)
    _ = unlinkat(descriptor, quarantineName, AT_REMOVEDIR)
  }

  guard renameat(descriptor, name, quarantine, "entry") == 0 else {
    if errno == ENOENT { return false }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  let moved = openat(quarantine, "entry", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
  guard moved >= 0 else {
    try restoreGitFinalizationQuarantinedEntry(
      from: quarantine,
      to: descriptor,
      name: name
    )
    return false
  }
  defer { close(moved) }
  var movedStatus = stat()
  guard fstat(moved, &movedStatus) == 0,
        gitFinalizationFileSnapshot(movedStatus) == expected else {
    try restoreGitFinalizationQuarantinedEntry(
      from: quarantine,
      to: descriptor,
      name: name
    )
    return false
  }
  guard unlinkat(quarantine, "entry", 0) == 0,
        fsync(quarantine) == 0,
        fsync(descriptor) == 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  return true
}

private func restoreGitFinalizationQuarantinedEntry(
  from quarantine: Int32,
  to directory: Int32,
  name: String
) throws {
  let result = "entry".withCString { sourceName in
    name.withCString { destinationName in
      #if canImport(Darwin)
      renameatx_np(
        quarantine,
        sourceName,
        directory,
        destinationName,
        UInt32(RENAME_EXCL)
      )
      #else
      gitFinalizationLinuxRenameAt2(
        quarantine,
        sourceName,
        directory,
        destinationName,
        1
      )
      #endif
    }
  }
  guard result == 0 else {
    if errno == EEXIST { return }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  guard fsync(quarantine) == 0,
        fsync(directory) == 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
}

func checkGitFinalizationFilesystemDeadline() throws {
  if let deadline = GitCommandRuntimeContext.deadline,
     !deadline.timeIntervalSinceNow.isFinite || deadline <= Date() {
    throw AdapterExecutionError(.timeout, "git finalization filesystem operation exceeded its workflow deadline")
  }
}

private func gitFinalizationFileSnapshot(_ status: stat) -> GitFinalizationFileSnapshot {
  GitFinalizationFileSnapshot(status)
}
