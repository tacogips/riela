import Foundation
import RielaCore
import RielaEvents
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

  func testDueTicksReturnsEveryBoundedMatchingSecond() {
    let source = CronScheduleSource(id: "tick", schedule: "*/30 * * * * *", timezone: "UTC")
    let base = Date(timeIntervalSince1970: 1_754_438_400)
    XCTAssertEqual(
      source.dueTicks(after: base.addingTimeInterval(-95), until: base),
      [base.addingTimeInterval(-90), base.addingTimeInterval(-60), base.addingTimeInterval(-30), base]
    )
    XCTAssertEqual(source.dueTicks(after: base, until: base.addingTimeInterval(10)), [])
    XCTAssertEqual(
      source.dueTicks(after: base, until: base.addingTimeInterval(31)),
      [base.addingTimeInterval(30)]
    )
  }

  func testReadOnlyCronRetainsFixedClockEnvelopeWithoutDispatchOrRoutineCompletion() async throws {
    let eventRoot = try temporaryDirectory()
    try writeCronEventConfig(eventRoot: eventRoot)
    let runner = FakeEventWorkflowRunner(replyText: "", replyAs: "")
    let server = DefaultEventLiveServer(workflowRunner: runner)
    let scheduled = Date(timeIntervalSince1970: 1_754_438_400)
    let dispatcher = CronOverlapDispatcher(
      server: server, eventRoot: eventRoot, parsed: try ParsedParityOptions(["--read-only"]),
      policies: [:], clock: SystemEventServeClock(), cancelSettleTimeout: .seconds(30)
    )
    let count = try await server.dispatchCronTick(
      source: CronScheduleSource(id: "cron-live", schedule: "* * * * * *", timezone: "UTC"),
      scheduledAt: scheduled, firedAt: scheduled.addingTimeInterval(1),
      config: try EventLiveConfig.load(eventRoot: eventRoot), eventRoot: eventRoot,
      parsed: try ParsedParityOptions(["--read-only"]), dispatcher: dispatcher
    )
    XCTAssertEqual(count, 1)
    let requests = await runner.requests
    XCTAssertTrue(requests.isEmpty)
    let receipt = try assertReadOnlyEventReceipt(eventRoot: eventRoot)
    XCTAssertEqual(receipt.envelope.input["scheduledAt"], .string("2025-08-06T00:00:00.000Z"))
    XCTAssertEqual(receipt.envelope.input["firedAt"], .string("2025-08-06T00:00:01.000Z"))
  }

  func testReadOnlyCronEnvelopeIncludesPreviousTickInTokyo() async throws {
    let scheduledAt = try isoDate("2026-10-27T05:55:00.000Z")
    let receipt = try await readOnlyCronReceipt(
      source: CronScheduleSource(id: "cron-live", schedule: "0 55 * * * *", timezone: "Asia/Tokyo"),
      scheduledAt: scheduledAt
    )
    XCTAssertEqual(receipt.envelope.input["previousScheduledAt"], .string("2026-10-27T04:55:00.000Z"))
    XCTAssertEqual(receipt.envelope.input["previousScheduledLocalTime"], .string("2026-10-27 13:55:00"))
    XCTAssertEqual(receipt.envelope.input["scheduledLocalTime"], .string("2026-10-27 14:55:00"))
  }

  func testReadOnlyCronEnvelopeIncludesPreviousTickAcrossNewYorkSpringForward() async throws {
    let scheduledAt = try isoDate("2026-03-08T07:00:00.000Z")
    let receipt = try await readOnlyCronReceipt(
      source: CronScheduleSource(id: "cron-live", schedule: "0 0 * * * *", timezone: "America/New_York"),
      scheduledAt: scheduledAt
    )
    XCTAssertEqual(receipt.envelope.input["previousScheduledAt"], .string("2026-03-08T06:00:00.000Z"))
    XCTAssertEqual(receipt.envelope.input["previousScheduledLocalTime"], .string("2026-03-08 01:00:00"))
  }

  func testPreviousTickUsesScheduleAndReturnsNilForInvalidSchedule() throws {
    let scheduledAt = try isoDate("2026-10-27T00:01:00.000Z")
    let source = CronScheduleSource(id: "x", schedule: "*/30 * * * * *", timezone: "UTC")
    XCTAssertEqual(source.previousTick(before: scheduledAt), scheduledAt.addingTimeInterval(-30))
    XCTAssertNil(CronScheduleSource(id: "x", schedule: "invalid", timezone: "UTC").previousTick(before: scheduledAt))
  }

  func testDryRunRendersPreviousTickBindingTemplateWindow() async throws {
    let receipt = try await readOnlyCronReceipt(
      source: CronScheduleSource(id: "cron-live", schedule: "0 55 * * * *", timezone: "Asia/Tokyo"),
      scheduledAt: try isoDate("2026-10-27T05:55:00.000Z")
    )
    let binding = EventBindingContract(
      id: "cron-window", sourceId: "cron-live", eventType: "cron.tick", workflowName: "cron-flow",
      inputMapping: EventInputMapping(mode: .template, template: .object([
        "windowStart": .string("{{event.input.previousScheduledAt}}"),
        "windowStartLocal": .string("{{event.input.previousScheduledLocalTime}}"),
        "windowEnd": .string("{{event.input.scheduledAt}}")
      ]))
    )
    let result = await DeterministicEventDryRunTrigger().dryRun(EventDryRunRequest(
      sources: [EventSourceContract(id: "cron-live", kind: .cron)], bindings: [binding], envelope: receipt.envelope
    ))
    XCTAssertTrue(result.accepted, "\(result.diagnostics)")
    let trigger = try XCTUnwrap(result.triggers.first)
    guard case let .object(input)? = trigger.runtimeVariables["workflowInput"] else {
      return XCTFail("expected rendered workflowInput object")
    }
    XCTAssertEqual(input["windowStart"], .string("2026-10-27T04:55:00.000Z"))
    XCTAssertEqual(input["windowStartLocal"], .string("2026-10-27 13:55:00"))
    XCTAssertEqual(input["windowEnd"], .string("2026-10-27T05:55:00.000Z"))
  }

  func testCronFixturesAgreeWithTheirSourceSchedules() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let pairs = [
      ("examples/event-sources/payloads/gmail-latest-mail-hourly-cron.json",
       "examples/event-sources/.riela-events/sources/gmail-latest-mail-hourly-cron.json"),
      ("examples/event-sources/payloads/x-follower-ai-business-hourly-cron.json",
       "examples/event-sources/.riela-events/sources/x-follower-ai-business-hourly-cron.json"),
      ("examples/wrike-project-kanban-agent/payloads/wrike-kanban-cron-tick.json",
       "examples/wrike-project-kanban-agent/.riela-events/sources/wrike-kanban-30s-cron.json")
    ]
    for (payloadPath, sourcePath) in pairs {
      let payload = try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: repository.appendingPathComponent(payloadPath)))
      let source = try JSONDecoder().decode(CronScheduleSource.self, from: Data(contentsOf: repository.appendingPathComponent(sourcePath)))
      guard case let .object(input)? = payload["input"],
            case let .string(scheduledAtString)? = input["scheduledAt"] else {
        return XCTFail("missing cron input in \(payloadPath)")
      }
      let scheduledAt = try isoDate(scheduledAtString)
      let previous = try XCTUnwrap(source.previousTick(before: scheduledAt), "no previous tick for \(sourcePath)")
      XCTAssertEqual(input["previousScheduledAt"], .string(cronISO(previous)), payloadPath)
      XCTAssertEqual(input["previousScheduledLocalTime"], .string(cronLocal(previous, timezone: source.resolvedTimeZone)), payloadPath)
    }
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

  func testCronServeSurvivesWorkflowRunFailure() async throws {
    let eventRoot = try temporaryDirectory()
    try writeCronEventConfig(eventRoot: eventRoot)
    let workflowRunner = FakeEventWorkflowRunner(failureMessage: "cron run failed")
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
    let record = try String(contentsOf: eventRoot.appendingPathComponent("serve-record.json"), encoding: .utf8)
    XCTAssertTrue(record.contains("cron-workflow-failed"), record)
    XCTAssertTrue(record.contains("cron run failed"), record)
  }

  func testRoutineGateSkipsDisabledRoutineAndCountsActiveRun() async throws {
    let root = try temporaryDirectory()
    let store = RoutineStore(rootDirectory: root.appendingPathComponent("routines").path)
    var routine = RoutineRecord(
      routineId: "routine-a",
      name: "gate test",
      task: "run once",
      schedule: "* * * * * *",
      workflowName: "cron-flow",
      status: .disabled,
      createdAt: RoutineStore.timestamp(),
      updatedAt: RoutineStore.timestamp(),
      eventRoot: root.path,
      sourceId: "cron-live",
      bindingId: "cron-to-workflow"
    )
    try store.save(routine)
    let config = EventLiveConfig(
      sources: [EventSourceContract(id: "cron-live", kind: .cron)],
      bindings: [EventBindingContract(
        id: "cron-to-workflow",
        sourceId: "cron-live",
        eventType: "cron.tick",
        workflowName: "cron-flow",
        inputMapping: EventInputMapping(mode: .eventInput),
        routineId: routine.routineId,
        routineStoreRoot: store.rootDirectory
      )]
    )
    let workflowRunner = FakeEventWorkflowRunner(replyText: "", replyAs: "")
    let server = DefaultEventLiveServer(workflowRunner: workflowRunner)
    let source = CronScheduleSource(id: "cron-live", schedule: "* * * * * *", timezone: "UTC")
    let parsed = try ParsedParityOptions([])
    let now = Date()
    let dispatcher = CronOverlapDispatcher(
      server: server, eventRoot: root, parsed: parsed,
      policies: ["cron-to-workflow": EffectiveEventOverlapPolicy(policy: .skip, source: .default)],
      clock: SystemEventServeClock(), cancelSettleTimeout: .seconds(30)
    )

    let skipped = try await server.dispatchCronTick(
      source: source,
      scheduledAt: now,
      firedAt: now,
      config: config,
      eventRoot: root,
      parsed: parsed, dispatcher: dispatcher
    )
    XCTAssertEqual(skipped, 0)
    var requests = await workflowRunner.requests
    XCTAssertEqual(requests.count, 0)
    // The submit-time gate skip is persisted like a deferred-start gate skip.
    let gateReceipt = try XCTUnwrap(EventReceiptStore(eventRoot: root).load(cronOverlapReceiptId(
      sourceId: "cron-live", eventId: "cron-live-\(Int(now.timeIntervalSince1970))", bindingId: "cron-to-workflow"
    )))
    XCTAssertEqual(gateReceipt.status, "skipped")
    XCTAssertEqual(gateReceipt.reason, "routine-disabled:routine-a")
    XCTAssertEqual(gateReceipt.bindingId, "cron-to-workflow")
    XCTAssertEqual(gateReceipt.overlapPolicy, "skip")

    routine.status = .active
    try store.save(routine)
    let dispatched = try await server.dispatchCronTick(
      source: source,
      scheduledAt: now.addingTimeInterval(1),
      firedAt: now.addingTimeInterval(1),
      config: config,
      eventRoot: root,
      parsed: parsed, dispatcher: dispatcher
    )
    XCTAssertEqual(dispatched, 1)
    await dispatcher.drain()
    requests = await workflowRunner.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(try store.load(routineId: routine.routineId)?.runCount, 1)
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

  private func readOnlyCronReceipt(source: CronScheduleSource, scheduledAt: Date) async throws -> PersistedEventReceipt {
    let eventRoot = try temporaryDirectory()
    try writeCronEventConfig(eventRoot: eventRoot)
    let server = DefaultEventLiveServer(workflowRunner: FakeEventWorkflowRunner(replyText: "", replyAs: ""))
    let parsed = try ParsedParityOptions(["--read-only"])
    let dispatcher = CronOverlapDispatcher(
      server: server, eventRoot: eventRoot, parsed: parsed, policies: [:], clock: SystemEventServeClock(),
      cancelSettleTimeout: .seconds(30)
    )
    let count = try await server.dispatchCronTick(
      source: source, scheduledAt: scheduledAt, firedAt: scheduledAt.addingTimeInterval(1),
      config: try EventLiveConfig.load(eventRoot: eventRoot), eventRoot: eventRoot,
      parsed: parsed, dispatcher: dispatcher
    )
    XCTAssertEqual(count, 1)
    return try assertReadOnlyEventReceipt(eventRoot: eventRoot)
  }

  private func isoDate(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return try XCTUnwrap(formatter.date(from: value), "invalid ISO timestamp: \(value)")
  }

  private func cronISO(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private func cronLocal(_ date: Date, timezone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timezone
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
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
