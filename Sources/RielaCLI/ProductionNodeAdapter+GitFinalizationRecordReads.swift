import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

func boundedGitFinalizationRecordData(
  from url: URL,
  maxBytes: Int,
  ownedHardLinkDirectory: URL? = nil,
  ownedHardLinkEntryLimit: Int = 4_096,
  afterOpen: () throws -> Void = {},
  afterOwnedHardLinkValidation: () throws -> Void = {}
) throws -> Data {
  let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
  guard descriptor >= 0 else {
    let openError = errno
    var pathStatus = stat()
    if lstat(url.path, &pathStatus) == 0,
       pathStatus.st_mode & S_IFMT != S_IFREG {
      throw policyError("git finalization record must be a bounded single-link regular file")
    }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(openError))
  }
  defer { close(descriptor) }
  try afterOpen()

  var initialStatus = stat()
  guard fstat(descriptor, &initialStatus) == 0,
        initialStatus.st_mode & S_IFMT == S_IFREG,
        initialStatus.st_nlink >= 1,
        initialStatus.st_size >= 0,
        initialStatus.st_size <= maxBytes else {
    throw policyError("git finalization record must be a bounded single-link regular file")
  }
  if initialStatus.st_nlink > 1 {
    guard let ownedHardLinkDirectory else {
      throw policyError("git finalization record must be a bounded single-link regular file")
    }
    try validateOwnedGitFinalizationTemporaryLinks(
      matching: initialStatus,
      in: ownedHardLinkDirectory,
      maximumEntries: ownedHardLinkEntryLimit
    )
    try afterOwnedHardLinkValidation()
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
        lstat(url.path, &pathStatus) == 0,
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
    guard let ownedHardLinkDirectory else {
      throw policyError("git finalization record has an unowned hard link")
    }
    try validateOwnedGitFinalizationTemporaryLinks(
      matching: finalStatus,
      in: ownedHardLinkDirectory,
      maximumEntries: ownedHardLinkEntryLimit
    )
  }
  return data
}

private func validateOwnedGitFinalizationTemporaryLinks(
  matching recordStatus: stat,
  in directoryURL: URL,
  maximumEntries: Int
) throws {
  guard maximumEntries >= 0 else {
    throw policyError("git finalization temporary directory entry limit is invalid")
  }
  let descriptor = open(
    directoryURL.path,
    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
  )
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
    if fstatat(descriptor, name, &candidateStatus, AT_SYMLINK_NOFOLLOW) != 0 {
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

func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
