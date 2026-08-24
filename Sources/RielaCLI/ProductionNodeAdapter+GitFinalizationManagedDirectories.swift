import Foundation
#if canImport(Darwin)
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif
#else
import Glibc
#endif

final class GitFinalizationManagedDirectories: @unchecked Sendable {
  private struct Entry {
    var descriptor: Int32
    var device: UInt64
    var inode: UInt64
  }

  private let lock = NSRecursiveLock()
  private let rootDirectory: URL
  private var entries: [String: Entry] = [:]

  init(rootDirectory: URL) {
    self.rootDirectory = rootDirectory.standardizedFileURL
  }

  deinit {
    for entry in entries.values {
      close(entry.descriptor)
    }
  }

  func prepare(_ directories: [URL]) throws {
    lock.lock()
    defer { lock.unlock() }
    guard directories.first?.standardizedFileURL.path == rootDirectory.path else {
      throw policyError("git finalization managed-directory layout is invalid")
    }
    for directory in directories {
      try prepareDirectory(directory.standardizedFileURL)
    }
    try validateEntries()
  }

  func withDescriptor<Result>(
    at directory: URL,
    _ body: (Int32) throws -> Result
  ) throws -> Result {
    lock.lock()
    defer { lock.unlock() }
    try validateEntries()
    let path = directory.standardizedFileURL.path
    guard let entry = entries[path] else {
      throw policyError("git finalization directory is outside the managed layout")
    }
    return try body(entry.descriptor)
  }

  private func prepareDirectory(_ directory: URL) throws {
    if directory.path == rootDirectory.path {
      try prepareRootDirectory()
      return
    }
    guard directory.deletingLastPathComponent().standardizedFileURL.path == rootDirectory.path,
          let rootEntry = entries[rootDirectory.path] else {
      throw policyError("git finalization managed-directory layout is invalid")
    }
    let name = directory.lastPathComponent
    if mkdirat(rootEntry.descriptor, name, 0o700) != 0, errno != EEXIST {
      throw policyError("git finalization managed directory could not be created")
    }
    let descriptor = openat(
      rootEntry.descriptor,
      name,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      let openError = errno
      var status = stat()
      if fstatat(rootEntry.descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
         status.st_mode & S_IFMT == S_IFLNK {
        throw policyError("git finalization managed directory must not be a symbolic link")
      }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(openError))
    }
    try retainOrValidate(descriptor: descriptor, path: directory.path)
  }

  private func prepareRootDirectory() throws {
    try FileManager.default.createDirectory(
      at: rootDirectory.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if mkdir(rootDirectory.path, 0o700) != 0, errno != EEXIST {
      throw policyError("git finalization root directory could not be created")
    }
    let descriptor = open(
      rootDirectory.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      let openError = errno
      var status = stat()
      if lstat(rootDirectory.path, &status) == 0,
         status.st_mode & S_IFMT == S_IFLNK {
        throw policyError("git finalization root directory must not be a symbolic link")
      }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(openError))
    }
    try retainOrValidate(descriptor: descriptor, path: rootDirectory.path)
  }

  private func retainOrValidate(descriptor: Int32, path: String) throws {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          status.st_mode & S_IFMT == S_IFDIR,
          fchmod(descriptor, 0o700) == 0 else {
      close(descriptor)
      throw policyError("git finalization managed directory identity could not be established")
    }
    let candidate = Entry(
      descriptor: descriptor,
      device: UInt64(status.st_dev),
      inode: UInt64(status.st_ino)
    )
    if let retained = entries[path] {
      close(descriptor)
      guard retained.device == candidate.device, retained.inode == candidate.inode else {
        throw policyError("git finalization managed directory identity changed")
      }
      return
    }
    entries[path] = candidate
  }

