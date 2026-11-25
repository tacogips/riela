import Foundation
import XCTest
@testable import RielaCore

final class BotJobDueTests: XCTestCase {
  func testDisabledPausedAndBusyTakePrecedence() {
    var input = dueInput()
    input.schedule = .off
    input.paused = true
    input.busy = true
    XCTAssertEqual(BotJobDue.decide(input), .notDue(reason: "off"))
    input.schedule = .nightly
    XCTAssertEqual(BotJobDue.decide(input), .notDue(reason: "paused"))
    input.paused = false
    XCTAssertEqual(BotJobDue.decide(input), .notDue(reason: "busy"))
  }

  func testNightlyUsesNewestClosedLocalDay() {
    let input = dueInput()
    XCTAssertEqual(BotJobDue.decide(input), .run(periodKey: "2027-01-07", skippedPeriodKeys: []))
    XCTAssertEqual(BotJobDue.periodKey(for: input.now, schedule: .nightly, calendar: input.calendar), "2027-01-08")
    XCTAssertNil(BotJobDue.periodKey(for: input.now, schedule: .off, calendar: input.calendar))
  }

  func testNoNewActivitySkipsAndLedgerPreventsAnotherRun() {
    var input = dueInput()
    input.lastSuccessAt = input.lastActivityAt
    XCTAssertEqual(BotJobDue.decide(input), .skip(periodKey: "2027-01-07", reason: "no_activity"))
    input.lastActivityAt = nil
    XCTAssertEqual(BotJobDue.decide(input), .skip(periodKey: "2027-01-07", reason: "no_activity"))
    input.ledgerPeriodKeys.insert("2027-01-07")
    XCTAssertEqual(BotJobDue.decide(input), .notDue(reason: "done"))
  }

  func testMissedDaysCatchUpOnceAndExcludeLedgerRows() {
    var input = dueInput()
    input.lastSuccessAt = timestamp("2027-01-04T03:00:00Z")
    XCTAssertEqual(BotJobDue.decide(input), .run(periodKey: "2027-01-07", skippedPeriodKeys: ["2027-01-05", "2027-01-06"]))
    input.ledgerPeriodKeys.insert("2027-01-05")
    XCTAssertEqual(BotJobDue.decide(input), .run(periodKey: "2027-01-07", skippedPeriodKeys: ["2027-01-06"]))
  }

  func testCatchUpCapsAtThirtyMostRecentMissingPeriods() {
    var input = dueInput()
    input.lastSuccessAt = timestamp("2026-01-01T03:00:00Z")
    input.ledgerPeriodKeys.insert("2027-01-06")
    guard case let .run(key, skippedKeys) = BotJobDue.decide(input) else {
      return XCTFail("Expected a catch-up run")
    }
    XCTAssertEqual(key, "2027-01-07")
    XCTAssertEqual(skippedKeys.count, 30)
    XCTAssertEqual(skippedKeys.first, "2026-12-07")
    XCTAssertEqual(skippedKeys.last, "2027-01-05")
    XCTAssertEqual(skippedKeys, skippedKeys.sorted())
  }

  func testWeeklyUsesISOWeekYearAndInjectedTimeZone() {
    var input = dueInput()
    input.schedule = .weekly
    input.now = timestamp("2027-01-03T15:00:00Z")
    input.lastActivityAt = timestamp("2027-01-03T12:00:00Z")
    input.lastSuccessAt = timestamp("2026-12-20T00:00:00Z")
    input.calendar.firstWeekday = 1
    input.calendar.minimumDaysInFirstWeek = 1
    XCTAssertEqual(BotJobDue.periodKey(for: input.now, schedule: .weekly, calendar: input.calendar), "2027-W01")
    XCTAssertEqual(BotJobDue.decide(input), .run(periodKey: "2026-W53", skippedPeriodKeys: ["2026-W52"]))
  }

  func testNightlyClosesShortDayAtLocalMidnight() throws {
    var input = dueInput()
    input.calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    input.now = timestamp("2027-03-15T04:00:00Z")
    input.lastActivityAt = timestamp("2027-03-14T15:00:00Z")
    XCTAssertEqual(BotJobDue.decide(input), .run(periodKey: "2027-03-14", skippedPeriodKeys: []))
  }

  private func dueInput() -> BotJobDueInput {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
    return BotJobDueInput(
      schedule: .nightly, now: timestamp("2027-01-07T15:00:00Z"), calendar: calendar, paused: false, busy: false,
      lastActivityAt: timestamp("2027-01-07T02:00:00Z"), lastSuccessAt: nil, ledgerPeriodKeys: []
    )
  }

  private func timestamp(_ value: String) -> Date {
    guard let date = ISO8601DateFormatter().date(from: value) else {
      XCTFail("Invalid test fixture date: \(value)")
      return .distantPast
    }
    return date
  }
}
