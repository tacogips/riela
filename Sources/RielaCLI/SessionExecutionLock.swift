import Foundation
import RielaCore
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

  /// Releases a lock this registry holds. Used when a reserved session id
  /// turns out to be persisted already, so a stale reservation never blocks
  /// another process from resuming that session.
  func release(sessionId: String) {
    mutex.lock()
    defer { mutex.unlock() }
    heldLocks[sessionId] = nil
  }

  func holds(sessionId: String) -> Bool {
    mutex.lock()
    defer { mutex.unlock() }
    return heldLocks[sessionId] != nil
  }
}

func makeSessionExecutionAdmission(
  sessionStoreRoot: String
) -> @Sendable (String) throws -> Void {
  makeSessionExecutionAdmission(registry: SessionExecutionLockRegistry(sessionStoreRoot: sessionStoreRoot))
}

func makeSessionExecutionAdmission(
  registry: SessionExecutionLockRegistry
) -> @Sendable (String) throws -> Void {
  { sessionId in
    try registry.acquire(sessionId: sessionId)
  }
}

/// Generates session ids that are reserved across processes before they are
/// handed to the runtime store. The monotonic counter alone is seeded from a
/// store scan, so two processes starting at the same time compute the same
/// next id; the loser then fails admission after it has already written a
/// durable session record under the winner's id (GitHub #122). Reserving the
/// execution lock for a candidate id at generation time, and skipping
/// candidates that are locked or already persisted, makes concurrent fresh
/// runs of one workflow receive distinct ids.
final class LockReservingWorkflowRuntimeIDGenerator: WorkflowRuntimeIDGenerating, @unchecked Sendable {
  static let maximumReservationAttempts = 10_000

  private let base: MonotonicWorkflowRuntimeIDGenerator
  private let registry: SessionExecutionLockRegistry
  private let persistedSessionExists: @Sendable (String) -> Bool

  init(
    registry: SessionExecutionLockRegistry,
    base: MonotonicWorkflowRuntimeIDGenerator = MonotonicWorkflowRuntimeIDGenerator(),
    persistedSessionExists: @escaping @Sendable (String) -> Bool
  ) {
    self.base = base
    self.registry = registry
    self.persistedSessionExists = persistedSessionExists
  }

  func nextSessionId(workflowId: String) throws -> String {
    var lastContended: String?
    for _ in 0..<Self.maximumReservationAttempts {
      let candidate = try base.nextSessionId(workflowId: workflowId)
      do {
        try registry.acquire(sessionId: candidate)
      } catch SessionExecutionLockError.alreadyRunning {
        lastContended = candidate
        continue
      }
      // A finished run can persist this id between our store scan and the
      // lock acquisition; its lock is gone but the record exists.
      if persistedSessionExists(candidate) {
        registry.release(sessionId: candidate)
        lastContended = candidate
        continue
      }
      return candidate
    }
    throw SessionExecutionLockError.unavailable(
      "could not reserve a unique session id for workflow '\(workflowId)'"
        + (lastContended.map { " (last contended: \($0))" } ?? "")
    )
  }

  func nextStepExecutionId(stepId: String, attempt: Int) throws -> String {
    try base.nextStepExecutionId(stepId: stepId, attempt: attempt)
  }

  func nextCommunicationId() throws -> String {
    try base.nextCommunicationId()
  }

  func noteExistingSessionId(_ sessionId: String, workflowId: String) {
    base.noteExistingSessionId(sessionId, workflowId: workflowId)
  }

  func noteExistingStepExecutionId(_ executionId: String) {
    base.noteExistingStepExecutionId(executionId)
  }

  func noteExistingCommunicationId(_ communicationId: String) {
    base.noteExistingCommunicationId(communicationId)
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
