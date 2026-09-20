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

  init(url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw DistributedWorkerError.storeUnavailable }
  }

  deinit { close(descriptor) }

  func acquire() throws {
    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else { throw DistributedWorkerError.storeUnavailable }
    }
  }

  func release() { _ = flock(descriptor, LOCK_UN) }
}
