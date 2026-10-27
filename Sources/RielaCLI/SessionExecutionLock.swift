import Foundation
import RielaCore
import RielaSQLite
#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum SessionExecutionLockError: Error, CustomStringConvertible, Equatable {
  case invalidSessionId(String)
  case unavailable(String)
  case alreadyRunning(String)
  case retiredSession(String)
  case messagesRetired(String)

  var description: String {
    switch self {
    case let .invalidSessionId(sessionId):
      "invalid session id for execution lock: \(sessionId)"
    case let .unavailable(message):
      "session execution lock unavailable: \(message)"
    case let .alreadyRunning(sessionId):
      "session '\(sessionId)' is already owned by another live execution"
    case let .retiredSession(sessionId):
      "session '\(sessionId)' payloads have expired under terminal retention"
    case let .messagesRetired(sessionId):
      "session '\(sessionId)' workflow messages expired under retention"
    }
  }
}

/// Owns process-scoped, per-session advisory locks. The kernel releases each
/// lock if the process exits, so crash recovery does not depend on a timeout.
final class SessionExecutionLockRegistry: @unchecked Sendable {
  private let lockRoot: URL
  private let databasePath: String
  private let beforeLockVerify: () -> Void
  private let mutex = NSLock()
  private var heldLocks: [String: SessionExecutionLock] = [:]

