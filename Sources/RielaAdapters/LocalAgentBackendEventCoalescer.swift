import Foundation
import RielaCore

final class BackendEventCoalescer: @unchecked Sendable {
  typealias TimerCancellation = @Sendable () -> Void
  typealias TimerScheduler = @Sendable (
    _ delay: TimeInterval,
    _ action: @escaping @Sendable () -> Void
  ) -> TimerCancellation

  private struct PendingKey: Equatable {
    var provider: String
    var eventType: String
    var channel: AdapterBackendEventChannel?
  }

  private let lock = NSLock()
  private let byteThreshold = 256
  private let timeThreshold: TimeInterval
  private let timerScheduler: TimerScheduler
  private var pending: AdapterBackendEvent?
  private var pendingKey: PendingKey?
  private var timerCancellation: TimerCancellation?
  private var timerGeneration = 0
  private var isFinished = false

  init(
    timeThreshold: TimeInterval = 0.25,
    timerScheduler: @escaping TimerScheduler = BackendEventCoalescer.scheduleTimer
  ) {
    self.timeThreshold = timeThreshold
    self.timerScheduler = timerScheduler
  }

  func absorb(
    _ event: AdapterBackendEvent,
    yield: @escaping @Sendable (AdapterBackendEvent) -> Void
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard !isFinished else {
      return
    }

    guard event.isDelta, let delta = event.contentDelta, event.channel != nil else {
      flushLocked(yield: yield)
      yield(event)
      return
    }

    let key = PendingKey(provider: event.provider, eventType: event.eventType, channel: event.channel)
    guard var current = pending, pendingKey == key else {
      flushLocked(yield: yield)
      pending = event
      pendingKey = key
      if delta.utf8.count >= byteThreshold {
        flushLocked(yield: yield)
      } else {
        scheduleTimerLocked(yield: yield)
      }
      return
    }

    current.contentDelta = (current.contentDelta ?? "") + delta
    pending = current
    if (current.contentDelta ?? "").utf8.count >= byteThreshold {
      flushLocked(yield: yield)
    }
  }

  func finish(yield: @escaping @Sendable (AdapterBackendEvent) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    guard !isFinished else {
      return
    }
    isFinished = true
    flushLocked(yield: yield)
  }

  private func scheduleTimerLocked(yield: @escaping @Sendable (AdapterBackendEvent) -> Void) {
    timerGeneration += 1
    let generation = timerGeneration
    timerCancellation = timerScheduler(timeThreshold) { [weak self] in
      self?.timerFired(generation: generation, yield: yield)
    }
  }

  private func timerFired(
    generation: Int,
    yield: @escaping @Sendable (AdapterBackendEvent) -> Void
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard !isFinished, generation == timerGeneration else {
      return
    }
    flushLocked(yield: yield)
  }

  private func flushLocked(yield: @escaping @Sendable (AdapterBackendEvent) -> Void) {
    timerCancellation?()
    timerCancellation = nil
    timerGeneration += 1
    guard let event = pending else {
      return
    }
    pending = nil
    pendingKey = nil
    yield(event)
  }

  private static func scheduleTimer(
    delay: TimeInterval,
    action: @escaping @Sendable () -> Void
  ) -> TimerCancellation {
    let task = Task {
      do {
        try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
      } catch {
        return
      }
      guard !Task.isCancelled else {
        return
      }
      action()
    }
    return { task.cancel() }
  }
}
