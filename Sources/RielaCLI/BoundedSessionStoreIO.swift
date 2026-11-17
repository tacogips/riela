import Foundation

/// Runs potentially blocking session-store filesystem/SQLite work away from the
/// caller's executor with an upper bound on how long the caller waits.
///
/// An `open(2)` on an unavailable or permission-gated volume (for example a
/// removable APFS disk awaiting TCC approval, or a stalled external disk) can
/// block in the kernel indefinitely and cannot be cancelled. The work therefore
/// runs on its own thread; when the deadline passes the caller receives
/// `.timedOut` and the stuck thread is abandoned. While an abandoned operation
/// for the same store is still blocked, further calls fail fast with
/// `.storeBusy` instead of piling up more blocked threads.
public enum BoundedSessionStoreIO {
  public enum Outcome<Value: Sendable>: Sendable {
    case completed(Result<Value, any Error>)
    case timedOut
    case storeBusy
  }

  public static let defaultTimeout: TimeInterval = 10

  /// The serialization key for a session store (its canonical runtime root).
  public static func key(sessionStoreRoot: String) -> String {
    canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot)
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var blockedKeys: Set<String> = []

  public static func isBlocked(key: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return blockedKeys.contains(key)
  }

  public struct Unavailable: Error, Equatable, Sendable {
    public let timedOut: Bool
  }

  /// Synchronous variant for callers that are not async (still bounded): the
  /// caller blocks at most `timeout`, never on the stuck `open(2)` itself.
  public static func runBlocking<Value: Sendable>(
    key: String,
    timeout: TimeInterval = defaultTimeout,
    _ work: @escaping @Sendable () throws -> Value
  ) throws -> Value {
    if isBlocked(key: key) { throw Unavailable(timedOut: false) }
    let box = BlockingOutcomeBox<Value>()
    let semaphore = DispatchSemaphore(value: 0)
    let thread = Thread {
      box.set(.completed(Result { try work() }))
      semaphore.signal()
      if box.abandoned {
        lock.lock()
        blockedKeys.remove(key)
        lock.unlock()
      }
    }
    thread.name = "riela.session-store-io"
    thread.start()
    if semaphore.wait(timeout: .now() + max(0, timeout)) == .timedOut {
      lock.lock()
      if box.markAbandonedIfPending() { blockedKeys.insert(key) }
      lock.unlock()
      if case let .completed(result)? = box.get() { return try result.get() }
      throw Unavailable(timedOut: true)
    }
    if case let .completed(result)? = box.get() { return try result.get() }
    throw Unavailable(timedOut: false)
  }

  public static func run<Value: Sendable>(
    key: String,
    timeout: TimeInterval = defaultTimeout,
    _ work: @escaping @Sendable () throws -> Value
  ) async -> Outcome<Value> {
    if isBlocked(key: key) { return .storeBusy }
    let state = BoundedIOState<Value>()
    return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<Value>, Never>) in
      state.install(continuation)
      let thread = Thread {
        let result = Result { try work() }
        if !state.resume(.completed(result)) {
          // The caller already gave up; the store is usable again.
          lock.lock()
          blockedKeys.remove(key)
          lock.unlock()
        }
      }
      thread.name = "riela.session-store-io"
      thread.start()
      DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout)) {
        lock.lock()
        let marked = state.isPending
        if marked { blockedKeys.insert(key) }
        lock.unlock()
        if marked, !state.resume(.timedOut) {
          lock.lock()
          blockedKeys.remove(key)
          lock.unlock()
        }
      }
    }
  }
}

private final class BoundedIOState<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<BoundedSessionStoreIO.Outcome<Value>, Never>?
  private var finished = false

  func install(_ continuation: CheckedContinuation<BoundedSessionStoreIO.Outcome<Value>, Never>) {
    lock.lock()
    self.continuation = continuation
    lock.unlock()
  }

  var isPending: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !finished
  }

  /// Returns true when this call delivered the outcome.
  @discardableResult
  func resume(_ outcome: BoundedSessionStoreIO.Outcome<Value>) -> Bool {
    lock.lock()
    guard !finished, let continuation else {
      lock.unlock()
      return false
    }
    finished = true
    self.continuation = nil
    lock.unlock()
    continuation.resume(returning: outcome)
    return true
  }
}

private final class BlockingOutcomeBox<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var outcome: BoundedSessionStoreIO.Outcome<Value>?
  private var isAbandoned = false
  func set(_ value: BoundedSessionStoreIO.Outcome<Value>) { lock.lock(); outcome = value; lock.unlock() }
  func get() -> BoundedSessionStoreIO.Outcome<Value>? { lock.lock(); defer { lock.unlock() }; return outcome }
  var abandoned: Bool { lock.lock(); defer { lock.unlock() }; return isAbandoned }
  /// Marks the work abandoned when it has not produced a result yet.
  func markAbandonedIfPending() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard outcome == nil else { return false }
    isAbandoned = true
    return true
  }
}
