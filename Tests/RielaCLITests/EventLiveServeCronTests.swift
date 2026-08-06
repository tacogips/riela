import Foundation
import RielaCore
@testable import RielaCLI
import XCTest

final class EventLiveServeCronTests: XCTestCase {
  func testCronScheduleParsesSixFieldExpressions() throws {
    let everyThirtySeconds = try CronSchedule.parse("*/30 * * * * *")
    XCTAssertEqual(everyThirtySeconds.seconds, [0, 30])
    XCTAssertEqual(everyThirtySeconds.minutes.count, 60)

    let hourly = try CronSchedule.parse("0 0 * * * *")
    XCTAssertEqual(hourly.seconds, [0])
    XCTAssertEqual(hourly.minutes, [0])
    XCTAssertEqual(hourly.hours.count, 24)

    let listsAndRanges = try CronSchedule.parse("5,10 0-15/5 9-18 1 12 1-5")
    XCTAssertEqual(listsAndRanges.seconds, [5, 10])
    XCTAssertEqual(listsAndRanges.minutes, [0, 5, 10, 15])
    XCTAssertEqual(listsAndRanges.hours, Set(9...18))
    XCTAssertEqual(listsAndRanges.daysOfMonth, [1])
    XCTAssertEqual(listsAndRanges.months, [12])
    XCTAssertEqual(listsAndRanges.daysOfWeek, [1, 2, 3, 4, 5])

    let sundayAliases = try CronSchedule.parse("0 0 0 * * 7")
    XCTAssertEqual(sundayAliases.daysOfWeek, [0])
  }

  func testCronScheduleRejectsInvalidExpressions() {
    XCTAssertThrowsError(try CronSchedule.parse("* * * * *"))
    XCTAssertThrowsError(try CronSchedule.parse("60 * * * * *"))
    XCTAssertThrowsError(try CronSchedule.parse("* * 24 * * *"))
    XCTAssertThrowsError(try CronSchedule.parse("* * * 0 * *"))
    XCTAssertThrowsError(try CronSchedule.parse("*/0 * * * * *"))
    XCTAssertThrowsError(try CronSchedule.parse("a * * * * *"))
  }

  func testCronScheduleMatchesInConfiguredTimezone() throws {
    let nineAmTokyo = try CronSchedule.parse("0 0 9 * * *")
    var tokyo = Calendar(identifier: .gregorian)
    tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    // 2026-08-06T00:00:00Z == 09:00 JST
    let date = Date(timeIntervalSince1970: 1_785_974_400)
    XCTAssertTrue(nineAmTokyo.matches(date, calendar: tokyo))
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    XCTAssertFalse(nineAmTokyo.matches(date, calendar: utc))
  }

  func testDueTickCoalescesMissedTicksIntoLatestMatch() {
    let source = CronScheduleSource(id: "tick", schedule: "*/30 * * * * *", timezone: "UTC")
    let base = Date(timeIntervalSince1970: 1_754_438_400)
    XCTAssertEqual(
      source.dueTick(after: base.addingTimeInterval(-95), until: base),
      base
    )
    XCTAssertNil(source.dueTick(after: base, until: base.addingTimeInterval(10)))
    XCTAssertEqual(
      source.dueTick(after: base, until: base.addingTimeInterval(31)),
      base.addingTimeInterval(30)
    )
  }

  func testCronServeFiresTickAndRunsBoundWorkflow() async throws {
    let eventRoot = try temporaryDirectory()
    try writeCronEventConfig(eventRoot: eventRoot)
    let workflowRunner = FakeEventWorkflowRunner(replyText: "", replyAs: "")
    let server = DefaultEventLiveServer(workflowRunner: workflowRunner)

    let result = try await server.serve(
      eventRoot: eventRoot,
      target: nil,
      parsed: try ParsedParityOptions(["--limit", "1"]),
      output: .json
    )

    XCTAssertEqual(result.status, "ok")
    XCTAssertTrue(result.records.contains("processedEvents=1"))
    let requests = await workflowRunner.requests
    XCTAssertEqual(requests.map(\.workflowName), ["cron-flow"])
    let workflowInput = requests.first?.runtimeVariables["workflowInput"]
    guard case let .object(input)? = workflowInput else {
      return XCTFail("expected workflowInput object, got \(String(describing: workflowInput))")
    }
    XCTAssertEqual(input["request"], .string("cron tick"))
    guard case let .string(scheduledAt)? = input["scheduledAt"] else {
      return XCTFail("expected scheduledAt string")
    }
    XCTAssertTrue(scheduledAt.hasSuffix("Z"))
    XCTAssertEqual(input["timezone"], .string("UTC"))
  }

  private func writeCronEventConfig(eventRoot: URL) throws {
    let sources = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let bindings = eventRoot.appendingPathComponent("bindings", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bindings, withIntermediateDirectories: true)
    try """
    {
      "id": "cron-live",
      "kind": "cron",
      "schedule": "* * * * * *",
      "timezone": "UTC"
    }
    """.write(to: sources.appendingPathComponent("cron-live.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "cron-to-workflow",
      "sourceId": "cron-live",
      "workflowName": "cron-flow",
      "match": {"eventType": "cron.tick"},
      "inputMapping": {
        "mode": "template",
        "template": {
          "request": "cron tick",
          "scheduledAt": "{{event.input.scheduledAt}}",
          "timezone": "{{event.input.timezone}}"
        },
        "mirrorToHumanInput": false
      }
    }
    """.write(to: bindings.appendingPathComponent("cron-to-workflow.json"), atomically: true, encoding: .utf8)
  }

  private func temporaryDirectory() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-event-live-cron-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    return root
  }
}
