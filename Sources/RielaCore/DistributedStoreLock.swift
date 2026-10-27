import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Serializes local controller and workflow processes. This is not a network
/// filesystem lock: workers never open the controller store.
final class DistributedStoreLock {
  private let descriptor: Int32
  private let processLock: NSRecursiveLock

  init(url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw DistributedWorkerError.storeUnavailable }
    processLock = DistributedStoreProcessLockRegistry.shared.lock(for: url.standardizedFileURL.path)
  }

  deinit { close(descriptor) }

  func acquire() throws {
    processLock.lock()
    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else {
        processLock.unlock()
        throw DistributedWorkerError.storeUnavailable
      }
    }
  }

  func release() {
    _ = flock(descriptor, LOCK_UN)
    processLock.unlock()
  }
}

/// Coordinates schema initialization for every subsystem that shares a runtime
/// SQLite database, including callers in other Riela package modules.
public enum RuntimeDatabaseAccess {
  public static func withSchemaLock<T>(rootDirectory: String, _ body: () throws -> T) throws -> T {
    let lock = try DistributedStoreLock(
      url: URL(fileURLWithPath: rootDirectory, isDirectory: true).appendingPathComponent(".riela/runtime-schema.lock")
    )
    try lock.acquire()
    defer { lock.release() }
    return try body()
  }
}

private final class DistributedStoreProcessLockRegistry: @unchecked Sendable {
  static let shared = DistributedStoreProcessLockRegistry()

  private let registryLock = NSLock()
  private var locks: [String: NSRecursiveLock] = [:]

  func lock(for path: String) -> NSRecursiveLock {
    registryLock.lock()
    defer { registryLock.unlock() }
    if let lock = locks[path] { return lock }
    let lock = NSRecursiveLock()
    locks[path] = lock
    return lock
  }
}
