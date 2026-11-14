import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Serializes local controller and workflow processes. This is not a network
/// filesystem lock: workers never open the controller store.
final class DistributedStoreLock {
  private let path: String
  private let shared: DistributedStoreSharedLock
  private var acquiredDepth = 0

  init(url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    path = url.standardizedFileURL.path
    shared = try DistributedStoreProcessLockRegistry.shared.acquire(path: path, lockPath: url.path)
  }

  deinit { DistributedStoreProcessLockRegistry.shared.release(path: path, shared: shared) }

  func acquire() throws {
    shared.processLock.lock()
    if shared.flockDepth > 0 {
      shared.flockDepth += 1
      acquiredDepth += 1
      return
    }
    while flock(shared.descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else {
        shared.processLock.unlock()
        throw DistributedWorkerError.storeUnavailable
      }
    }
    shared.flockDepth = 1
    acquiredDepth += 1
  }

  func release() {
    guard acquiredDepth > 0 else { return }
    acquiredDepth -= 1
    shared.flockDepth -= 1
    if shared.flockDepth == 0 {
      _ = flock(shared.descriptor, LOCK_UN)
    }
    shared.processLock.unlock()
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

  /// Avoids the initialization lock for established read-only databases while
  /// keeping readers behind an in-progress first creation.
  public static func withSchemaLockIfUninitialized<T>(
    rootDirectory: String,
    databasePath: String,
    _ body: () throws -> T
  ) throws -> T {
    let size = (try? FileManager.default.attributesOfItem(atPath: databasePath)[.size] as? NSNumber)?.int64Value
    guard size == nil || size == 0 else { return try body() }
    return try withSchemaLock(rootDirectory: rootDirectory, body)
  }
}

private final class DistributedStoreSharedLock {
  let descriptor: Int32
  let processLock = NSRecursiveLock()
  var users = 0
  var flockDepth = 0

  init(lockPath: String) throws {
    descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw DistributedWorkerError.storeUnavailable }
  }

  deinit { close(descriptor) }
}

private final class DistributedStoreProcessLockRegistry: @unchecked Sendable {
  static let shared = DistributedStoreProcessLockRegistry()

  private let registryLock = NSLock()
  private var locks: [String: DistributedStoreSharedLock] = [:]

  func acquire(path: String, lockPath: String) throws -> DistributedStoreSharedLock {
    registryLock.lock()
    defer { registryLock.unlock() }
    if let lock = locks[path] {
      lock.users += 1
      return lock
    }
    let lock = try DistributedStoreSharedLock(lockPath: lockPath)
    lock.users = 1
    locks[path] = lock
    return lock
  }

  func release(path: String, shared: DistributedStoreSharedLock) {
    registryLock.lock()
    defer { registryLock.unlock() }
    shared.users -= 1
    if shared.users == 0 { locks.removeValue(forKey: path) }
  }
}
