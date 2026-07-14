#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RielaCore

enum WorkflowHistorySecurePersistence {
  enum EntryType {
    case regularFile
    case directory
  }

  static func ensureDirectory(_ directory: URL, historyRoot: URL) throws {
    try WorkflowHistoryPinnedRoot(historyRoot).ensureDirectory(directory)
  }

  static func writeCanonical<T: Encodable>(
    _ value: T,
    to url: URL,
    historyRoot: URL,
    overwrite: Bool = true
  ) throws {
    let bytes = try WorkflowHistoryCanonicalCoding.encode(value)
    try writePersistedBytes(bytes, to: url, historyRoot: historyRoot, overwrite: overwrite)
  }

  static func readCanonical<T: Codable>(_ type: T.Type, from url: URL, historyRoot: URL) throws -> T {
    if type == WorkflowDirectoryTransactionRecord.self,
       let record = try WorkflowTransactionGenerationStore.readLatest(logicalURL: url, historyRoot: historyRoot) {
      guard let typed = record as? T else {
        throw CLIUsageError("transaction generation decoded to an unexpected type")
      }
      return typed
    }
    let bytes = try readPersistedBytes(from: url, historyRoot: historyRoot)
    return try WorkflowHistoryCanonicalCoding.decode(type, from: bytes)
  }

  static func writePersistedBytes(
    _ bytes: Data,
    to url: URL,
    historyRoot: URL,
    overwrite: Bool = true
  ) throws {
    try validateContained(url, historyRoot: historyRoot, leafType: nil)
    let parent = url.deletingLastPathComponent()
    try ensureDirectory(parent, historyRoot: historyRoot)
    try atomicWrite(bytes, to: url, historyRoot: historyRoot, overwrite: overwrite)
    let sidecar = digestSidecar(for: url)
    try atomicWrite(
      Data("\(WorkflowHistoryCanonicalCoding.sha256(bytes))\n".utf8),
      to: sidecar,
      historyRoot: historyRoot,
      overwrite: overwrite
    )
    try validateContained(url, historyRoot: historyRoot, leafType: .regularFile)
    try validateContained(sidecar, historyRoot: historyRoot, leafType: .regularFile)
    let pinned = try WorkflowHistoryPinnedRoot(historyRoot, create: false)
    let parentDescriptor = try pinned.openDirectory(try pinned.relativePath(for: parent))
    defer { _ = close(parentDescriptor) }
    guard fsync(parentDescriptor) == 0 else { throw CLIUsageError("unable to fsync workflow history directory") }
  }

  static func readPersistedBytes(from url: URL, historyRoot: URL) throws -> Data {
    let sidecar = digestSidecar(for: url)
    let pinned = try WorkflowHistoryPinnedRoot(historyRoot, create: false)
    let bytes = try pinned.readRegular(url)
    let digest = try pinned.readRegular(sidecar)
    guard digest == Data("\(WorkflowHistoryCanonicalCoding.sha256(bytes))\n".utf8) else {
      throw WorkflowHistoryValidationError.integrityMismatch
    }
    return bytes
  }

  static func validateContained(
    _ url: URL,
    historyRoot: URL,
    leafType: EntryType?
  ) throws {
    let root = historyRoot.standardizedFileURL
    let candidate = url.standardizedFileURL
    guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
      throw CLIUsageError("workflow history path escapes selected root")
    }
    try WorkflowHistoryIdentityResolver.rejectSymbolicLinkComponents(in: candidate, stoppingAt: root)
    guard let leafType, FileManager.default.fileExists(atPath: candidate.path) else { return }
    var status = stat()
    guard lstat(candidate.path, &status) == 0 else {
      throw CLIUsageError("unable to inspect workflow history path: \(candidate.path)")
    }
    let actual = status.st_mode & S_IFMT
    let expected = leafType == .regularFile ? S_IFREG : S_IFDIR
    guard actual == expected else {
      throw CLIUsageError("workflow history entry type changed: \(candidate.path)")
    }
  }

  static func openLock(_ url: URL, historyRoot: URL) throws -> Int32 {
    let pinned = try WorkflowHistoryPinnedRoot(historyRoot)
    let descriptor = try pinned.withParent(of: url, create: true) { parent, leaf in
      openat(parent, leaf, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else {
      throw CLIUsageError("workflow transaction lock must be a regular non-symbolic-link file")
    }
    var status = stat()
    guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
      _ = close(descriptor)
      throw CLIUsageError("workflow transaction lock entry type changed")
    }
    return descriptor
  }

  static func digestSidecar(for url: URL) -> URL {
    URL(fileURLWithPath: url.path + ".sha256")
  }

  private static func atomicWrite(
    _ bytes: Data,
    to url: URL,
    historyRoot: URL,
    overwrite: Bool
  ) throws {
    try WorkflowHistoryPinnedRoot(historyRoot).atomicWrite(bytes, to: url, overwrite: overwrite)
  }
}
