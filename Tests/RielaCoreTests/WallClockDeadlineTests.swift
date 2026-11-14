import Dispatch
import Foundation
import XCTest
@testable import RielaCore

private final class RecordingWallClockScheduler: WallClockDeadlineScheduling, @unchecked Sendable {
  private let lock = NSLock()
  private let current: Date
  private var entries: [(Date, DispatchWorkItem)] = []
  init(now: Date) { current = now }
  func now() -> Date { current }
  func schedule(at deadline: Date, on queue: DispatchQueue, _ work: DispatchWorkItem) {
    lock.lock(); defer { lock.unlock() }
    entries.append((deadline, work))
  }
  func snapshot() -> [(Date, DispatchWorkItem)] {
    lock.lock(); defer { lock.unlock() }
    return entries
  }
}

private actor CompletionMarker {
  var completed = false
  func mark() { completed = true }
}

final class WallClockDeadlineTests: XCTestCase {
  func testConversionAndEpochClamp() {
    let expected = DispatchWallTime(timespec: timespec(tv_sec: 1_700_000_000, tv_nsec: 250_000_000))
    XCTAssertEqual(dispatchWallTime(for: Date(timeIntervalSince1970: 1_700_000_000.25)).rawValue, expected.rawValue)
    let epoch = DispatchWallTime(timespec: timespec(tv_sec: 0, tv_nsec: 0))
    XCTAssertEqual(dispatchWallTime(for: Date(timeIntervalSince1970: 0)).rawValue, epoch.rawValue)
    XCTAssertEqual(dispatchWallTime(for: Date(timeIntervalSince1970: -1)).rawValue, epoch.rawValue)
  }

  private func waitForSchedule(_ scheduler: RecordingWallClockScheduler) async throws {
    for _ in 0..<1_000 {
      if !scheduler.snapshot().isEmpty { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("scheduler was not called")
  }

  func testAbsoluteDeadlineAndFire() async throws {
    let now = Date()
    let scheduler = RecordingWallClockScheduler(now: now)
    let deadline = now.addingTimeInterval(3_600)
    let marker = CompletionMarker()
    let task = Task {
      try await wallClockSleep(until: deadline, scheduler: scheduler)
      await marker.mark()
    }
    try await waitForSchedule(scheduler)
    let entries = scheduler.snapshot()
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.0, deadline)
    for _ in 0..<10 { await Task.yield() }
    let completedBeforeFire = await marker.completed
    XCTAssertFalse(completedBeforeFire)
    entries.first?.1.perform()
    try await task.value
  }

  func testCancellationCancelsWork() async throws {
    let now = Date()
    let scheduler = RecordingWallClockScheduler(now: now)
    let task = Task { try await wallClockSleep(until: now.addingTimeInterval(3_600), scheduler: scheduler) }
    try await waitForSchedule(scheduler)
    task.cancel()
    do { try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
    XCTAssertTrue(scheduler.snapshot()[0].1.isCancelled)
  }

  func testPastAndPrecancelled() async throws {
    try await wallClockSleep(until: .distantPast)
    let now = Date()
    let scheduler = RecordingWallClockScheduler(now: now)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await wallClockSleep(until: now.addingTimeInterval(3_600), scheduler: scheduler)
    }
    do { try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
    XCTAssertTrue(scheduler.snapshot().isEmpty)
  }

  func testSystemRetryClockPastAndCancellation() async throws {
    let clock = SystemWorkflowRetryClock()
    try await clock.sleep(until: Date().addingTimeInterval(-1))
    let task = Task { try await clock.sleep(until: Date().addingTimeInterval(3_600)) }
    task.cancel()
    do { try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
  }
}
