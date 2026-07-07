import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class AppleCalendarAddonTests: XCTestCase {
  func testCalendarListBuildsVariablesAndParsesCalendars() async throws {
    let fake = try CalendarFakeAppleGateway(mode: "calendar-list")
    defer { fake.cleanup() }

    let output = try await runCalendarAddon(
      "riela/calendar-list",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "entityType": .string("EVENT")
      ],
      environment: [
        "PATH": "/usr/bin:/bin",
        "USER": "calendar-test",
        "OPENAI_API_KEY": "sentinel-openai"
      ]
    )

    XCTAssertEqual(try String(contentsOf: fake.argumentLogURL), "graphql\n--query\n--variables\n")
    let query = try String(contentsOf: fake.queryLogURL)
    XCTAssertTrue(query.contains("calendars(entityType: $entityType)"))
    XCTAssertFalse(query.contains("cal-1"))
    XCTAssertEqual(try variablesObject(fake)["entityType"], .string("EVENT"))
    let appleCalendar = try XCTUnwrap(calendarTestObject(output.payload["appleCalendar"]))
    XCTAssertEqual(calendarTestArray(appleCalendar["calendars"])?.count, 1)
    XCTAssertEqual(appleCalendar["calendarCount"], .integer(1))
    XCTAssertEqual(output.payload["calendarCount"], .integer(1))
    XCTAssertEqual(output.when["has_calendars"], true)

    let childEnvironment = try String(contentsOf: fake.environmentLogURL)
    XCTAssertTrue(childEnvironment.contains("PATH=/usr/bin:/bin"))
    XCTAssertTrue(childEnvironment.contains("USER=calendar-test"))
    XCTAssertFalse(childEnvironment.contains("sentinel-openai"))
  }

  func testEventSearchAcceptsJsonArrayTemplateAndParsesConnection() async throws {
    let fake = try CalendarFakeAppleGateway(mode: "event-search")
    defer { fake.cleanup() }

    let output = try await runCalendarAddon(
      "riela/event-search",
      config: ["binaryPath": .string(fake.executableURL.path), "first": .integer(2)],
      inputs: [
        "calendarIds": .string("{{workflowInput.calendarIds}}"),
        "startDate": .string("{{workflowInput.startDate}}")
      ],
      variables: [
        "workflowInput": .object([
          "calendarIds": .array([.string("cal-1")]),
          "startDate": .string("2026-07-07T00:00:00Z")
        ])
      ]
    )

    let variables = try variablesObject(fake)
    let searchInput = try XCTUnwrap(calendarTestObject(variables["input"]))
    XCTAssertEqual(searchInput["calendarIds"], .array([.string("cal-1")]))
    XCTAssertEqual(searchInput["startDate"], .string("2026-07-07T00:00:00Z"))
    XCTAssertEqual(searchInput["first"], .integer(2))
    let query = try String(contentsOf: fake.queryLogURL)
    XCTAssertTrue(query.contains("events(input: $input)"))
    XCTAssertFalse(query.contains("cal-1"))

    let appleCalendar = try XCTUnwrap(calendarTestObject(output.payload["appleCalendar"]))
    let events = try XCTUnwrap(calendarTestArray(appleCalendar["events"]))
    let event = try XCTUnwrap(calendarTestObject(events.first))
    XCTAssertEqual(event["id"], .string("event-1"))
    XCTAssertEqual(event["cursor"], .string("cursor-1"))
    XCTAssertEqual(appleCalendar["totalCount"], .integer(1))
    XCTAssertEqual(output.when["has_events"], true)
  }

  func testEventGetPassesOccurrenceDateAndAllowsNullEvent() async throws {
    let fake = try CalendarFakeAppleGateway(mode: "event-get-null")
    defer { fake.cleanup() }

    let output = try await runCalendarAddon(
      "riela/event-get",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: ["eventId": .string("event-1"), "occurrenceDate": .string("2026-07-08T09:00:00Z")]
    )

    let variables = try variablesObject(fake)
    XCTAssertEqual(variables["eventId"], .string("event-1"))
    XCTAssertEqual(variables["occurrenceDate"], .string("2026-07-08T09:00:00Z"))
    XCTAssertFalse(try String(contentsOf: fake.queryLogURL).contains("event-1"))
    XCTAssertEqual(calendarTestObject(output.payload["appleCalendar"])?.getValue("event"), .null)
    XCTAssertEqual(output.when["has_event"], false)
  }

  func testEventGetRejectsMalformedEventValue() async throws {
    let fake = try CalendarFakeAppleGateway(mode: "event-get-scalar")
    defer { fake.cleanup() }

    try await assertCalendarFailure(
      "riela/event-get",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: ["eventId": .string("event-1")],
      code: .invalidOutput,
      messageContains: "data.event must be null or an object"
    )
  }

  func testMutationAddonsBuildVariablesAndParseOutputs() async throws {
    let createFake = try CalendarFakeAppleGateway(mode: "event-create")
    let updateFake = try CalendarFakeAppleGateway(mode: "event-update")
    let deleteFake = try CalendarFakeAppleGateway(mode: "event-delete")
    let alarmsFake = try CalendarFakeAppleGateway(mode: "event-alarms-set")
    defer {
      createFake.cleanup()
      updateFake.cleanup()
      deleteFake.cleanup()
      alarmsFake.cleanup()
    }

    let createOutput = try await runCalendarAddon(
      "riela/event-create",
      config: ["binaryPath": .string(createFake.executableURL.path)],
      inputs: [
        "calendarId": .string("cal-1"),
        "title": .string("Planning \"Session\""),
        "startDate": .string("2026-07-07T10:00:00Z"),
        "endDate": .string("2026-07-07T11:00:00Z"),
        "availability": .string("BUSY"),
        "alarms": .array([.object(["relativeOffsetSeconds": .integer(-600)])]),
        "recurrenceRules": .array([.object(["frequency": .string("daily"), "interval": .integer(1)])])
      ]
    )
    var input = try XCTUnwrap(calendarTestObject(try variablesObject(createFake)["input"]))
    XCTAssertEqual(input["title"], .string("Planning \"Session\""))
    XCTAssertEqual(input["isAllDay"], .bool(false))
    XCTAssertEqual(input["availability"], .string("BUSY"))
    XCTAssertEqual(calendarTestArray(input["alarms"])?.count, 1)
    let expectedRule: JSONValue = .object(["frequency": .string("DAILY"), "interval": .integer(1)])
    XCTAssertEqual(calendarTestArray(input["recurrenceRules"])?.first, expectedRule)
    try assertLoggedQuery(
      createFake,
      contains: ["mutation RielaEventCreate", "createEvent(input: $input)"],
      excludes: ["Planning", "cal-1", "BUSY"]
    )
    XCTAssertEqual(calendarTestObject(createOutput.payload["appleCalendar"])?.getObject("event")?.getString("id"), "created-event")
    XCTAssertEqual(createOutput.when["has_event"], true)
    XCTAssertEqual(createOutput.when["created"], true)

    let updateOutput = try await runCalendarAddon(
      "riela/event-update",
      config: ["binaryPath": .string(updateFake.executableURL.path)],
      inputs: [
        "eventId": .string("event-1"),
        "span": .string("FUTURE_EVENTS"),
        "occurrenceDate": .string("2026-07-09T10:00:00Z"),
        "title": .string("Updated")
      ]
    )
    input = try XCTUnwrap(calendarTestObject(try variablesObject(updateFake)["input"]))
    XCTAssertEqual(input["span"], .string("FUTURE_EVENTS"))
    XCTAssertEqual(input["occurrenceDate"], .string("2026-07-09T10:00:00Z"))
    try assertLoggedQuery(
      updateFake,
      contains: ["mutation RielaEventUpdate", "updateEvent(input: $input)"],
      excludes: ["event-1", "FUTURE_EVENTS", "Updated"]
    )
    XCTAssertEqual(updateOutput.when["updated"], true)
    XCTAssertEqual(updateOutput.when["has_event"], true)

    let deleteOutput = try await runCalendarAddon(
      "riela/event-delete",
      config: ["binaryPath": .string(deleteFake.executableURL.path)],
      inputs: ["eventId": .string("event-1")]
    )
    let deleteVariables = try variablesObject(deleteFake)
    XCTAssertEqual(deleteVariables["eventId"], .string("event-1"))
    XCTAssertEqual(deleteVariables["span"], .string("THIS_EVENT"))
    try assertLoggedQuery(
      deleteFake,
      contains: [
        "mutation RielaEventDelete",
        "deleteEvent(eventId: $eventId, span: $span, occurrenceDate: $occurrenceDate)"
      ],
      excludes: ["event-1", "THIS_EVENT"]
    )
    XCTAssertEqual(calendarTestObject(deleteOutput.payload["appleCalendar"])?.getObject("deleteResult")?.getBool("success"), true)
    XCTAssertEqual(deleteOutput.payload["deleted"], .bool(true))

    let alarmsOutput = try await runCalendarAddon(
      "riela/event-alarms-set",
      config: ["binaryPath": .string(alarmsFake.executableURL.path)],
      inputs: [
        "eventId": .string("event-1"),
        "alarms": .array([]),
        "occurrenceDate": .string("2026-07-09T10:00:00Z")
      ]
    )
    let alarmVariables = try variablesObject(alarmsFake)
    XCTAssertEqual(alarmVariables["eventId"], .string("event-1"))
    XCTAssertEqual(alarmVariables["alarms"], .array([]))
    XCTAssertEqual(alarmVariables["span"], .string("THIS_EVENT"))
    XCTAssertEqual(alarmVariables["occurrenceDate"], .string("2026-07-09T10:00:00Z"))
    try assertLoggedQuery(
      alarmsFake,
      contains: [
        "mutation RielaEventAlarmsSet",
        "setEventAlarms(eventId: $eventId, alarms: $alarms, span: $span, occurrenceDate: $occurrenceDate)"
      ],
      excludes: ["event-1", "THIS_EVENT", "2026-07-09T10:00:00Z"]
    )
    XCTAssertEqual(calendarTestObject(alarmsOutput.payload["appleCalendar"])?.getObject("event")?.getString("id"), "event-1")
    XCTAssertEqual(alarmsOutput.when["alarms_set"], true)
    XCTAssertEqual(alarmsOutput.when["has_event"], true)
  }

  func testEventDeleteRejectsMalformedOrFailedSuccessValue() async throws {
    let missingSuccessFake = try CalendarFakeAppleGateway(mode: "event-delete-missing-success")
    let scalarSuccessFake = try CalendarFakeAppleGateway(mode: "event-delete-scalar-success")
    let failedSuccessFake = try CalendarFakeAppleGateway(mode: "event-delete-false-success")
    defer {
      missingSuccessFake.cleanup()
      scalarSuccessFake.cleanup()
      failedSuccessFake.cleanup()
    }

    try await assertCalendarFailure(
      "riela/event-delete",
      config: ["binaryPath": .string(missingSuccessFake.executableURL.path)],
      inputs: ["eventId": .string("event-1")],
      code: .invalidOutput,
      messageContains: "data.deleteEvent.success must be a boolean"
    )
    try await assertCalendarFailure(
      "riela/event-delete",
      config: ["binaryPath": .string(scalarSuccessFake.executableURL.path)],
      inputs: ["eventId": .string("event-1")],
      code: .invalidOutput,
      messageContains: "data.deleteEvent.success must be a boolean"
    )
    try await assertCalendarFailure(
      "riela/event-delete",
      config: ["binaryPath": .string(failedSuccessFake.executableURL.path)],
      inputs: ["eventId": .string("event-1")],
      code: .providerError,
      messageContains: "data.deleteEvent.success was false"
    )
  }

  func testEventCreateTreatsRenderedWorkflowInputTextAsLiteral() async throws {
    let fake = try CalendarFakeAppleGateway(mode: "event-create")
    defer { fake.cleanup() }

    _ = try await runCalendarAddon(
      "riela/event-create",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: [
        "title": .string("{{workflowInput.title}}"),
        "notes": .string("{{workflowInput.notes}}"),
        "startDate": .string("2026-07-07T10:00:00Z"),
        "endDate": .string("2026-07-07T11:00:00Z")
      ],
      variables: [
        "workflowInput": .object([
          "title": .string("Review {{workflowInput.secret}}"),
          "notes": .string("Keep {{workflowInput.secret}} literal"),
          "secret": .string("private-note")
        ])
      ]
    )

    let variables = try variablesObject(fake)
    let input = try XCTUnwrap(calendarTestObject(variables["input"]))
    XCTAssertEqual(input["title"], .string("Review {{workflowInput.secret}}"))
    XCTAssertEqual(input["notes"], .string("Keep {{workflowInput.secret}} literal"))
    XCTAssertFalse(try String(contentsOf: fake.variablesLogURL).contains("private-note"))
  }

  func testCalendarConfigFieldsIgnoreConflictingResolvedInputPayload() async throws {
    let searchFake = try CalendarFakeAppleGateway(mode: "event-search")
    let getFake = try CalendarFakeAppleGateway(mode: "event-get-null")
    let templatedGetFake = try CalendarFakeAppleGateway(mode: "event-get-null")
    defer {
      searchFake.cleanup()
      getFake.cleanup()
      templatedGetFake.cleanup()
    }

    _ = try await runCalendarAddon(
      "riela/event-search",
      config: [
        "binaryPath": .string(searchFake.executableURL.path),
        "calendarIds": .array([.string("config-calendar")])
      ],
      resolvedInputPayload: ["calendarIds": .array([.string("payload-calendar")])]
    )
    let searchInput = try XCTUnwrap(calendarTestObject(try variablesObject(searchFake)["input"]))
    XCTAssertEqual(searchInput["calendarIds"], .array([.string("config-calendar")]))

    _ = try await runCalendarAddon(
      "riela/event-get",
      config: [
        "binaryPath": .string(getFake.executableURL.path),
        "eventId": .string("config-event")
      ],
      resolvedInputPayload: ["eventId": .string("payload-event")]
    )
    XCTAssertEqual(try variablesObject(getFake)["eventId"], .string("config-event"))

    _ = try await runCalendarAddon(
      "riela/event-get",
      config: [
        "binaryPath": .string(templatedGetFake.executableURL.path),
        "eventId": .string("config-event")
      ],
      inputs: ["eventId": .string("{{workflowInput.eventId}}")],
      variables: ["workflowInput": .object(["eventId": .string("input-event")])],
      resolvedInputPayload: ["eventId": .string("payload-event")]
    )
    XCTAssertEqual(try variablesObject(templatedGetFake)["eventId"], .string("input-event"))
  }

  func testCalendarValidationFailuresArePolicyBlocked() async throws {
    let fake = try CalendarFakeAppleGateway(mode: "event-search")
    defer { fake.cleanup() }

    try await assertCalendarFailure(
      "riela/event-search",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: ["calendarIds": .array([])],
      code: .policyBlocked,
      messageContains: "calendarIds must not be empty"
    )
    try await assertCalendarFailure(
      "riela/event-search",
      config: ["binaryPath": .string(fake.executableURL.path), "first": .integer(101)],
      inputs: ["calendarIds": .array([.string("cal-1")])],
      code: .policyBlocked,
      messageContains: "first must be between"
    )
    try await assertCalendarFailure(
      "riela/event-create",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: ["startDate": .string("2026-07-07T10:00:00Z"), "endDate": .string("2026-07-07T11:00:00Z")],
      code: .policyBlocked,
      messageContains: "title is required"
    )
    try await assertCalendarFailure(
      "riela/event-create",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: [
        "title": .string("Bad"),
        "startDate": .string("2026-07-07T10:00:00Z"),
        "endDate": .string("2026-07-07T11:00:00Z"),
        "availability": .string("MAYBE")
      ],
      code: .policyBlocked,
      messageContains: "availability must be one of"
    )
    try await assertCalendarFailure(
      "riela/event-update",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: ["eventId": .string("event-1"), "span": .string("ALL_EVENTS")],
      code: .policyBlocked,
      messageContains: "span must be one of"
    )
    try await assertCalendarFailure(
      "riela/event-create",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: [
        "title": .string("Bad rule"),
        "startDate": .string("2026-07-07T10:00:00Z"),
        "endDate": .string("2026-07-07T11:00:00Z"),
        "recurrenceRules": .array([.object(["frequency": .string("HOURLY")])])
      ],
      code: .policyBlocked,
      messageContains: "frequency is invalid"
    )
    try await assertCalendarFailure(
      "riela/event-alarms-set",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: ["eventId": .string("event-1")],
      code: .policyBlocked,
      messageContains: "alarms is required"
    )
  }

  func testCalendarBinaryPrecedenceAndBinaryPathIsolation() async throws {
    let configFake = try CalendarFakeAppleGateway(mode: "calendar-list", requestId: "config")
    let envFake = try CalendarFakeAppleGateway(mode: "calendar-list", requestId: "env")
    let pathFake = try CalendarFakeAppleGateway(mode: "calendar-list", requestId: "path", executableName: "apple-gateway")
    let maliciousFake = try CalendarFakeAppleGateway(mode: "calendar-list", requestId: "malicious")
    defer {
      configFake.cleanup()
      envFake.cleanup()
      pathFake.cleanup()
      maliciousFake.cleanup()
    }

    let configOutput = try await runCalendarAddon(
      "riela/calendar-list",
      config: ["binaryPath": .string(configFake.executableURL.path)],
      environment: ["APPLE_GATEWAY_BIN": envFake.executableURL.path, "PATH": pathFake.binURL.path]
    )
    XCTAssertEqual(gatewayBinarySource(configOutput), "config")
    XCTAssertEqual(gatewayRequestId(configOutput), "config")

    let envOutput = try await runCalendarAddon(
      "riela/calendar-list",
      environment: ["APPLE_GATEWAY_BIN": envFake.executableURL.path, "PATH": pathFake.binURL.path]
    )
    XCTAssertEqual(gatewayBinarySource(envOutput), "environment")
    XCTAssertEqual(gatewayRequestId(envOutput), "env")

    let pathOutput = try await runCalendarAddon(
      "riela/calendar-list",
      environment: ["PATH": pathFake.binURL.path]
    )
    XCTAssertEqual(gatewayBinarySource(pathOutput), "path")
    XCTAssertEqual(gatewayRequestId(pathOutput), "path")

    let isolatedOutput = try await runCalendarAddon(
      "riela/calendar-list",
      inputs: ["binaryPath": .string("{{binaryPath}}")],
      environment: ["APPLE_GATEWAY_BIN": envFake.executableURL.path],
      variables: ["binaryPath": .string(maliciousFake.executableURL.path)],
      resolvedInputPayload: ["binaryPath": .string(maliciousFake.executableURL.path)]
    )
    XCTAssertEqual(gatewayBinarySource(isolatedOutput), "environment")
    XCTAssertEqual(gatewayRequestId(isolatedOutput), "env")
    XCTAssertFalse(FileManager.default.fileExists(atPath: maliciousFake.argumentLogURL.path))
  }

  func testCalendarProviderInvalidOutputTimeoutEnvAndVersionFailures() async throws {
    let graphQLErrorFake = try CalendarFakeAppleGateway(mode: "graphql-error")
    let nonzeroFake = try CalendarFakeAppleGateway(mode: "nonzero")
    let malformedFake = try CalendarFakeAppleGateway(mode: "malformed")
    let missingDataFake = try CalendarFakeAppleGateway(mode: "missing-data")
    let missingFieldFake = try CalendarFakeAppleGateway(mode: "missing-field")
    defer {
      graphQLErrorFake.cleanup()
      nonzeroFake.cleanup()
      malformedFake.cleanup()
      missingDataFake.cleanup()
      missingFieldFake.cleanup()
    }

    try await assertCalendarFailure(
      "riela/calendar-list",
      config: ["binaryPath": .string(graphQLErrorFake.executableURL.path)],
      code: .providerError,
      messageContains: "calendar permission denied"
    )
    try await assertCalendarFailure(
      "riela/calendar-list",
      config: ["binaryPath": .string(nonzeroFake.executableURL.path)],
      code: .providerError,
      messageContains: "exit code 8"
    )
    try await assertCalendarFailure(
      "riela/calendar-list",
      config: ["binaryPath": .string(malformedFake.executableURL.path)],
      code: .invalidOutput,
      messageContains: "not valid JSON"
    )
    try await assertCalendarFailure(
      "riela/calendar-list",
      config: ["binaryPath": .string(missingDataFake.executableURL.path)],
      code: .invalidOutput,
      messageContains: "GraphQL data is missing"
    )
    try await assertCalendarFailure(
      "riela/calendar-list",
      config: ["binaryPath": .string(missingFieldFake.executableURL.path)],
      code: .invalidOutput,
      messageContains: "data.calendars"
    )

    let sleepFake = try CalendarFakeAppleGateway(mode: "sleep")
    defer { sleepFake.cleanup() }
    let startedAt = Date()
    try await assertCalendarFailure(
      "riela/calendar-list",
      config: ["binaryPath": .string(sleepFake.executableURL.path)],
      code: .timeout,
      messageContains: "deadline",
      context: AdapterExecutionContext(deadline: Date().addingTimeInterval(0.1))
    )
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)

    let childFake = try CalendarFakeAppleGateway(mode: "spawn-child")
    defer { childFake.cleanup() }
    try await assertCalendarFailure(
      "riela/calendar-list",
      config: ["binaryPath": .string(childFake.executableURL.path)],
      code: .timeout,
      messageContains: "deadline",
      context: AdapterExecutionContext(deadline: Date().addingTimeInterval(0.1))
    )
    try await Task.sleep(nanoseconds: 1_300_000_000)
    XCTAssertFalse(FileManager.default.fileExists(atPath: childFake.childSurvivalLogURL.path))

    try await assertCalendarFailure(
      "riela/calendar-list",
      version: "2",
      config: ["binaryPath": .string(sleepFake.executableURL.path)],
      code: .policyBlocked,
      messageContains: "unsupported"
    )
    try await assertCalendarFailure(
      "riela/calendar-list",
      config: ["binaryPath": .string(sleepFake.executableURL.path)],
      env: ["UNSAFE": .object(["fromEnv": .string("UNSAFE")])],
      code: .policyBlocked,
      messageContains: "does not support addon.env"
    )
  }

  private func runCalendarAddon(
    _ addonName: String,
    version: String = "1",
    config: JSONObject = [:],
    inputs: JSONObject = [:],
    env: JSONObject? = nil,
    environment: [String: String] = [:],
    variables: JSONObject = [:],
    resolvedInputPayload: JSONObject = [:],
    context: AdapterExecutionContext = AdapterExecutionContext()
  ) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(environment: environment).execute(
      WorkflowAddonExecutionInput(
        workflowId: "apple-calendar",
        stepId: "calendar-step",
        nodeId: "calendar-step",
        addon: WorkflowNodeAddonRef(
          name: addonName,
          version: version,
          config: config,
          env: env,
          inputs: inputs
        ),
        variables: variables,
        resolvedInputPayload: resolvedInputPayload
      ),
      context: context
    )
  }

  private func assertCalendarFailure(
    _ addonName: String,
    version: String = "1",
    config: JSONObject,
    inputs: JSONObject = [:],
    env: JSONObject? = nil,
    code: AdapterExecutionErrorCode,
    messageContains: String,
    context: AdapterExecutionContext = AdapterExecutionContext()
  ) async throws {
    do {
      _ = try await runCalendarAddon(
        addonName,
        version: version,
        config: config,
        inputs: inputs,
        env: env,
        context: context
      )
      XCTFail("expected Apple Calendar add-on to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, code)
      XCTAssertTrue(error.message.contains(messageContains), error.message)
    }
  }

  private func variablesObject(_ fake: CalendarFakeAppleGateway) throws -> JSONObject {
    let data = try Data(contentsOf: fake.variablesLogURL)
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    return try XCTUnwrap(calendarTestObject(value))
  }

  private func assertLoggedQuery(
    _ fake: CalendarFakeAppleGateway,
    contains expectedFragments: [String],
    excludes forbiddenFragments: [String],
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    XCTAssertEqual(try String(contentsOf: fake.argumentLogURL), "graphql\n--query\n--variables\n", file: file, line: line)
    let query = try String(contentsOf: fake.queryLogURL)
    for expectedFragment in expectedFragments {
      XCTAssertTrue(query.contains(expectedFragment), "missing \(expectedFragment)", file: file, line: line)
    }
    for forbiddenFragment in forbiddenFragments {
      XCTAssertFalse(query.contains(forbiddenFragment), "query interpolated \(forbiddenFragment)", file: file, line: line)
    }
  }

  private func gatewayBinarySource(_ output: AdapterExecutionOutput) -> String? {
    calendarTestObject(output.payload["appleGateway"])
      .flatMap { calendarTestObject($0["binary"]) }
      .flatMap { calendarTestString($0["source"]) }
  }

  private func gatewayRequestId(_ output: AdapterExecutionOutput) -> String? {
    calendarTestObject(output.payload["appleGateway"]).flatMap { calendarTestString($0["requestId"]) }
  }
}

