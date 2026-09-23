import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum SessionExecutionLockError: Error, CustomStringConvertible, Equatable {
  case invalidSessionId(String)
  case unavailable(String)
  case alreadyRunning(String)

  var description: String {
    switch self {
    case let .invalidSessionId(sessionId):
      "invalid session id for execution lock: \(sessionId)"
    case let .unavailable(message):
      "session execution lock unavailable: \(message)"
    case let .alreadyRunning(sessionId):
      "session '\(sessionId)' is already owned by another live execution"
    }
  }
}

/// Owns process-scoped, per-session advisory locks. The kernel releases each
/// lock if the process exits, so crash recovery does not depend on a timeout.
final class SessionExecutionLockRegistry: @unchecked Sendable {
  private let lockRoot: URL
  private let mutex = NSLock()
  private var heldLocks: [String: SessionExecutionLock] = [:]

  init(sessionStoreRoot: String) {
    lockRoot = URL(fileURLWithPath: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot), isDirectory: true)
      .appendingPathComponent("execution-locks", isDirectory: true)
  }

  func acquire(sessionId: String) throws {
    guard sessionId.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression) != nil else {
      throw SessionExecutionLockError.invalidSessionId(sessionId)
    }
    mutex.lock()
    defer { mutex.unlock() }
    guard heldLocks[sessionId] == nil else {
      return
    }
    heldLocks[sessionId] = try SessionExecutionLock(
      url: lockRoot.appendingPathComponent(sessionId).appendingPathExtension("lock"),
      sessionId: sessionId
    )
  }
}

func makeSessionExecutionAdmission(
  sessionStoreRoot: String
) -> @Sendable (String) throws -> Void {
  let registry = SessionExecutionLockRegistry(sessionStoreRoot: sessionStoreRoot)
  return { sessionId in
    try registry.acquire(sessionId: sessionId)
  }
}

private final class SessionExecutionLock {
  private let descriptor: Int32

  init(url: URL, sessionId: String) throws {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    } catch {
      throw SessionExecutionLockError.unavailable(error.localizedDescription)
    }
    let openedDescriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard openedDescriptor >= 0 else {
      throw SessionExecutionLockError.unavailable(String(cString: strerror(errno)))
    }
    while flock(openedDescriptor, LOCK_EX | LOCK_NB) != 0 {
      if errno == EINTR {
        continue
      }
      let lockError = errno
      close(openedDescriptor)
      if lockError == EWOULDBLOCK || lockError == EAGAIN {
        throw SessionExecutionLockError.alreadyRunning(sessionId)
      }
      throw SessionExecutionLockError.unavailable(String(cString: strerror(lockError)))
    }
    descriptor = openedDescriptor
  }

  deinit {
    _ = flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}