  init(sessionStoreRoot: String, beforeVerify: @escaping () -> Void = {}) {
    databasePath = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: sessionStoreRoot)
    lockRoot = URL(fileURLWithPath: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot), isDirectory: true)
      .appendingPathComponent("execution-locks", isDirectory: true)
    beforeLockVerify = beforeVerify
  }

  func acquire(sessionId: String, allowRetired: Bool = false, allowMessagesRetired: Bool = false) throws {
    guard sessionId.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression) != nil else {
      throw SessionExecutionLockError.invalidSessionId(sessionId)
    }
    mutex.lock()
    defer { mutex.unlock() }
    guard heldLocks[sessionId] == nil else {
      return
    }
    let acquired = try SessionExecutionLock(
      url: lockRoot.appendingPathComponent(sessionId).appendingPathExtension("lock"),
      sessionId: sessionId,
      beforeVerify: beforeLockVerify
    )
    if !allowRetired, FileManager.default.fileExists(atPath: databasePath) {
      let runtimeRoot = lockRoot.deletingLastPathComponent().path
      let db = try RuntimeDatabaseAccess.withSchemaLockIfUninitialized(
        rootDirectory: runtimeRoot, databasePath: databasePath
      ) {
        try SQLiteDatabase.open(path: databasePath, mode: .strictReadOnly, options: .readOnlyDefault)
      }
      if try db.tableExists("session_retention_tombstones"),
         try !db.query("SELECT 1 FROM session_retention_tombstones WHERE session_id=? LIMIT 1",
          bindings: [.text(sessionId)]).isEmpty {
        throw SessionExecutionLockError.retiredSession(sessionId)
      }
      if !allowMessagesRetired, try db.tableExists("session_message_retention_tombstones"),
         try !db.query("SELECT 1 FROM session_message_retention_tombstones WHERE session_id=? LIMIT 1",
          bindings: [.text(sessionId)]).isEmpty {
        throw SessionExecutionLockError.messagesRetired(sessionId)
      }
    }
    heldLocks[sessionId] = acquired
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

  func sessionMessagesRetired(sessionId: String) throws -> Bool {
    guard FileManager.default.fileExists(atPath: databasePath) else { return false }
    let db = try SQLiteDatabase.open(path: databasePath, mode: .strictReadOnly, options: .readOnlyDefault)
    guard try db.tableExists("session_message_retention_tombstones") else { return false }
    return try !db.query("SELECT 1 FROM session_message_retention_tombstones WHERE session_id=? LIMIT 1",
      bindings: [.text(sessionId)]).isEmpty
  }

  struct OrphanLockRemovalResult: Codable, Equatable, Sendable {
    var selectedCount: Int
    var removedCount: Int
    var skippedBusy: Int
  }

  func removeOrphanLocks(
    limit: Int = 2000,
    dryRun: Bool,
    sessionExists: @escaping (String) throws -> Bool
  ) -> OrphanLockRemovalResult {
    guard limit > 0,
          let entries = try? FileManager.default.contentsOfDirectory(
            at: lockRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
          ) else {
      return .init(selectedCount: 0, removedCount: 0, skippedBusy: 0)
    }
    let candidates = Array(entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.lazy.compactMap { url -> (String, URL)? in
      let filename = url.lastPathComponent
      guard filename.hasSuffix(".lock") else { return nil }
      let sessionId = String(filename.dropLast(".lock".count))
      guard sessionId.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression) != nil else {
        return nil
      }
      var info = stat()
      guard lstat(url.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
            !self.isHeld(sessionId), (try? sessionExists(sessionId)) == false else { return nil }
      return (sessionId, url)
    }.prefix(limit))
    var result = OrphanLockRemovalResult(selectedCount: candidates.count, removedCount: 0, skippedBusy: 0)
    guard !dryRun else { return result }
    for (sessionId, url) in candidates {
      let descriptor = open(url.path, O_RDWR | O_CLOEXEC)
      guard descriptor >= 0 else { continue }
      defer { close(descriptor) }
      var locked = false
      while true {
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
          locked = true
          break
        }
        if errno == EINTR { continue }
        if errno == EWOULDBLOCK || errno == EAGAIN { result.skippedBusy += 1 }
        break
      }
      guard locked else { continue }
      guard (try? sessionExists(sessionId)) == false else {
        _ = flock(descriptor, LOCK_UN)
        continue
      }
      var descriptorInfo = stat()
      var pathInfo = stat()
      guard fstat(descriptor, &descriptorInfo) == 0, lstat(url.path, &pathInfo) == 0,
            descriptorInfo.st_dev == pathInfo.st_dev, descriptorInfo.st_ino == pathInfo.st_ino,
            unlink(url.path) == 0 else {
        _ = flock(descriptor, LOCK_UN)
        continue
      }
      _ = flock(descriptor, LOCK_UN)
      result.removedCount += 1
    }
    return result
  }

  private func isHeld(_ sessionId: String) -> Bool {
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
      } catch SessionExecutionLockError.retiredSession {
        lastContended = candidate
        continue
      } catch SessionExecutionLockError.messagesRetired {
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

  init(url: URL, sessionId: String, beforeVerify: () -> Void = {}) throws {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    } catch {
      throw SessionExecutionLockError.unavailable(error.localizedDescription)
    }
    for _ in 0..<8 {
      let openedDescriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
      guard openedDescriptor >= 0 else {
        throw SessionExecutionLockError.unavailable(String(cString: strerror(errno)))
      }
      while flock(openedDescriptor, LOCK_EX | LOCK_NB) != 0 {
        if errno == EINTR { continue }
        let lockError = errno
        close(openedDescriptor)
        if lockError == EWOULDBLOCK || lockError == EAGAIN {
          throw SessionExecutionLockError.alreadyRunning(sessionId)
        }
        throw SessionExecutionLockError.unavailable(String(cString: strerror(lockError)))
      }
      beforeVerify()
      var descriptorInfo = stat()
      var pathInfo = stat()
      guard fstat(openedDescriptor, &descriptorInfo) == 0 else {
        let verificationError = errno
        _ = flock(openedDescriptor, LOCK_UN)
        close(openedDescriptor)
        throw SessionExecutionLockError.unavailable(String(cString: strerror(verificationError)))
      }
      let pathResult = stat(url.path, &pathInfo)
      if pathResult == 0, descriptorInfo.st_dev == pathInfo.st_dev, descriptorInfo.st_ino == pathInfo.st_ino {
        descriptor = openedDescriptor
        return
      }
      let verificationError = errno
      _ = flock(openedDescriptor, LOCK_UN)
      close(openedDescriptor)
      if pathResult != 0, verificationError != ENOENT {
        throw SessionExecutionLockError.unavailable(String(cString: strerror(verificationError)))
      }
    }
    throw SessionExecutionLockError.unavailable("lock file replaced concurrently")
  }

  deinit {
    _ = flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}
