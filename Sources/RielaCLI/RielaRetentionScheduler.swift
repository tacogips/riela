import Foundation

public final class RielaRetentionScheduler: @unchecked Sendable {
  private let interval: TimeInterval
  private let runImmediately: Bool
  private let sleep: @Sendable (TimeInterval) async throws -> Void
  private let pass: @Sendable () -> Void
  private let passQueue = DispatchQueue(label: "riela.retention", qos: .utility)
  private let lock = NSLock()
  private var task: Task<Void, Never>?

  public init(
    interval: TimeInterval = 300,
    runImmediately: Bool,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
      try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
    },
    pass: @escaping @Sendable () -> Void
  ) {
    self.interval = max(0.001, interval)
    self.runImmediately = runImmediately
    self.sleep = sleep
    self.pass = pass
  }

  public func start() {
    lock.lock()
    defer { lock.unlock() }
    guard task == nil else { return }
    task = Task(priority: .utility) { [weak self] in await self?.runLoop() }
  }

  public func stop() {
    lock.lock()
    let runningTask = task
    task = nil
    lock.unlock()
    runningTask?.cancel()
  }

  // SQLite and filesystem reclamation must not block the cooperative executor.
  private func runPass() async {
    await withCheckedContinuation { continuation in
      passQueue.async { [pass] in
        pass()
        continuation.resume()
      }
    }
  }

  private func runLoop() async {
    if runImmediately, !Task.isCancelled { await runPass() }
    while !Task.isCancelled {
      do { try await sleep(interval) } catch { break }
      guard !Task.isCancelled else { break }
      await runPass()
      do { try await Task.sleep(nanoseconds: 1_000_000) } catch { break }
    }
  }
}