private struct CalendarFakeAppleGateway {
  var rootURL: URL
  var binURL: URL
  var executableURL: URL
  var argumentLogURL: URL
  var environmentLogURL: URL
  var queryLogURL: URL
  var variablesLogURL: URL
  var childSurvivalLogURL: URL

  init(mode: String, requestId: String? = nil, executableName: String = "fake-apple-gateway") throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-apple-calendar-\(UUID().uuidString)", isDirectory: true)
    binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
    executableURL = binURL.appendingPathComponent(executableName)
    argumentLogURL = rootURL.appendingPathComponent("args.log")
    environmentLogURL = rootURL.appendingPathComponent("environment.log")
    queryLogURL = rootURL.appendingPathComponent("query.graphql")
    variablesLogURL = rootURL.appendingPathComponent("variables.json")
    childSurvivalLogURL = rootURL.appendingPathComponent("child-survived.log")
    try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
    try script(mode: mode, requestId: requestId ?? mode).write(to: executableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: rootURL)
  }

  private func script(mode: String, requestId: String) -> String {
    """
    #!/bin/sh
    {
      for arg in "$@"; do
        case "$arg" in
          graphql|--query|--variables) printf "%s\\n" "$arg" ;;
        esac
      done
    } > "\(argumentLogURL.path)"
    {
      printf "OPENAI_API_KEY=%s\\n" "${OPENAI_API_KEY:-}"
      printf "PATH=%s\\n" "${PATH:-}"
      printf "USER=%s\\n" "${USER:-}"
    } > "\(environmentLogURL.path)"
    query=""
    variables=""
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --query)
          shift
          query="$1"
          ;;
        --variables)
          shift
          variables="$1"
          ;;
      esac
      shift
    done
    printf "%s" "$query" > "\(queryLogURL.path)"
    printf "%s" "$variables" > "\(variablesLogURL.path)"

    case "\(mode)" in
      calendar-list)
        /bin/cat <<'JSON'
    {
      "data": {
        "calendars": [{
          "id": "cal-1",
          "title": "Work",
          "entityType": "EVENT",
          "sourceTitle": "iCloud",
          "sourceType": "CALDAV",
          "colorHex": "#00ff00",
          "allowsModifications": true,
          "isSubscribed": false,
          "isDefault": true
        }]
      },
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
        ;;
      event-search)
        /bin/cat <<'JSON'
    {
      "data": {
        "events": {
          "totalCount": 1,
          "pageInfo": {"hasNextPage": false, "endCursor": null},
          "edges": [{
            "cursor": "cursor-1",
            "node": {
              "id": "event-1",
              "calendarId": "cal-1",
              "title": "Planning",
              "notes": "notes",
              "location": "Room",
              "url": "https://example.com",
              "isAllDay": false,
              "startDate": "2026-07-07T10:00:00Z",
              "endDate": "2026-07-07T11:00:00Z",
              "timeZone": "UTC",
              "status": "CONFIRMED",
              "availability": "BUSY",
              "organizer": {
                "name": "Me",
                "email": "me@example.com",
                "isCurrentUser": true,
                "status": "ACCEPTED"
              },
              "attendees": [],
              "alarms": [],
              "recurrenceRules": [],
              "isRecurring": false,
              "occurrenceDate": null,
              "isDetached": false,
              "creationDate": "2026-07-01T00:00:00Z",
              "lastModifiedDate": "2026-07-02T00:00:00Z"
            }
          }]
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
        ;;
      event-get-null)
        printf '{"data":{"event":null},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      event-get-scalar)
        printf '{"data":{"event":"corrupt"},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      event-create)
        /bin/cat <<'JSON'
    {
      "data": {
        "createEvent": {
          "id": "created-event",
          "calendarId": "cal-1",
          "title": "Created",
          "startDate": "2026-07-07T10:00:00Z",
          "endDate": "2026-07-07T11:00:00Z"
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
        ;;
      event-update)
        printf '{"data":{"updateEvent":{"id":"event-1","calendarId":"cal-1","title":"Updated","startDate":"2026-07-07T10:00:00Z","endDate":"2026-07-07T11:00:00Z"}},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      event-delete)
        printf '{"data":{"deleteEvent":{"success":true}},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      event-delete-missing-success)
        printf '{"data":{"deleteEvent":{}},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      event-delete-scalar-success)
        printf '{"data":{"deleteEvent":{"success":"yes"}},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      event-delete-false-success)
        printf '{"data":{"deleteEvent":{"success":false}},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      event-alarms-set)
        printf '{"data":{"setEventAlarms":{"id":"event-1","calendarId":"cal-1","title":"Alarms","alarms":[]}},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      graphql-error)
        printf '{"data":null,"errors":[{"message":"calendar permission denied","extensions":{"code":"PERMISSION_DENIED"}}],"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      nonzero)
        echo 'calendar upstream failed' >&2
        exit 8
        ;;
      malformed)
        printf 'not-json\\n'
        ;;
      missing-data)
        printf '{"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      missing-field)
        printf '{"data":{},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      sleep)
        sleep 5
        ;;
      spawn-child)
        (sleep 1; printf survived > "\(childSurvivalLogURL.path)") >/dev/null 2>&1 &
        sleep 5
        ;;
    esac
    """
  }
}

private extension JSONObject {
  func getValue(_ key: String) -> JSONValue? {
    self[key]
  }

  func getObject(_ key: String) -> JSONObject? {
    calendarTestObject(self[key])
  }

  func getString(_ key: String) -> String? {
    calendarTestString(self[key])
  }

  func getBool(_ key: String) -> Bool? {
    guard case let .bool(value)? = self[key] else {
      return nil
    }
    return value
  }
}

private func calendarTestObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object)? = value else {
    return nil
  }
  return object
}

private func calendarTestArray(_ value: JSONValue?) -> [JSONValue]? {
  guard case let .array(array)? = value else {
    return nil
  }
  return array
}

private func calendarTestString(_ value: JSONValue?) -> String? {
  guard case let .string(string)? = value else {
    return nil
  }
  return string
}