  private func validateEntries() throws {
    guard let rootEntry = entries[rootDirectory.path] else {
      throw policyError("git finalization managed directories are not prepared")
    }
    try validatePathEntry(rootDirectory.path, expected: rootEntry)
    for (path, entry) in entries where path != rootDirectory.path {
      var status = stat()
      let name = URL(fileURLWithPath: path).lastPathComponent
      guard fstatat(rootEntry.descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
            status.st_mode & S_IFMT == S_IFDIR,
            UInt64(status.st_dev) == entry.device,
            UInt64(status.st_ino) == entry.inode else {
        throw policyError("git finalization managed directory identity changed")
      }
    }
  }

  private func validatePathEntry(_ path: String, expected: Entry) throws {
    var pathStatus = stat()
    var descriptorStatus = stat()
    guard lstat(path, &pathStatus) == 0,
          fstat(expected.descriptor, &descriptorStatus) == 0,
          pathStatus.st_mode & S_IFMT == S_IFDIR,
          pathStatus.st_dev == descriptorStatus.st_dev,
          pathStatus.st_ino == descriptorStatus.st_ino else {
      throw policyError("git finalization root directory identity changed")
    }
  }
}

func createGitFinalizationFile(
  in directoryDescriptor: Int32,
  name: String,
  data: Data,
  mode: mode_t = 0o600
) throws -> Int32 {
  let descriptor = openat(
    directoryDescriptor,
    name,
    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
    mode
  )
  guard descriptor >= 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  do {
    try data.withUnsafeBytes { rawBuffer in
      guard var address = rawBuffer.baseAddress else { return }
      var remaining = rawBuffer.count
      while remaining > 0 {
        let written = write(descriptor, address, remaining)
        if written < 0, errno == EINTR { continue }
        guard written > 0 else {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        remaining -= written
        address = address.advanced(by: written)
      }
    }
    guard fsync(descriptor) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return descriptor
  } catch {
    close(descriptor)
    _ = unlinkat(directoryDescriptor, name, 0)
    throw error
  }
}

func openOrCreateGitFinalizationDirectory(
  in parentDescriptor: Int32,
  name: String
) throws -> Int32 {
  if mkdirat(parentDescriptor, name, 0o700) != 0, errno != EEXIST {
    throw policyError("git finalization directory could not be created")
  }
  let descriptor = openat(
    parentDescriptor,
    name,
    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
  )
  guard descriptor >= 0,
        fchmod(descriptor, 0o700) == 0 else {
    if descriptor >= 0 { close(descriptor) }
    throw policyError("git finalization directory identity could not be established")
  }
  return descriptor
}

func unlinkGitFinalizationFileIfSame(
  in directoryDescriptor: Int32,
  name: String,
  openedDescriptor: Int32
) {
  var openedStatus = stat()
  var pathStatus = stat()
  guard fstat(openedDescriptor, &openedStatus) == 0,
        fstatat(directoryDescriptor, name, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0,
        openedStatus.st_mode & S_IFMT == S_IFREG,
        pathStatus.st_mode & S_IFMT == S_IFREG,
        openedStatus.st_dev == pathStatus.st_dev,
        openedStatus.st_ino == pathStatus.st_ino else {
    return
  }
  _ = unlinkat(directoryDescriptor, name, 0)
}

func gitFinalizationFileSnapshot(
  in directoryDescriptor: Int32,
  name: String
) throws -> GitFinalizationFileSnapshot? {
  let descriptor = openat(
    directoryDescriptor,
    name,
    O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
  )
  guard descriptor >= 0 else {
    if errno == ENOENT { return nil }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  defer { close(descriptor) }
  var status = stat()
  guard fstat(descriptor, &status) == 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  return GitFinalizationFileSnapshot(status)
}

func boundedGitFinalizationDirectoryEntries(
  directoryDescriptor: Int32,
  directoryURL: URL,
  maximumEntries: Int,
  includingHidden: Bool = false
) throws -> [URL] {
  guard maximumEntries >= 0 else {
    throw policyError("git finalization directory entry limit is invalid")
  }
  let duplicate = openat(
    directoryDescriptor,
    ".",
    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
  )
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

func boundedGitFinalizationRecordData(
  directoryDescriptor: Int32,
  name: String,
  maxBytes: Int,
  ownedHardLinkDirectoryDescriptor: Int32? = nil,
  ownedHardLinkEntryLimit: Int = 4_096
) throws -> Data {
  var preOpenStatus = stat()
  guard fstatat(directoryDescriptor, name, &preOpenStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  guard preOpenStatus.st_mode & S_IFMT == S_IFREG else {
    throw policyError("git finalization record must be a bounded regular file")
  }
  let descriptor = openat(
    directoryDescriptor,
    name,
    O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
  )
  guard descriptor >= 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  defer { close(descriptor) }
  var initialStatus = stat()
  guard fstat(descriptor, &initialStatus) == 0,
        initialStatus.st_mode & S_IFMT == S_IFREG,
        initialStatus.st_nlink >= 1,
        initialStatus.st_size >= 0,
        initialStatus.st_size <= maxBytes else {
    throw policyError("git finalization record must be a bounded regular file")
  }
  if initialStatus.st_nlink > 1 {
    guard let ownedHardLinkDirectoryDescriptor else {
      throw policyError("git finalization record has an unowned hard link")
    }
    try validateOwnedGitFinalizationTemporaryLinks(
      matching: initialStatus,
      directoryDescriptor: ownedHardLinkDirectoryDescriptor,
      maximumEntries: ownedHardLinkEntryLimit
    )
  }

  var data = Data()
  data.reserveCapacity(Int(initialStatus.st_size))
  var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
  while true {
    try checkGitFinalizationFilesystemDeadline()
    let bytesRead = read(descriptor, &buffer, buffer.count)
    if bytesRead > 0 {
      guard data.count + bytesRead <= maxBytes else {
        throw policyError("git finalization record exceeds its size limit")
      }
      data.append(buffer, count: bytesRead)
      continue
    }
    if bytesRead == 0 { break }
    if errno == EINTR { continue }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }

  var finalStatus = stat()
  var pathStatus = stat()
  guard fstat(descriptor, &finalStatus) == 0,
        fstatat(directoryDescriptor, name, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0,
        finalStatus.st_mode & S_IFMT == S_IFREG,
        finalStatus.st_nlink == initialStatus.st_nlink,
        finalStatus.st_dev == initialStatus.st_dev,
        finalStatus.st_ino == initialStatus.st_ino,
        finalStatus.st_size == initialStatus.st_size,
        data.count == Int(finalStatus.st_size),
        pathStatus.st_mode & S_IFMT == S_IFREG,
        pathStatus.st_dev == finalStatus.st_dev,
        pathStatus.st_ino == finalStatus.st_ino else {
    throw policyError("git finalization record changed during its bounded read")
  }
  if finalStatus.st_nlink > 1 {
    guard let ownedHardLinkDirectoryDescriptor else {
      throw policyError("git finalization record has an unowned hard link")
    }
    try validateOwnedGitFinalizationTemporaryLinks(
      matching: finalStatus,
      directoryDescriptor: ownedHardLinkDirectoryDescriptor,
      maximumEntries: ownedHardLinkEntryLimit
    )
  }
  return data
}

private func validateOwnedGitFinalizationTemporaryLinks(
  matching recordStatus: stat,
  directoryDescriptor: Int32,
  maximumEntries: Int
) throws {
  guard maximumEntries >= 0 else {
    throw policyError("git finalization temporary directory entry limit is invalid")
  }
  let duplicate = openat(
    directoryDescriptor,
    ".",
    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
  )
  guard duplicate >= 0, let directory = fdopendir(duplicate) else {
    let directoryError = errno
    if duplicate >= 0 { close(duplicate) }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(directoryError))
  }
  defer { closedir(directory) }
  var entryCount = 0
  var matchingLinkCount = 0
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
      throw policyError("git finalization temporary directory exceeds its entry limit")
    }
    var candidateStatus = stat()
    if fstatat(directoryDescriptor, name, &candidateStatus, AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { continue }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    guard candidateStatus.st_mode & S_IFMT == S_IFREG,
          candidateStatus.st_dev == recordStatus.st_dev,
          candidateStatus.st_ino == recordStatus.st_ino else {
      continue
    }
    matchingLinkCount += 1
  }
  guard Int(recordStatus.st_nlink) == matchingLinkCount + 1 else {
    throw policyError("git finalization record has an unowned hard link")
  }
}
