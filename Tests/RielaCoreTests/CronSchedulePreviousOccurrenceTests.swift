import Foundation
import XCTest
import RielaCore

final class CronSchedulePreviousOccurrenceTests: XCTestCase {
  func testTokyoHourlyOccurrence() throws {
    try assertPrevious("0 55 * * * *", timezone: "Asia/Tokyo", before: "2026-10-27T14:55:00+09:00", expected: "2026-10-27T13:55:00+09:00")
  }

  func testTokyoDailyOccurrence() throws {
    try assertPrevious("0 0 3 * * *", timezone: "Asia/Tokyo", before: "2026-10-27T03:00:00+09:00", expected: "2026-10-26T03:00:00+09:00")
  }

  func testTokyoWeeklyOccurrence() throws {
    try assertPrevious("0 0 9 * * 1", timezone: "Asia/Tokyo", before: "2026-10-26T09:00:00+09:00", expected: "2026-10-19T09:00:00+09:00")
  }

  func testNewYorkSpringForwardHourly() throws {
    try assertPrevious("0 0 * * * *", timezone: "America/New_York", before: "2026-03-08T07:00:00Z", expected: "2026-03-08T06:00:00Z")
  }

  func testNewYorkSpringForwardDailyMissingTime() throws {
    try assertPrevious("0 30 2 * * *", timezone: "America/New_York", before: "2026-03-09T06:30:00Z", expected: "2026-03-07T07:30:00Z")
  }

  func testNewYorkFallBackRepeatedTime() throws {
    try assertPrevious("0 30 1 * * *", timezone: "America/New_York", before: "2026-11-01T06:30:00Z", expected: "2026-11-01T05:30:00Z")
  }

  func testEveryFifteenSeconds() throws {
    try assertPrevious("*/15 * * * * *", timezone: "UTC", before: "2026-10-27T10:00:00Z", expected: "2026-10-27T09:59:45Z")
  }

  func testSecondAndMinuteSchedule() throws {
    try assertPrevious("30 0 * * * *", timezone: "UTC", before: "2026-10-27T10:00:30Z", expected: "2026-10-27T09:00:30Z")
  }

  func testLeapDaySchedule() throws {
    try assertPrevious("0 0 0 29 2 *", timezone: "UTC", before: "2028-02-29T00:00:00Z", expected: "2024-02-29T00:00:00Z")
  }

  func testImpossibleFebruaryThirtyFirstReturnsNil() throws {
    let schedule = try CronSchedule.parse("0 0 0 31 2 *")
    XCTAssertNil(schedule.previousOccurrence(before: try instant("2026-10-27T00:00:00Z"), calendar: try calendar("UTC")))
  }

  func testDayOfMonthAndWeekUseOrRule() throws {
    try assertPrevious("0 0 0 1 * 1", timezone: "UTC", before: "2026-10-26T00:00:00Z", expected: "2026-10-19T00:00:00Z")
  }

  func testFractionalInputUsesLargestEarlierWholeSecond() throws {
    try assertPrevious("* * * * * *", timezone: "UTC", before: "2026-10-27T10:00:00.5Z", expected: "2026-10-27T10:00:00Z")
  }

  func testIntegralInputIsStrictlyEarlier() throws {
    try assertPrevious("* * * * * *", timezone: "UTC", before: "2026-10-27T10:00:00Z", expected: "2026-10-27T09:59:59Z")
  }

  func testSeededResultsMatchBackwardScanAcrossDSTWindows() throws {
    let schedules = ["*/7 * * * * *", "0 */13 * * * *", "15 0-5 * * * 2"]
    let zones = ["Asia/Tokyo", "America/New_York"]
    let starts = [try instant("2026-03-07T00:00:00Z"), try instant("2026-10-31T00:00:00Z")]
    var state: UInt64 = 0x5eed

    for index in 0..<20 {
      state = state &* 6_364_136_223_846_793_005 &+ 1
      let schedule = try CronSchedule.parse(schedules[index % schedules.count])
      let zone = zones[index % zones.count]
      let cal = try calendar(zone)
      let before = starts[index % starts.count].addingTimeInterval(TimeInterval(state % (3 * 86_400)))
      let expected = bruteForcePrevious(schedule, before: before, calendar: cal)
      XCTAssertEqual(schedule.previousOccurrence(before: before, calendar: cal), expected, "case \(index), \(zone)")
    }
  }

  private func assertPrevious(
    _ expression: String,
    timezone: String,
    before: String,
    expected: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let schedule = try CronSchedule.parse(expression)
    let actual = schedule.previousOccurrence(before: try instant(before), calendar: try calendar(timezone))
    XCTAssertEqual(actual, try instant(expected), file: file, line: line)
  }

  private func calendar(_ timezone: String) throws -> Calendar {
    var result = Calendar(identifier: .gregorian)
    result.timeZone = try XCTUnwrap(TimeZone(identifier: timezone))
    return result
  }

  private func instant(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: value) else {
      throw NSError(domain: "CronSchedulePreviousOccurrenceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid ISO-8601 instant: \(value)"])
    }
    return date
  }

  private func bruteForcePrevious(_ schedule: CronSchedule, before: Date, calendar: Calendar) -> Date? {
    var candidate = Date(timeIntervalSince1970: ceil(before.timeIntervalSince1970) - 1)
    let limit = candidate.addingTimeInterval(-8 * 86_400)
    while candidate >= limit {
      if schedule.matches(candidate, calendar: calendar) {
        return candidate
      }
      candidate = candidate.addingTimeInterval(-1)
    }
    return nil
  }
}
