import Foundation
import RielaNote

/// Drives the periodic recovery+retry maintenance tick for app-side note
/// services. Each tick reclaims dispatch leases older than `leaseStaleness`
/// and retries the pending rows, awaiting the fired dispatches. Lives in
/// `RielaNoteDispatch` (AppKit-free) so window controllers only start/stop it.
public actor NoteAutoActionMaintenanceTicker {
  private let service: NoteService
  private let interval: TimeInterval
  private let leaseStaleness: TimeInterval
  private let retryLimit: Int
  private var loop: Task<Void, Never>?

  public init(
    service: NoteService,
    interval: TimeInterval = 5 * 60,
    leaseStaleness: TimeInterval = defaultAutoActionDispatchLeaseStaleness,
    retryLimit: Int = 50
  ) {
    self.service = service
    self.interval = interval
    self.leaseStaleness = leaseStaleness
    self.retryLimit = retryLimit
  }

  /// Runs one recovery+retry pass and returns the number of dispatches retried.
  /// Exposed for the app to run an immediate pass and for tests to drive the
  /// tick without waiting on the timer.
  @discardableResult
  public func runOnce() async -> Int {
    (try? await service.recoverAndRetryAutoActionDispatches(
      olderThan: leaseStaleness,
      limit: retryLimit
    )) ?? 0
  }

  /// Starts the background loop. Idempotent: a running loop is left untouched.
  public func start() {
    guard loop == nil else {
      return
    }
    let intervalNanos = UInt64(max(interval, 0) * 1_000_000_000)
    loop = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else {
          return
        }
        await self.runOnce()
        if intervalNanos > 0 {
          try? await Task.sleep(nanoseconds: intervalNanos)
        } else {
          return
        }
      }
    }
  }

  public func stop() {
    loop?.cancel()
    loop = nil
  }
}
