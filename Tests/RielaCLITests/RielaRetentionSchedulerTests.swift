import Foundation
import XCTest
@testable import RielaCLI

final class RielaRetentionSchedulerTests: XCTestCase {
  func testRunImmediatelyPassesBeforeSleeping() async throws {
    let probe = SchedulerProbe()
    let scheduler = RielaRetentionScheduler(interval: 1, runImmediately: true, sleep: { _ in
      probe.recordSleep()
      throw CancellationError()
    }, pass: { probe.recordPass() })
    scheduler.start()
    try await waitUntil { probe.passCount == 1 && probe.sleepCount == 1 }
    scheduler.stop()
    XCTAssertEqual(probe.events, ["pass", "sleep"])
  }

  func testDeferredSchedulerSleepsBeforeFirstPass() async throws {
    let probe = SchedulerProbe()
    let scheduler = RielaRetentionScheduler(interval: 1, runImmediately: false, sleep: { _ in
      probe.recordSleep()
      return
    }, pass: { probe.recordPass() })
    scheduler.start()
    try await waitUntil { probe.passCount >= 1 }
    scheduler.stop()
    XCTAssertEqual(probe.events.first, "sleep")
    XCTAssertEqual(probe.events.dropFirst().first, "pass")
  }

  func testStopWhileSleepingPreventsAnotherPass() async throws {
    let probe = SchedulerProbe()
    let scheduler = RielaRetentionScheduler(interval: 1, runImmediately: true, sleep: { _ in
      probe.recordSleep()
      do {
        try await Task.sleep(nanoseconds: 60_000_000_000)
      } catch {
        probe.recordCancelled()
        throw error
      }
    }, pass: { probe.recordPass() })
    scheduler.start()
    try await waitUntil { probe.passCount == 1 && probe.sleepCount == 1 }
    scheduler.stop()
    try await waitUntil { probe.events.contains("cancelled") }
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(probe.events, ["pass", "sleep", "cancelled"])
  }

  func testStartIsIdempotent() async throws {
    let probe = SchedulerProbe()
    let scheduler = RielaRetentionScheduler(interval: 1, runImmediately: true, sleep: { _ in
      probe.recordSleep()
      try await Task.sleep(nanoseconds: 60_000_000_000)
    }, pass: { probe.recordPass() })
    scheduler.start()
    scheduler.start()
    try await waitUntil { probe.passCount >= 1 && probe.sleepCount >= 1 }
    scheduler.stop()
    XCTAssertEqual(probe.passCount, 1)
  }

  func testNonSuspendingSleepCannotSpinFasterThanOneTick() async throws {
    let probe = SchedulerProbe()
    let scheduler = RielaRetentionScheduler(interval: 1, runImmediately: false, sleep: { _ in
      probe.recordSleep()
      return
    }, pass: { probe.recordPass() })
    let started = Date()
    scheduler.start()
    try await Task.sleep(for: .milliseconds(200))
    scheduler.stop()
    let elapsedMilliseconds = Date().timeIntervalSince(started) * 1_000
    let passesAtStop = probe.passCount
    // The mandatory 1 ms cancellable tick after each pass bounds the loop to about one pass per
    // millisecond, so an injected sleep that returns synchronously can never busy-spin.
    XCTAssertGreaterThanOrEqual(passesAtStop, 1)
    XCTAssertLessThanOrEqual(Double(passesAtStop), elapsedMilliseconds + 10)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertLessThanOrEqual(probe.passCount, passesAtStop + 1, "stop() must end the loop at the next tick")
  }

  private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition())
  }
}

private final class SchedulerProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storedEvents: [String] = []

  var events: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storedEvents
  }

  var passCount: Int { events.filter { $0 == "pass" }.count }
  var sleepCount: Int { events.filter { $0 == "sleep" }.count }

  func recordPass() { record("pass") }
  func recordSleep() { record("sleep") }
  func recordCancelled() { record("cancelled") }

  private func record(_ event: String) {
    lock.lock()
    storedEvents.append(event)
    lock.unlock()
  }
}
