import Dispatch
import Foundation

public protocol WallClockDeadlineScheduling: Sendable {
  func now() -> Date
  func schedule(at deadline: Date, on queue: DispatchQueue, _ work: DispatchWorkItem)
}

public struct SystemWallClockDeadlineScheduler: WallClockDeadlineScheduling {
  public init() {}
  public func now() -> Date { Date() }
  public func schedule(at deadline: Date, on queue: DispatchQueue, _ work: DispatchWorkItem) {
    queue.asyncAfter(wallDeadline: dispatchWallTime(for: deadline), execute: work)
  }
}

public func dispatchWallTime(for date: Date) -> DispatchWallTime {
  let interval = max(0, date.timeIntervalSince1970)
  let seconds = floor(interval)
  let nanoseconds = min(999_999_999, max(0, Int((interval - seconds) * 1_000_000_000)))
  return DispatchWallTime(timespec: timespec(tv_sec: Int(seconds), tv_nsec: nanoseconds))
}

private final class WallClockSleepState: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, any Error>?
  private var work: DispatchWorkItem?
  private var finished = false

  func install(_ continuation: CheckedContinuation<Void, any Error>, scheduler: any WallClockDeadlineScheduling, deadline: Date) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    self.continuation = continuation
    let item = DispatchWorkItem { [self] in finish(cancelled: false) }
    work = item
    scheduler.schedule(at: deadline, on: .global(qos: .utility), item)
    lock.unlock()
  }

  func finish(cancelled: Bool) {
    lock.lock()
    guard !finished else { lock.unlock(); return }
    finished = true
    let continuation = self.continuation
    let item = work
    self.continuation = nil
    work = nil
    lock.unlock()
    if cancelled { item?.cancel(); continuation?.resume(throwing: CancellationError()) } else { continuation?.resume() }
  }
}

public func wallClockSleep(
  until deadline: Date, scheduler: any WallClockDeadlineScheduling = SystemWallClockDeadlineScheduler()
) async throws {
  try Task.checkCancellation()
  guard deadline > scheduler.now() else { return }
  let state = WallClockSleepState()
  try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      state.install(continuation, scheduler: scheduler, deadline: deadline)
    }
  } onCancel: {
    state.finish(cancelled: true)
  }
}
