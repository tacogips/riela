import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class AppleClockAlarmAddonTests: XCTestCase {
  func testListBuildsFixedQueryWithoutVariablesAndParsesAlarms() async throws {
    let fake = try ClockFakeAppleGateway(mode: "list")
    defer { fake.cleanup() }

    let output = try await runClockAddon(
      "riela/apple-clock-alarms-list",
      config: ["binaryPath": .string(fake.executableURL.path)]
    )

    let query = try String(contentsOf: fake.queryLogURL)
    let arguments = try String(contentsOf: fake.argumentLogURL)
    XCTAssertEqual(arguments, "graphql\n--query\n\(query)\n")
    XCTAssertFalse(arguments.contains("--variables\n"))
    XCTAssertEqual(try String(contentsOf: fake.variablesLogURL), "")
    XCTAssertTrue(query.contains("query RielaAppleClockAlarmsList"))
    XCTAssertTrue(query.contains("clockAlarms"))
    let alarms = try XCTUnwrap(clockTestArray(output.payload["clockAlarms"]))
    XCTAssertEqual(alarms.count, 1)
    XCTAssertEqual(clockTestObject(alarms.first)?.getString("label"), "Morning")
    XCTAssertEqual(output.payload["alarmCount"], .number(1))
    XCTAssertEqual(output.when["has_alarms"], true)
  }

  func testMutationsPassInputVariablesAndParseResultAlarm() async throws {
    let cases = [
      ClockMutationCase(
        addon: "riela/apple-clock-alarm-create",
        mode: "create",
        inputs: ["time": .string("07:30"), "label": .string("Workout"), "repeatDays": .string("monday, friday")],
        expectedOperation: "mutation RielaAppleClockAlarmCreate($input: CreateClockAlarmInput!)",
        expectedMutationField: "createClockAlarm(input: $input)",
        expectedVariables: [#""time":"07:30""#, #""label":"Workout""#, #""repeatDays":["MONDAY","FRIDAY"]"#]
      ),
      ClockMutationCase(
        addon: "riela/apple-clock-alarm-toggle",
        mode: "toggle",
        inputs: ["label": .string("Workout"), "enabled": .bool(false)],
        expectedOperation: "mutation RielaAppleClockAlarmToggle($input: ToggleClockAlarmInput!)",
        expectedMutationField: "toggleClockAlarm(input: $input)",
        expectedVariables: [#""label":"Workout""#, #""enabled":false"#]
      ),
      ClockMutationCase(
        addon: "riela/apple-clock-alarm-update",
        mode: "update",
        inputs: ["label": .string("Workout"), "time": .string("08:05"), "newLabel": .string("Gym"), "repeatDays": .array([.string("Sunday")])],
        expectedOperation: "mutation RielaAppleClockAlarmUpdate($input: UpdateClockAlarmInput!)",
        expectedMutationField: "updateClockAlarm(input: $input)",
        expectedVariables: [#""label":"Workout""#, #""time":"08:05""#, #""newLabel":"Gym""#, #""repeatDays":["SUNDAY"]"#]
      ),
      ClockMutationCase(
        addon: "riela/apple-clock-alarm-delete",
        mode: "delete",
        inputs: ["label": .string("Gym")],
        expectedOperation: "mutation RielaAppleClockAlarmDelete($input: DeleteClockAlarmInput!)",
        expectedMutationField: "deleteClockAlarm(input: $input)",
        expectedVariables: [#""label":"Gym""#]
      )
    ]

    for testCase in cases {
      let fake = try ClockFakeAppleGateway(mode: testCase.mode)
      defer { fake.cleanup() }

      let output = try await runClockAddon(
        testCase.addon,
        config: ["binaryPath": .string(fake.executableURL.path)],
        inputs: testCase.inputs
      )

      XCTAssertEqual(output.when["succeeded"], true, testCase.addon)
      XCTAssertEqual(clockTestObject(output.payload["clockAlarm"])?.getString("id"), "alarm-1", testCase.addon)
      let query = try String(contentsOf: fake.queryLogURL)
      let variables = try String(contentsOf: fake.variablesLogURL)
      XCTAssertEqual(
        try String(contentsOf: fake.argumentLogURL),
        "graphql\n--query\n\(query)\n--variables\n\(variables)\n",
        testCase.addon
      )
      XCTAssertTrue(query.contains(testCase.expectedOperation), "\(testCase.addon) query: \(query)")
      XCTAssertTrue(query.contains(testCase.expectedMutationField), "\(testCase.addon) query: \(query)")
      for wrongField in testCase.unexpectedMutationFields {
        XCTAssertFalse(query.contains("\(wrongField)(input: $input)"), "\(testCase.addon) query: \(query)")
      }
      for expected in testCase.expectedVariables {
        XCTAssertTrue(variables.contains(expected), "\(testCase.addon) variables: \(variables)")
      }
      XCTAssertFalse(query.contains("Workout"), testCase.addon)
    }
  }

  func testMutationDoesNotRetryWithoutVariablesAfterFailedAttempt() async throws {
    let fake = try ClockFakeAppleGateway(mode: "no-variables-create")
    defer { fake.cleanup() }

    try await assertClockFailure(
      "riela/apple-clock-alarm-create",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: [
        "time": .string("07:30"),
        "label": .string("Quote \" Alarm"),
        "repeatDays": .string("monday, friday")
      ],
      code: .providerError,
      messageContains: "unknown option --variables"
    )

    let query = try String(contentsOf: fake.queryLogURL)
    let variables = try String(contentsOf: fake.variablesLogURL)
    XCTAssertEqual(
      try String(contentsOf: fake.argumentLogURL),
      "graphql\n--query\n\(query)\n--variables\n\(variables)\n"
    )
    XCTAssertTrue(query.contains("mutation RielaAppleClockAlarmCreate"))
    XCTAssertTrue(query.contains("createClockAlarm(input: $input)"))
    XCTAssertTrue(variables.contains(#""label":"Quote \" Alarm""#), variables)
  }

  func testInputValidationFailuresArePolicyBlocked() async throws {
    let fake = try ClockFakeAppleGateway(mode: "create")
    defer { fake.cleanup() }
    let config: JSONObject = ["binaryPath": .string(fake.executableURL.path)]

    try await assertClockFailure(
      "riela/apple-clock-alarm-create",
      config: config,
      inputs: ["label": .string("Missing Time")],
      code: .policyBlocked,
      messageContains: "time is required"
    )
    try await assertClockFailure(
      "riela/apple-clock-alarm-delete",
      config: config,
      inputs: [:],
      code: .policyBlocked,
      messageContains: "label is required"
    )
    try await assertClockFailure(
      "riela/apple-clock-alarm-create",
      config: config,
      inputs: ["time": .string("7:99")],
      code: .policyBlocked,
      messageContains: "HH:mm"
    )
    for invalidTime in ["+1:00", "01:+5"] {
      try await assertClockFailure(
        "riela/apple-clock-alarm-create",
        config: config,
        inputs: ["time": .string(invalidTime)],
        code: .policyBlocked,
        messageContains: "HH:mm"
      )
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fake.argumentLogURL.path),
      "invalid time strings must fail validation before launching apple-gateway"
    )
    try await assertClockFailure(
      "riela/apple-clock-alarm-create",
      config: config,
      inputs: ["time": .string("07:30"), "repeatDays": .string("Funday")],
      code: .policyBlocked,
      messageContains: "invalid weekday"
    )
    try await assertClockFailure(
      "riela/apple-clock-alarm-toggle",
      config: config,
      inputs: ["label": .string("Morning"), "enabled": .string("false")],
      code: .policyBlocked,
      messageContains: "enabled must be a boolean"
    )
  }

  func testMissingShortcutAndMacOSVersionEnvelopesArePolicyBlocked() async throws {
    let missingShortcutFake = try ClockFakeAppleGateway(mode: "missing-shortcut")
    let nonzeroMissingShortcutFake = try ClockFakeAppleGateway(mode: "missing-shortcut-nonzero-stdout")
    let osVersionFake = try ClockFakeAppleGateway(mode: "os-version")
    let nonzeroOSVersionFake = try ClockFakeAppleGateway(mode: "os-version-nonzero-stderr")
    defer {
      missingShortcutFake.cleanup()
      nonzeroMissingShortcutFake.cleanup()
      osVersionFake.cleanup()
      nonzeroOSVersionFake.cleanup()
    }

    try await assertClockFailure(
      "riela/apple-clock-alarms-list",
      config: ["binaryPath": .string(missingShortcutFake.executableURL.path)],
      code: .policyBlocked,
      messageContains: "apple-gateway-get-alarms"
    )
    try await assertClockFailure(
      "riela/apple-clock-alarm-create",
      config: ["binaryPath": .string(missingShortcutFake.executableURL.path)],
      inputs: ["time": .string("07:30")],
      code: .policyBlocked,
      messageContains: "packaging/shortcuts"
    )
    try await assertClockFailure(
      "riela/apple-clock-alarm-create",
      config: ["binaryPath": .string(nonzeroMissingShortcutFake.executableURL.path)],
      inputs: ["time": .string("07:30")],
      code: .policyBlocked,
      messageContains: "apple-gateway-create-alarm"
    )
    try await assertClockFailure(
      "riela/apple-clock-alarm-update",
      config: ["binaryPath": .string(osVersionFake.executableURL.path)],
      inputs: ["label": .string("Morning"), "time": .string("08:00")],
      code: .policyBlocked,
      messageContains: "macOS 26+"
    )
    try await assertClockFailure(
      "riela/apple-clock-alarm-delete",
      config: ["binaryPath": .string(osVersionFake.executableURL.path)],
      inputs: ["label": .string("Morning")],
      code: .policyBlocked,
      messageContains: "macOS 26+"
    )
    try await assertClockFailure(
      "riela/apple-clock-alarm-update",
      config: ["binaryPath": .string(nonzeroOSVersionFake.executableURL.path)],
      inputs: ["label": .string("Morning"), "time": .string("08:00")],
      code: .policyBlocked,
      messageContains: "macOS 26+"
    )
  }

  func testProviderInvalidOutputResultWarningAndTimeoutFailures() async throws {
    let resultFailureFake = try ClockFakeAppleGateway(mode: "result-failure")
    let graphqlErrorFake = try ClockFakeAppleGateway(mode: "graphql-error")
    let nonzeroFake = try ClockFakeAppleGateway(mode: "nonzero")
    let malformedFake = try ClockFakeAppleGateway(mode: "malformed")
    let missingDataFake = try ClockFakeAppleGateway(mode: "missing-data")
    let sleepFake = try ClockFakeAppleGateway(mode: "sleep")
    defer {
      resultFailureFake.cleanup()
      graphqlErrorFake.cleanup()
      nonzeroFake.cleanup()
      malformedFake.cleanup()
      missingDataFake.cleanup()
      sleepFake.cleanup()
    }

    try await assertClockFailure(
      "riela/apple-clock-alarm-create",
      config: ["binaryPath": .string(resultFailureFake.executableURL.path)],
      inputs: ["time": .string("07:30")],
      code: .providerError,
      messageContains: "duplicate label"
    )
    try await assertClockFailure(
      "riela/apple-clock-alarms-list",
      config: ["binaryPath": .string(graphqlErrorFake.executableURL.path)],
      code: .providerError,
      messageContains: "clock permission denied"
    )
    try await assertClockFailure(
      "riela/apple-clock-alarms-list",
      config: ["binaryPath": .string(nonzeroFake.executableURL.path)],
      code: .providerError,
      messageContains: "exit code 6"
    )
    try await assertClockFailure(
      "riela/apple-clock-alarms-list",
      config: ["binaryPath": .string(malformedFake.executableURL.path)],
      code: .invalidOutput,
      messageContains: "not valid JSON"
    )
    try await assertClockFailure(
      "riela/apple-clock-alarms-list",
      config: ["binaryPath": .string(missingDataFake.executableURL.path)],
      code: .invalidOutput,
      messageContains: "GraphQL data is missing"
    )

    let startedAt = Date()
    try await assertClockFailure(
      "riela/apple-clock-alarms-list",
      config: ["binaryPath": .string(sleepFake.executableURL.path)],
      code: .timeout,
      messageContains: "deadline",
      context: AdapterExecutionContext(deadline: Date().addingTimeInterval(0.1))
    )
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
  }

  func testMalformedClockAlarmPayloadsAreInvalidOutput() async throws {
    let malformedListAlarmFake = try ClockFakeAppleGateway(mode: "malformed-list-alarm")
    let malformedListRepeatDaysFake = try ClockFakeAppleGateway(mode: "malformed-list-repeat-days")
    let malformedMutationAlarmFake = try ClockFakeAppleGateway(mode: "malformed-mutation-alarm")
    let missingMutationAlarmFake = try ClockFakeAppleGateway(mode: "missing-mutation-alarm")
    defer {
      malformedListAlarmFake.cleanup()
      malformedListRepeatDaysFake.cleanup()
      malformedMutationAlarmFake.cleanup()
      missingMutationAlarmFake.cleanup()
    }

    try await assertClockFailure(
      "riela/apple-clock-alarms-list",
      config: ["binaryPath": .string(malformedListAlarmFake.executableURL.path)],
      code: .invalidOutput,
      messageContains: "clockAlarms[0].id"
    )
    try await assertClockFailure(
      "riela/apple-clock-alarms-list",
      config: ["binaryPath": .string(malformedListRepeatDaysFake.executableURL.path)],
      code: .invalidOutput,
      messageContains: "repeatDays[1]"
    )
    try await assertClockFailure(
      "riela/apple-clock-alarm-create",
      config: ["binaryPath": .string(malformedMutationAlarmFake.executableURL.path)],
      inputs: ["time": .string("07:30")],
      code: .invalidOutput,
      messageContains: "alarm must be a ClockAlarm object"
    )
    try await assertClockFailure(
      "riela/apple-clock-alarm-create",
      config: ["binaryPath": .string(missingMutationAlarmFake.executableURL.path)],
      inputs: ["time": .string("07:30")],
      code: .invalidOutput,
      messageContains: "alarm must be null or a ClockAlarm object"
    )
  }

  func testBinaryPrecedenceEnvStrippingAddonEnvAndVersionRejection() async throws {
    let configFake = try ClockFakeAppleGateway(mode: "list", requestId: "config")
    let envFake = try ClockFakeAppleGateway(mode: "list", requestId: "env")
    let pathFake = try ClockFakeAppleGateway(mode: "list", requestId: "path", executableName: "apple-gateway")
    defer {
      configFake.cleanup()
      envFake.cleanup()
      pathFake.cleanup()
    }

    let configOutput = try await runClockAddon(
      "riela/apple-clock-alarms-list",
      config: ["binaryPath": .string(configFake.executableURL.path)],
      environment: [
        "APPLE_GATEWAY_BIN": envFake.executableURL.path,
        "PATH": pathFake.binURL.path
      ]
    )
    XCTAssertEqual(clockGatewayBinarySource(configOutput), "config")

    let envOutput = try await runClockAddon(
      "riela/apple-clock-alarms-list",
      environment: [
        "APPLE_GATEWAY_BIN": envFake.executableURL.path,
        "PATH": pathFake.binURL.path
      ]
    )
    XCTAssertEqual(clockGatewayBinarySource(envOutput), "environment")

    let pathOutput = try await runClockAddon(
      "riela/apple-clock-alarms-list",
      environment: ["PATH": pathFake.binURL.path]
    )
    XCTAssertEqual(clockGatewayBinarySource(pathOutput), "path")

    _ = try await runClockAddon(
      "riela/apple-clock-alarms-list",
      config: ["binaryPath": .string(configFake.executableURL.path)],
      environment: [
        "OPENAI_API_KEY": "sentinel-openai",
        "GITHUB_TOKEN": "sentinel-github",
        "PATH": "/usr/bin:/bin",
        "USER": "riela-test"
      ]
    )
    let childEnvironment = try String(contentsOf: configFake.environmentLogURL)
    XCTAssertTrue(childEnvironment.contains("USER=riela-test"))
    XCTAssertFalse(childEnvironment.contains("sentinel-openai"))
    XCTAssertFalse(childEnvironment.contains("sentinel-github"))

    try await assertClockFailure(
      "riela/apple-clock-alarms-list",
      config: ["binaryPath": .string(configFake.executableURL.path)],
      env: ["UNSAFE": .object(["fromEnv": .string("OPENAI_API_KEY")])],
      code: .policyBlocked,
      messageContains: "does not support addon.env"
    )
    try await assertClockFailure(
      "riela/apple-clock-alarms-list",
      version: "2",
      config: ["binaryPath": .string(configFake.executableURL.path)],
      code: .policyBlocked,
      messageContains: "unsupported"
    )
  }

  func testBinaryPathIsNotSourcedFromInputsVariablesOrPayload() async throws {
    let maliciousFake = try ClockFakeAppleGateway(mode: "list", requestId: "payload")
    let envFake = try ClockFakeAppleGateway(mode: "list", requestId: "env")
    defer {
      maliciousFake.cleanup()
      envFake.cleanup()
    }

    let output = try await runClockAddon(
      "riela/apple-clock-alarms-list",
      inputs: ["binaryPath": .string("{{binaryPath}}")],
      environment: ["APPLE_GATEWAY_BIN": envFake.executableURL.path],
      variables: ["binaryPath": .string(maliciousFake.executableURL.path)],
      resolvedInputPayload: ["binaryPath": .string(maliciousFake.executableURL.path)]
    )

    XCTAssertEqual(clockGatewayBinarySource(output), "environment")
    XCTAssertFalse(FileManager.default.fileExists(atPath: maliciousFake.argumentLogURL.path))
  }

  private func runClockAddon(
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
        workflowId: "apple-clock-alarms",
        stepId: "clock-step",
        nodeId: "clock-step",
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

  private func assertClockFailure(
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
      _ = try await runClockAddon(
        addonName,
        version: version,
        config: config,
        inputs: inputs,
        env: env,
        context: context
      )
      XCTFail("expected Apple Clock Alarm add-on to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, code)
      XCTAssertTrue(error.message.contains(messageContains), error.message)
    }
  }

  private func clockGatewayBinarySource(_ output: AdapterExecutionOutput) -> String? {
    clockTestObject(output.payload["appleGateway"])
      .flatMap { clockTestObject($0["binary"]) }
      .flatMap { clockTestString($0["source"]) }
  }
}

private struct ClockMutationCase {
  private static let allMutationFields = [
    "createClockAlarm",
    "toggleClockAlarm",
    "updateClockAlarm",
    "deleteClockAlarm"
  ]

  var addon: String
  var mode: String
  var inputs: JSONObject
  var expectedOperation: String
  var expectedMutationField: String
  var expectedVariables: [String]

  var unexpectedMutationFields: [String] {
    Self.allMutationFields.filter { !expectedMutationField.hasPrefix($0) }
  }
}

private struct ClockFakeAppleGateway {
  var rootURL: URL
  var binURL: URL
  var executableURL: URL
  var argumentLogURL: URL
  var environmentLogURL: URL
  var queryLogURL: URL
  var variablesLogURL: URL

  init(mode: String, requestId: String? = nil, executableName: String = "fake-apple-gateway") throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-apple-clock-alarm-\(UUID().uuidString)", isDirectory: true)
    binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
    executableURL = binURL.appendingPathComponent(executableName)
    argumentLogURL = rootURL.appendingPathComponent("args.log")
    environmentLogURL = rootURL.appendingPathComponent("environment.log")
    queryLogURL = rootURL.appendingPathComponent("query.graphql")
    variablesLogURL = rootURL.appendingPathComponent("variables.json")
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
      for arg in "$@"; do printf "%s\\n" "$arg"; done
    } > "\(argumentLogURL.path)"
    {
      printf "OPENAI_API_KEY=%s\\n" "${OPENAI_API_KEY:-}"
      printf "GITHUB_TOKEN=%s\\n" "${GITHUB_TOKEN:-}"
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
      list|large-output)
        /bin/cat <<'JSON'
    {"data":{"clockAlarms":[{"id":"alarm-1","label":"Morning","time":"07:30","isEnabled":true,"repeatDays":["MONDAY","FRIDAY"]}]},"extensions":{"requestId":"\(requestId)"}}
    JSON
        ;;
      create|no-variables-create)
        if [ "\(mode)" = "no-variables-create" ] && [ -n "$variables" ]; then
          echo 'unknown option --variables' >&2
          exit 64
        fi
        /bin/cat <<'JSON'
    {"data":{"createClockAlarm":{"success":true,"warning":null,"alarm":{"id":"alarm-1","label":"Workout","time":"07:30","isEnabled":true,"repeatDays":["MONDAY","FRIDAY"]}}},"extensions":{"requestId":"\(requestId)"}}
    JSON
        ;;
      toggle)
        /bin/cat <<'JSON'
    {"data":{"toggleClockAlarm":{"success":true,"warning":null,"alarm":{"id":"alarm-1","label":"Workout","time":"07:30","isEnabled":false,"repeatDays":["MONDAY","FRIDAY"]}}},"extensions":{"requestId":"\(requestId)"}}
    JSON
        ;;
      update)
        /bin/cat <<'JSON'
    {"data":{"updateClockAlarm":{"success":true,"warning":null,"alarm":{"id":"alarm-1","label":"Gym","time":"08:05","isEnabled":true,"repeatDays":["SUNDAY"]}}},"extensions":{"requestId":"\(requestId)"}}
    JSON
        ;;
      delete)
        /bin/cat <<'JSON'
    {"data":{"deleteClockAlarm":{"success":true,"warning":null,"alarm":{"id":"alarm-1","label":"Gym","time":"08:05","isEnabled":false,"repeatDays":[]}}},"extensions":{"requestId":"\(requestId)"}}
    JSON
        ;;
      result-failure)
        printf '{"data":{"createClockAlarm":{"success":false,"warning":"duplicate label","alarm":null}},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      missing-shortcut)
        printf '{"data":null,"errors":[{"message":"missing shortcut apple-gateway-get-alarms","extensions":{"code":"SHORTCUT_BRIDGE_MISSING"}}],"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      missing-shortcut-nonzero-stdout)
        printf '{"data":null,"errors":[{"message":"missing shortcut apple-gateway-create-alarm","extensions":{"code":"SHORTCUT_BRIDGE_MISSING"}}],"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        exit 6
        ;;
      os-version)
        printf '{"data":null,"errors":[{"message":"operation requires macOS 26 or newer","extensions":{"code":"UNSUPPORTED_OS_VERSION"}}],"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      os-version-nonzero-stderr)
        printf '{"data":null,"errors":[{"message":"operation requires macOS 26 or newer","extensions":{"code":"UNSUPPORTED_OS_VERSION"}}],"extensions":{"requestId":"%s"}}\\n' "\(requestId)" >&2
        exit 6
        ;;
      graphql-error)
        printf '{"data":null,"errors":[{"message":"clock permission denied","extensions":{"code":"PERMISSION_DENIED"}}],"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      nonzero)
        echo 'clock upstream denied' >&2
        exit 6
        ;;
      malformed)
        printf 'not-json\\n'
        ;;
      missing-data)
        printf '{"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      malformed-list-alarm)
        printf '{"data":{"clockAlarms":[{"label":"Morning"}]},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      malformed-list-repeat-days)
        printf '{"data":{"clockAlarms":[{"id":"alarm-1","label":"Morning","time":"07:30","isEnabled":true,"repeatDays":["MONDAY",5]}]},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      malformed-mutation-alarm)
        printf '{"data":{"createClockAlarm":{"success":true,"warning":null,"alarm":"created"}},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      missing-mutation-alarm)
        printf '{"data":{"createClockAlarm":{"success":true,"warning":null}},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      sleep)
        sleep 5
        ;;
    esac
    """
  }
}

private extension JSONObject {
  func getString(_ key: String) -> String? {
    clockTestString(self[key])
  }
}

private func clockTestObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object)? = value else {
    return nil
  }
  return object
}

private func clockTestArray(_ value: JSONValue?) -> [JSONValue]? {
  guard case let .array(array)? = value else {
    return nil
  }
  return array
}

private func clockTestString(_ value: JSONValue?) -> String? {
  guard case let .string(string)? = value else {
    return nil
  }
  return string
}
