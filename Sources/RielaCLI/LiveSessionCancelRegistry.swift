import Foundation
import RielaCore
import RielaServer

public final class LiveSessionCancelRegistry: @unchecked Sendable {
  private struct Entry {
    let cancellation: OperatorCancellation
    let cancel: @Sendable () -> Void
  }
  private let lock = NSLock()
  private var inFlight = 0
  private var entries: [String: Entry] = [:]

  public init() {}

  public func beginRun() {
    lock.lock()
    defer { lock.unlock() }
    inFlight += 1
  }

  public func endRun() {
    lock.lock()
    defer { lock.unlock() }
    inFlight = max(0, inFlight - 1)
  }

  public func register(sessionId: String, cancellation: OperatorCancellation, cancel: @escaping @Sendable () -> Void) {
    lock.lock()
    defer { lock.unlock() }
    entries[sessionId] = Entry(cancellation: cancellation, cancel: cancel)
  }

  public func unregister(sessionId: String) {
    lock.lock()
    defer { lock.unlock() }
    entries.removeValue(forKey: sessionId)
  }

  public func requestCancel(sessionId: String, reason: String, actor: String) -> WorkflowServeSessionCancelOutcome {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = entries[sessionId] else { return .notFound }
    guard entry.cancellation.request(reason: reason, actor: actor) else { return .alreadyRequested }
    // Callers must provide a nonblocking closure that only requests Task cancellation.
    entry.cancel()
    return .cancelRequested
  }

  public func liveSnapshot() -> (sessionIds: [String], pendingRunCount: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (entries.keys.sorted(), max(0, inFlight - entries.count))
  }
}
