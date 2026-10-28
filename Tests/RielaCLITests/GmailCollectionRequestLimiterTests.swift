import Foundation
import XCTest
@testable import RielaCLI

final class GmailCollectionRequestLimiterTests: XCTestCase {
  func testFirstAcquireDoesNotWait() async throws {
    let state = LimiterTestState()
    let limiter = makeLimiter(interval: 2.5, state: state)

    try await limiter.acquire()

    XCTAssertEqual(state.waits, [])
    let grantedCount = await limiter.grantedCount
    XCTAssertEqual(grantedCount, 1)
  }

  func testFrozenClockWaitsForIncreasingSlotOffsets() async throws {
    let state = LimiterTestState()
    let limiter = makeLimiter(interval: 2.5, state: state)

    for _ in 0..<4 { try await limiter.acquire() }

    XCTAssertEqual(state.waits, [2.5, 5.0, 7.5])
    let grantedCount = await limiter.grantedCount
    XCTAssertEqual(grantedCount, 4)
  }

  func testWaitThatAdvancesClockUsesOneIntervalPerGrant() async throws {
    let state = LimiterTestState(advancesDuringWait: true)
    let limiter = makeLimiter(interval: 2.5, state: state)

    for _ in 0..<4 { try await limiter.acquire() }

    XCTAssertEqual(state.waits, [2.5, 2.5, 2.5])
    let grantedCount = await limiter.grantedCount
    XCTAssertEqual(grantedCount, 4)
  }

  func testClockCatchUpAvoidsWaitingAfterAnIdlePeriod() async throws {
    let state = LimiterTestState()
    let limiter = makeLimiter(interval: 2.5, state: state)
    try await limiter.acquire()
    state.advance(by: 10)

    try await limiter.acquire()

    XCTAssertEqual(state.waits, [])
    let grantedCount = await limiter.grantedCount
    XCTAssertEqual(grantedCount, 2)
  }

  func testConcurrentAcquiresReserveDistinctSlots() async throws {
    let state = LimiterTestState()
    let limiter = makeLimiter(interval: 1, state: state)

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<8 { group.addTask { try await limiter.acquire() } }
      try await group.waitForAll()
    }

    XCTAssertEqual(state.waits.sorted(), Array(1...7).map(Double.init))
    let grantedCount = await limiter.grantedCount
    XCTAssertEqual(grantedCount, 8)
  }

  func testZeroIntervalNeverWaits() async throws {
    let state = LimiterTestState()
    let limiter = makeLimiter(interval: 0, state: state)

    for _ in 0..<5 { try await limiter.acquire() }

    XCTAssertEqual(state.waits, [])
    let grantedCount = await limiter.grantedCount
    XCTAssertEqual(grantedCount, 5)
  }

  func testDeadlineAtNowRefusesWithoutReservingOrWaiting() async {
    let state = LimiterTestState()
    let now = state.now
    let limiter = makeLimiter(interval: 2.5, deadline: now, state: state)

    do {
      try await limiter.acquire()
      XCTFail("Expected deadline refusal")
    } catch is GmailCollectionDeadlineRefusal {
      let grantedCount = await limiter.grantedCount
      XCTAssertEqual(grantedCount, 0)
      XCTAssertEqual(state.waits, [])
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testDeadlineRefusesSlotAtOrAfterCutoff() async throws {
    let state = LimiterTestState()
    let limiter = makeLimiter(interval: 2.5, deadline: state.now.addingTimeInterval(7), state: state)

    try await limiter.acquire()
    try await limiter.acquire()
    do {
      try await limiter.acquire()
      XCTFail("Expected deadline refusal")
    } catch is GmailCollectionDeadlineRefusal {
      let grantedCount = await limiter.grantedCount
      XCTAssertEqual(grantedCount, 2)
      XCTAssertEqual(state.waits, [2.5])
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testSlotTooCloseToDeadlineIsRefusedBeforeChildTimeout() async {
    let state = LimiterTestState()
    let limiter = makeLimiter(interval: 0, deadline: state.now.addingTimeInterval(3.999), state: state)

    do {
      try await limiter.acquire()
      XCTFail("Expected a slot without the minimum request remainder to be refused")
    } catch is GmailCollectionDeadlineRefusal {
      let grantedCount = await limiter.grantedCount
      XCTAssertEqual(grantedCount, 0)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testPrefetchedGrantOccupiesFirstSlot() async throws {
    let state = LimiterTestState()
    let limiter = makeLimiter(interval: 2.5, state: state)
    await limiter.recordPrefetchedGrant()

    try await limiter.acquire()

    XCTAssertEqual(state.waits, [2.5])
    let grantedCount = await limiter.grantedCount
    XCTAssertEqual(grantedCount, 2)
  }

  func testPreCancelledTaskDoesNotReserveSlot() async {
    let state = LimiterTestState()
    let limiter = makeLimiter(interval: 2.5, state: state)
    let task = Task { try await limiter.acquire() }
    task.cancel()

    do {
      try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      let grantedCount = await limiter.grantedCount
      XCTAssertEqual(grantedCount, 0)
      XCTAssertEqual(state.waits, [])
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func makeLimiter(
    interval: Double,
    deadline: Date? = nil,
    state: LimiterTestState
  ) -> GmailCollectionRequestLimiter {
    GmailCollectionRequestLimiter(
      interval: interval,
      deadline: deadline,
      clock: { state.now },
      wait: { state.wait($0) }
    )
  }
}

private final class LimiterTestState: @unchecked Sendable {
  private let lock = NSLock()
  private var instant = Date(timeIntervalSince1970: 1_000)
  private var recordedWaits: [Double] = []
  private let advancesDuringWait: Bool

  init(advancesDuringWait: Bool = false) {
    self.advancesDuringWait = advancesDuringWait
  }

  var now: Date { lock.withLock { instant } }
  var waits: [Double] { lock.withLock { recordedWaits } }

  func advance(by seconds: Double) {
    lock.withLock { instant.addTimeInterval(seconds) }
  }

  func wait(_ seconds: Double) {
    lock.withLock {
      recordedWaits.append(seconds)
      if advancesDuringWait { instant.addTimeInterval(seconds) }
    }
  }
}
