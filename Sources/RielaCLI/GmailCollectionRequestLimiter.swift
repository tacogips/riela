import Foundation

struct GmailCollectionDeadlineRefusal: Error, Sendable {}

actor GmailCollectionRequestLimiter {
  private static let minimumRequestRemainder: TimeInterval = 4
  private let interval: Double
  private let deadline: Date?
  private let clock: @Sendable () -> Date
  private let wait: @Sendable (Double) async throws -> Void
  private var lastSlot: Date?
  private(set) var grantedCount = 0

  init(
    interval: Double,
    deadline: Date?,
    clock: @escaping @Sendable () -> Date,
    wait: @escaping @Sendable (Double) async throws -> Void
  ) {
    self.interval = interval
    self.deadline = deadline
    self.clock = clock
    self.wait = wait
  }

  func recordPrefetchedGrant() {
    lastSlot = clock()
    grantedCount += 1
  }

  func acquire() async throws {
    try Task.checkCancellation()
    let now = clock()
    let slot = lastSlot.map { max(now, $0.addingTimeInterval(interval)) } ?? now
    if let deadline, slot >= deadline.addingTimeInterval(-Self.minimumRequestRemainder) {
      throw GmailCollectionDeadlineRefusal()
    }

    lastSlot = slot
    grantedCount += 1
    let delay = slot.timeIntervalSince(now)
    if delay > 0 {
      // A cancelled wait still owns its reserved start slot.
      try await wait(delay)
      try Task.checkCancellation()
    }
  }
}
