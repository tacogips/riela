import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private let maxSocketPathBytes = 103

public enum RielaAppOwnerLockError: Error, Equatable {
  case insecure
  case io(Int32)
}

public struct RielaAppRunDirectory: Sendable {
  public let directoryURL: URL
  public var lockURL: URL { directoryURL.appendingPathComponent("app.lock") }
  public var socketURL: URL { directoryURL.appendingPathComponent("control.sock") }
  public var socketPathFits: Bool { socketURL.path.utf8.count <= maxSocketPathBytes }

  public init(appRoot: URL) {
    directoryURL = appRoot.appendingPathComponent("run", isDirectory: true)
  }

  public func prepare() throws {
    do {
      try FileManager.default.createDirectory(at: directoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      if mkdir(directoryURL.path, 0o700) != 0 && errno != EEXIST {
        throw RielaAppOwnerLockError.io(errno)
      }
      try validate()
    } catch let error as RielaAppOwnerLockError {
      throw error
    } catch {
      throw RielaAppOwnerLockError.io(Int32((error as NSError).code))
    }
  }

  public func validate() throws {
    var info = stat()
    guard lstat(directoryURL.path, &info) == 0 else { throw RielaAppOwnerLockError.io(errno) }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid(),
          info.st_mode & 0o077 == 0 else { throw RielaAppOwnerLockError.insecure }
  }

  public func validateSocketFile() throws {
    var info = stat()
    guard lstat(socketURL.path, &info) == 0 else {
      if errno == ENOENT { return }
      throw RielaAppOwnerLockError.io(errno)
    }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK), info.st_uid == geteuid(),
          info.st_mode & 0o177 == 0 else { throw RielaAppOwnerLockError.insecure }
  }
}

public final class RielaAppOwnerLock: @unchecked Sendable {
  private let mutex = NSLock()
  private var descriptor: Int32

  private init(descriptor: Int32) { self.descriptor = descriptor }

  public static func tryAcquire(_ run: RielaAppRunDirectory) throws -> RielaAppOwnerLock? {
    try acquire(run, nonblocking: true)
  }

  /// Blocks until ownership is available. Call only from a non-main thread.
  public static func acquireBlocking(_ run: RielaAppRunDirectory) throws -> RielaAppOwnerLock {
    guard let lock = try acquire(run, nonblocking: false) else { throw RielaAppOwnerLockError.io(EWOULDBLOCK) }
    return lock
  }

  private static func acquire(_ run: RielaAppRunDirectory, nonblocking: Bool) throws -> RielaAppOwnerLock? {
    try run.validate()
    let descriptor = open(run.lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw RielaAppOwnerLockError.io(errno) }
    while flock(descriptor, LOCK_EX | (nonblocking ? LOCK_NB : 0)) != 0 {
      let code = errno
      if code == EINTR { continue }
      close(descriptor)
      if nonblocking && code == EWOULDBLOCK { return nil }
      throw RielaAppOwnerLockError.io(code)
    }
    return RielaAppOwnerLock(descriptor: descriptor)
  }

  public func release() {
    mutex.lock()
    defer { mutex.unlock() }
    guard descriptor >= 0 else { return }
    _ = flock(descriptor, LOCK_UN)
    close(descriptor)
    descriptor = -1
  }

  func whileOwned(_ body: () -> Void) {
    mutex.lock()
    defer { mutex.unlock() }
    guard descriptor >= 0 else { return }
    body()
  }

  deinit { release() }
}
