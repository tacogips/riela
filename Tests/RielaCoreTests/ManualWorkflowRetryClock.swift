import Foundation
import RielaCore

final class ManualWorkflowRetryClock: WorkflowRetryClock, @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date
  private var sleepers: [UUID: (Date, CheckedContinuation<Void, any Error>)] = [:]
  private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

  init(now: Date = Date(timeIntervalSince1970: 0)) { current = now }

  func now() -> Date { lock.withLock { current } }

  func sleep(until: Date) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        lock.lock()
        if Task.isCancelled {
          lock.unlock()
          continuation.resume(throwing: CancellationError())
        } else if until <= current {
          lock.unlock()
          continuation.resume()
        } else {
          sleepers[id] = (until, continuation)
          let ready = observers.filter { sleepers.count >= $0.0 }
          observers.removeAll { sleepers.count >= $0.0 }
          lock.unlock()
          ready.forEach { $0.1.resume() }
        }
      }
    } onCancel: {
      let sleeper = self.lock.withLock { self.sleepers.removeValue(forKey: id) }
      sleeper?.1.resume(throwing: CancellationError())
    }
  }

  func advance(to date: Date) {
    lock.lock()
    current = max(current, date)
    let ready = sleepers.filter { $0.value.0 <= current }
    for id in ready.keys { sleepers.removeValue(forKey: id) }
    lock.unlock()
    ready.values.forEach { $0.1.resume() }
  }

  func advance(by interval: TimeInterval) { advance(to: now().addingTimeInterval(interval)) }
  func advance(byMs milliseconds: Int) { advance(by: Double(milliseconds) / 1_000) }

  func waitForSleepers(count: Int) async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if sleepers.count >= count {
        lock.unlock()
        continuation.resume()
      } else {
        observers.append((count, continuation))
        lock.unlock()
      }
    }
  }
}
