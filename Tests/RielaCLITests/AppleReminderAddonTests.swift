import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class AppleReminderAddonTests: XCTestCase {
  func testReminderListsBuildsFixedQueryAndParsesOutput() async throws {
    let fake = try FakeAppleReminderGateway(mode: "lists")
    defer { fake.cleanup() }

    let output = try await runReminderAddon("riela/apple-reminder-lists", fake: fake)

    XCTAssertEqual(try String(contentsOf: fake.argumentLogURL), "graphql\n--query\n--variables\n")
    XCTAssertTrue(try String(contentsOf: fake.queryLogURL).contains("reminderLists"))
    XCTAssertEqual(try variablesObject(fake), [:])
    let appleReminders = try XCTUnwrap(testObject(output.payload["appleReminders"]))
    XCTAssertEqual(testArray(appleReminders["lists"])?.count, 1)
    XCTAssertEqual(appleReminders["listCount"], .integer(1))
  }

  func testRemindersListPassesTypedVariablesAndFlattensConnection() async throws {
    let fake = try FakeAppleReminderGateway(mode: "search")
    defer { fake.cleanup() }

    let output = try await runReminderAddon(
      "riela/apple-reminders-list",
      fake: fake,
      config: ["status": .string("INCOMPLETE"), "first": .integer(2)],
      inputs: ["listIds": .array([.string("list-1")]), "query": .string("project")]
    )

    XCTAssertTrue(try String(contentsOf: fake.queryLogURL).contains("reminders(input: $input)"))
    try assertReminderSelectionUsesGatewaySchema(fake)
    let variables = try variablesObject(fake)
    let input = try XCTUnwrap(testObject(variables["input"]))
    XCTAssertEqual(input["status"], .string("INCOMPLETE"))
    XCTAssertEqual(input["first"], .integer(2))
    XCTAssertEqual(input["listIds"], .array([.string("list-1")]))
    XCTAssertEqual(input["query"], .string("project"))
    let appleReminders = try XCTUnwrap(testObject(output.payload["appleReminders"]))
    let reminders = try XCTUnwrap(testArray(appleReminders["reminders"]))
    let reminder = try XCTUnwrap(testObject(reminders.first))
    XCTAssertEqual(reminder["id"], .string("reminder-1"))
    XCTAssertEqual(reminder["cursor"], .string("cursor-1"))
    XCTAssertEqual(output.when["has_reminders"], true)
  }

  func testReminderGetReturnsFoundAndNullWithoutProviderFailure() async throws {
    let foundFake = try FakeAppleReminderGateway(mode: "get")
    let nullFake = try FakeAppleReminderGateway(mode: "get-null")
    defer {
      foundFake.cleanup()
      nullFake.cleanup()
    }

    let found = try await runReminderAddon("riela/apple-reminder-get", fake: foundFake, config: ["reminderId": .string("reminder-1")])
    try assertReminderSelectionUsesGatewaySchema(foundFake)
    let foundPayload = try XCTUnwrap(testObject(found.payload["appleReminders"]))
    XCTAssertEqual(foundPayload["found"], .bool(true))

    let missing = try await runReminderAddon("riela/apple-reminder-get", fake: nullFake, config: ["reminderId": .string("missing")])
    let missingPayload = try XCTUnwrap(testObject(missing.payload["appleReminders"]))
    XCTAssertEqual(missingPayload["found"], .bool(false))
    XCTAssertEqual(missingPayload["reminder"], .null)
  }

  func testReminderMutationsBuildExpectedVariablesAndOutputs() async throws {
    let createListFake = try FakeAppleReminderGateway(mode: "list-create")
    let createFake = try FakeAppleReminderGateway(mode: "create")
    let updateFake = try FakeAppleReminderGateway(mode: "update")
    let deleteFake = try FakeAppleReminderGateway(mode: "delete")
    let completeFake = try FakeAppleReminderGateway(mode: "complete")
    let completeFalseFake = try FakeAppleReminderGateway(mode: "complete")
    let alarmsFake = try FakeAppleReminderGateway(mode: "alarms")
    defer {
      createListFake.cleanup()
      createFake.cleanup()
      updateFake.cleanup()
      deleteFake.cleanup()
      completeFake.cleanup()
      completeFalseFake.cleanup()
      alarmsFake.cleanup()
    }

    _ = try await runReminderAddon("riela/apple-reminder-list-create", fake: createListFake, config: ["title": .string("Work")])
    XCTAssertTrue(try String(contentsOf: createListFake.queryLogURL).contains("createReminderList"))
    XCTAssertEqual(try inputObject(createListFake)["title"], .string("Work"))

    _ = try await runReminderAddon(
      "riela/apple-reminder-create",
      fake: createFake,
      config: [
        "title": .string("Buy milk"),
        "dueDate": .string("2026-07-07T09:00:00Z"),
        "alarms": .array([.object(["relativeOffsetSeconds": .integer(-600)])])
      ]
    )
    try assertReminderSelectionUsesGatewaySchema(createFake)
    let createInput = try inputObject(createFake)
    XCTAssertEqual(createInput["priority"], .integer(0))
    XCTAssertNil(createInput["dueDateHasTime"])
    XCTAssertEqual(createInput["title"], .string("Buy milk"))
    XCTAssertEqual(createInput["dueDate"], .string("2026-07-07T09:00:00Z"))
    XCTAssertEqual(testArray(createInput["alarms"])?.count, 1)

    _ = try await runReminderAddon(
      "riela/apple-reminder-update",
      fake: updateFake,
      config: ["reminderId": .string("reminder-1"), "notes": .string("sparse")]
    )
    try assertReminderSelectionUsesGatewaySchema(updateFake)
    let updateInput = try inputObject(updateFake)
    XCTAssertEqual(updateInput["reminderId"], .string("reminder-1"))
    XCTAssertEqual(updateInput["notes"], .string("sparse"))
    XCTAssertNil(updateInput["title"])

    let delete = try await runReminderAddon("riela/apple-reminder-delete", fake: deleteFake, config: ["reminderId": .string("reminder-1")])
    try assertDeleteSelectionUsesGatewaySchema(deleteFake)
    let deletePayload = try XCTUnwrap(testObject(delete.payload["appleReminders"]))
    XCTAssertEqual(testObject(deletePayload["deleted"])?["reminderId"], .string("reminder-1"))
    XCTAssertEqual(testObject(deletePayload["deleted"])?["success"], .bool(true))

    _ = try await runReminderAddon("riela/apple-reminder-complete", fake: completeFake, config: ["reminderId": .string("reminder-1")])
    try assertReminderSelectionUsesGatewaySchema(completeFake)
    XCTAssertEqual(try variablesObject(completeFake)["completed"], .bool(true))

    _ = try await runReminderAddon(
      "riela/apple-reminder-complete",
      fake: completeFalseFake,
      config: ["reminderId": .string("reminder-1"), "completed": .bool(false)]
    )
    try assertReminderSelectionUsesGatewaySchema(completeFalseFake)
    XCTAssertEqual(try variablesObject(completeFalseFake)["completed"], .bool(false))

    _ = try await runReminderAddon(
      "riela/apple-reminder-alarms-set",
      fake: alarmsFake,
      config: ["reminderId": .string("reminder-1"), "alarms": .array([])]
    )
    try assertReminderSelectionUsesGatewaySchema(alarmsFake)
    XCTAssertEqual(try variablesObject(alarmsFake)["alarms"], .array([]))
  }

  func testAmbientPayloadCannotOverrideConfiguredMutationParameters() async throws {
    let updateFake = try FakeAppleReminderGateway(mode: "update")
    let deleteFake = try FakeAppleReminderGateway(mode: "delete")
    let completeFake = try FakeAppleReminderGateway(mode: "complete")
    defer {
      updateFake.cleanup()
      deleteFake.cleanup()
      completeFake.cleanup()
    }

    let ambientPayload: JSONObject = [
      "reminderId": .string("payload-reminder"),
      "notes": .string("payload-notes"),
      "completed": .bool(false)
    ]

    _ = try await runReminderAddon(
      "riela/apple-reminder-update",
      fake: updateFake,
      config: ["reminderId": .string("config-reminder"), "notes": .string("config-notes")],
      resolvedInputPayload: ambientPayload
    )
    let updateInput = try inputObject(updateFake)
    XCTAssertEqual(updateInput["reminderId"], .string("config-reminder"))
    XCTAssertEqual(updateInput["notes"], .string("config-notes"))

    _ = try await runReminderAddon(
      "riela/apple-reminder-delete",
      fake: deleteFake,
      config: ["reminderId": .string("config-reminder")],
      resolvedInputPayload: ambientPayload
    )
    XCTAssertEqual(try variablesObject(deleteFake)["reminderId"], .string("config-reminder"))

    _ = try await runReminderAddon(
      "riela/apple-reminder-complete",
      fake: completeFake,
      config: ["reminderId": .string("config-reminder"), "completed": .bool(true)],
      resolvedInputPayload: ambientPayload
    )
    let completeVariables = try variablesObject(completeFake)
    XCTAssertEqual(completeVariables["reminderId"], .string("config-reminder"))
    XCTAssertEqual(completeVariables["completed"], .bool(true))
  }

  func testExplicitAddonInputsCanRenderFromAmbientPayload() async throws {
    let fake = try FakeAppleReminderGateway(mode: "update")
    defer { fake.cleanup() }

    _ = try await runReminderAddon(
      "riela/apple-reminder-update",
      fake: fake,
      config: ["reminderId": .string("config-reminder")],
      inputs: ["reminderId": .string("{{reminderId}}"), "notes": .string("{{input.notes}}")],
      resolvedInputPayload: ["reminderId": .string("payload-reminder"), "notes": .string("payload-notes")]
    )

    let updateInput = try inputObject(fake)
    XCTAssertEqual(updateInput["reminderId"], .string("payload-reminder"))
    XCTAssertEqual(updateInput["notes"], .string("payload-notes"))
  }

  func testRenderedAddonInputStringsPreserveLiteralTemplateLikeText() async throws {
    let searchFake = try FakeAppleReminderGateway(mode: "search")
    let createFake = try FakeAppleReminderGateway(mode: "create")
    defer {
      searchFake.cleanup()
      createFake.cleanup()
    }

    let literalQuery = "review {{stepId}} and {{missing-template}} literally"
    _ = try await runReminderAddon(
      "riela/apple-reminders-list",
      fake: searchFake,
      inputs: ["query": .string("{{workflowInput.query}}")],
      variables: ["workflowInput": .object(["query": .string(literalQuery)])]
    )
    XCTAssertEqual(try inputObject(searchFake)["query"], .string(literalQuery))

    let literalTitle = "title with literal {{stepId}} and {{not.available}}"
    _ = try await runReminderAddon(
      "riela/apple-reminder-create",
      fake: createFake,
      inputs: ["title": .string("{{workflowInput.title}}")],
      variables: ["workflowInput": .object(["title": .string(literalTitle)])]
    )
    XCTAssertEqual(try inputObject(createFake)["title"], .string(literalTitle))
  }

  func testTemplatedScalarInputsMaterializeTypedVariables() async throws {
    let listFake = try FakeAppleReminderGateway(mode: "search")
    let createFake = try FakeAppleReminderGateway(mode: "create")
    let completeFake = try FakeAppleReminderGateway(mode: "complete")
    defer {
      listFake.cleanup()
      createFake.cleanup()
      completeFake.cleanup()
    }

    _ = try await runReminderAddon(
      "riela/apple-reminders-list",
      fake: listFake,
      inputs: ["first": .string("{{workflowInput.first}}")],
      variables: ["workflowInput": .object(["first": .integer(25)])]
    )
    let listInput = try inputObject(listFake)
    XCTAssertEqual(listInput["first"], .integer(25))

    _ = try await runReminderAddon(
      "riela/apple-reminder-create",
      fake: createFake,
      config: ["title": .string("Typed scalar")],
      inputs: [
        "priority": .string("{{workflowInput.priority}}"),
        "dueDateHasTime": .string("{{workflowInput.dueDateHasTime}}")
      ],
      variables: ["workflowInput": .object(["priority": .integer(7), "dueDateHasTime": .bool(false)])]
    )
    let createInput = try inputObject(createFake)
    XCTAssertEqual(createInput["priority"], .integer(7))
    XCTAssertEqual(createInput["dueDateHasTime"], .bool(false))

    _ = try await runReminderAddon(
      "riela/apple-reminder-complete",
      fake: completeFake,
      config: ["reminderId": .string("reminder-1")],
      inputs: ["completed": .string("{{workflowInput.completed}}")],
      variables: ["workflowInput": .object(["completed": .bool(false)])]
    )
    XCTAssertEqual(try variablesObject(completeFake)["completed"], .bool(false))
  }

  func testMalformedOptionalStringFieldsFailValidation() async throws {
    let fake = try FakeAppleReminderGateway(mode: "search")
    defer { fake.cleanup() }

    try await assertReminderFailure(
      "riela/apple-reminders-list",
      fake: fake,
      config: ["query": .integer(42)],
      code: .policyBlocked,
      messageContains: "query must be a string"
    )
    try await assertReminderFailure(
      "riela/apple-reminder-update",
      fake: fake,
      config: ["reminderId": .string("config-reminder"), "notes": .string("config-notes")],
      inputs: ["notes": .bool(false)],
      code: .policyBlocked,
      messageContains: "notes must be a string"
    )
    assertFakeGatewayWasNotInvoked(fake)
  }

  func testValidationFailuresDoNotSpawnGateway() async throws {
    let fake = try FakeAppleReminderGateway(mode: "create")
    defer { fake.cleanup() }

    try await assertReminderFailure(
      "riela/apple-reminder-create",
      fake: fake,
      config: [:],
      code: .policyBlocked,
      messageContains: "title is required"
    )
    try await assertReminderFailure(
      "riela/apple-reminders-list",
      fake: fake,
      config: ["status": .string("OPEN")],
      code: .policyBlocked,
      messageContains: "status must be"
    )
    try await assertReminderFailure(
      "riela/apple-reminders-list",
      fake: fake,
      config: ["first": .integer(0)],
      code: .policyBlocked,
      messageContains: "first must be between"
    )
    try await assertReminderFailure(
      "riela/apple-reminder-create",
      fake: fake,
      config: ["title": .string("Bad"), "priority": .integer(10)],
      code: .policyBlocked,
      messageContains: "priority must be between"
    )
    try await assertReminderFailure(
      "riela/apple-reminder-alarms-set",
      fake: fake,
      config: ["reminderId": .string("reminder-1"), "alarms": .array([.object(["label": .string("bad")])])],
      code: .policyBlocked,
      messageContains: "must include"
    )
    try await assertReminderFailure(
      "riela/apple-reminder-lists",
      fake: fake,
      version: "2",
      config: [:],
      code: .policyBlocked,
      messageContains: "unsupported"
    )
    try await assertReminderFailure(
      "riela/apple-reminder-lists",
      fake: fake,
      config: [:],
      env: ["TOKEN": .object(["fromEnv": .string("TOKEN")])],
      code: .policyBlocked,
      messageContains: "does not support addon.env"
    )
    assertFakeGatewayWasNotInvoked(fake)
  }

  func testGatewayErrorMappingAndMissingBinary() async throws {
    let graphqlErrorFake = try FakeAppleReminderGateway(mode: "graphql-error")
    let nonzeroFake = try FakeAppleReminderGateway(mode: "nonzero")
    let malformedFake = try FakeAppleReminderGateway(mode: "malformed")
    let missingFieldFake = try FakeAppleReminderGateway(mode: "missing-field")
    let deleteFalseFake = try FakeAppleReminderGateway(mode: "delete-false")
    defer {
      graphqlErrorFake.cleanup()
      nonzeroFake.cleanup()
      malformedFake.cleanup()
      missingFieldFake.cleanup()
      deleteFalseFake.cleanup()
    }

    try await assertReminderFailure("riela/apple-reminder-lists", fake: graphqlErrorFake, code: .providerError, messageContains: "reminders denied")
    try await assertReminderFailure("riela/apple-reminder-lists", fake: nonzeroFake, code: .providerError, messageContains: "exit code 9")
    try await assertReminderFailure("riela/apple-reminder-lists", fake: malformedFake, code: .invalidOutput, messageContains: "not valid JSON")
    try await assertReminderFailure("riela/apple-reminder-lists", fake: missingFieldFake, code: .invalidOutput, messageContains: "data.reminderLists")
    try await assertReminderFailure(
      "riela/apple-reminder-delete",
      fake: deleteFalseFake,
      config: ["reminderId": .string("missing-reminder")],
      code: .providerError,
      messageContains: "deleteReminder.success was false"
    )

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-apple-reminder-nonexec-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let nonExecutable = root.appendingPathComponent("apple-gateway")
    try Data("#!/bin/sh\n".utf8).write(to: nonExecutable)
    try await assertReminderFailure(
      "riela/apple-reminder-lists",
      environment: ["PATH": root.path],
      code: .policyBlocked,
      messageContains: "requires apple-gateway"
    )
  }

  func testDeadlineAndSharedBinaryResolutionAndSanitizedEnvironment() async throws {
    let configFake = try FakeAppleReminderGateway(mode: "lists", requestId: "config")
    let envFake = try FakeAppleReminderGateway(mode: "lists", requestId: "env")
    let pathFake = try FakeAppleReminderGateway(mode: "lists", requestId: "path", executableName: "apple-gateway")
    let sleepFake = try FakeAppleReminderGateway(mode: "sleep")
    defer {
      configFake.cleanup()
      envFake.cleanup()
      pathFake.cleanup()
      sleepFake.cleanup()
    }

    let configOutput = try await runReminderAddon(
      "riela/apple-reminder-lists",
      config: ["binaryPath": .string(configFake.executableURL.path)],
      environment: ["APPLE_GATEWAY_BIN": envFake.executableURL.path, "PATH": pathFake.binURL.path]
    )
    XCTAssertEqual(gatewayBinarySource(configOutput), "config")

    let envOutput = try await runReminderAddon(
      "riela/apple-reminder-lists",
      environment: [
        "APPLE_GATEWAY_BIN": envFake.executableURL.path,
        "PATH": pathFake.binURL.path,
        "OPENAI_API_KEY": "sentinel",
        "USER": "riela-test"
      ]
    )
    XCTAssertEqual(gatewayBinarySource(envOutput), "environment")
    let childEnvironment = try String(contentsOf: envFake.environmentLogURL)
    XCTAssertTrue(childEnvironment.contains("USER=riela-test"))
    XCTAssertFalse(childEnvironment.contains("sentinel"))

    let pathOutput = try await runReminderAddon("riela/apple-reminder-lists", environment: ["PATH": pathFake.binURL.path])
    XCTAssertEqual(gatewayBinarySource(pathOutput), "path")

    try await assertReminderFailure(
      "riela/apple-reminder-lists",
      fake: sleepFake,
      code: .timeout,
      messageContains: "deadline",
      context: AdapterExecutionContext(deadline: Date().addingTimeInterval(0.1))
    )
  }
}

private func runReminderAddon(
  _ addonName: String,
  fake: FakeAppleReminderGateway,
  version: String? = "1",
  config: JSONObject = [:],
  inputs: JSONObject = [:],
  variables: JSONObject = [:],
  resolvedInputPayload: JSONObject = [:],
  env: JSONObject? = nil,
  context: AdapterExecutionContext = AdapterExecutionContext()
) async throws -> AdapterExecutionOutput {
  var config = config
  config["binaryPath"] = .string(fake.executableURL.path)
  return try await runReminderAddon(
    addonName,
    version: version,
    config: config,
    inputs: inputs,
    variables: variables,
    resolvedInputPayload: resolvedInputPayload,
    env: env,
    environment: [:],
    context: context
  )
}

private func runReminderAddon(
  _ addonName: String,
  version: String? = "1",
  config: JSONObject = [:],
  inputs: JSONObject = [:],
  variables: JSONObject = [:],
  resolvedInputPayload: JSONObject = [:],
  env: JSONObject? = nil,
  environment: [String: String],
  context: AdapterExecutionContext = AdapterExecutionContext()
) async throws -> AdapterExecutionOutput {
  try await BuiltinWorkflowAddonResolver(environment: environment).execute(
    WorkflowAddonExecutionInput(
      workflowId: "apple-reminders",
      stepId: "apple-reminders-step",
      nodeId: "apple-reminders-node",
      addon: WorkflowNodeAddonRef(name: addonName, version: version, config: config, env: env, inputs: inputs),
      variables: variables,
      resolvedInputPayload: resolvedInputPayload
    ),
    context: context
  )
}

private func assertReminderFailure(
  _ addonName: String,
  fake: FakeAppleReminderGateway,
  version: String? = "1",
  config: JSONObject = [:],
  inputs: JSONObject = [:],
  env: JSONObject? = nil,
  code: AdapterExecutionErrorCode,
  messageContains: String,
  context: AdapterExecutionContext = AdapterExecutionContext()
) async throws {
  do {
    _ = try await runReminderAddon(
      addonName,
      fake: fake,
      version: version,
      config: config,
      inputs: inputs,
      env: env,
      context: context
    )
    XCTFail("expected Apple Reminders add-on to fail")
  } catch let error as AdapterExecutionError {
    XCTAssertEqual(error.code, code)
    XCTAssertTrue(error.message.contains(messageContains), error.message)
  }
}

private func assertReminderFailure(
  _ addonName: String,
  environment: [String: String],
  code: AdapterExecutionErrorCode,
  messageContains: String
) async throws {
  do {
    _ = try await runReminderAddon(addonName, environment: environment)
    XCTFail("expected Apple Reminders add-on to fail")
  } catch let error as AdapterExecutionError {
    XCTAssertEqual(error.code, code)
    XCTAssertTrue(error.message.contains(messageContains), error.message)
  }
}

private struct FakeAppleReminderGateway {
  var rootURL: URL
  var binURL: URL
  var executableURL: URL
  var argumentLogURL: URL
  var environmentLogURL: URL
  var queryLogURL: URL
  var variablesLogURL: URL

  init(mode: String, requestId: String = "req-reminders", executableName: String = "fake-apple-gateway") throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-apple-reminder-addon-\(UUID().uuidString)", isDirectory: true)
    binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
    executableURL = binURL.appendingPathComponent(executableName)
    argumentLogURL = rootURL.appendingPathComponent("args.log")
    environmentLogURL = rootURL.appendingPathComponent("environment.log")
    queryLogURL = rootURL.appendingPathComponent("query.graphql")
    variablesLogURL = rootURL.appendingPathComponent("variables.json")
    try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
    try script(mode: mode, requestId: requestId).write(to: executableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: rootURL)
  }

  private func script(mode: String, requestId: String) -> String {
    """
    #!/bin/sh
    printf "%s\\n%s\\n%s\\n" "$1" "$2" "$4" > "\(argumentLogURL.path)"
    printf "%s" "$3" > "\(queryLogURL.path)"
    printf "%s" "$5" > "\(variablesLogURL.path)"
    {
      printf "OPENAI_API_KEY=%s\\n" "${OPENAI_API_KEY:-}"
      printf "PATH=%s\\n" "${PATH:-}"
      printf "USER=%s\\n" "${USER:-}"
      } > "\(environmentLogURL.path)"
      case "\(mode)" in
        lists)
        /bin/cat <<'JSON'
    {
      "data": {
        "reminderLists": [{
          "id": "list-1",
          "title": "Work",
          "entityType": "calendar",
          "sourceTitle": "iCloud",
          "sourceType": "caldav",
          "colorHex": "#ff0000",
          "allowsModifications": true,
          "isSubscribed": false,
          "isDefault": true
        }]
      },
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
        ;;
      search)
        /bin/cat <<'JSON'
    {
      "data": {
        "reminders": {
          "totalCount": 1,
          "pageInfo": {"hasNextPage": false, "endCursor": null},
          "edges": [{
            "cursor": "cursor-1",
            "node": {
              "id": "reminder-1",
              "listId": "list-1",
              "title": "Project",
              "notes": null,
              "url": null,
              "completed": false,
              "priority": 0,
              "startDate": null,
              "dueDate": null,
              "dueDateHasTime": false,
              "completionDate": null,
              "creationDate": "2026-07-07T00:00:00Z",
              "modificationDate": "2026-07-07T01:00:00Z",
              "alarms": []
            }
          }]
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
        ;;
      get)
        printf '{"data":{"reminder":{"id":"reminder-1","listId":"list-1","title":"Project","completed":false,"priority":0,"alarms":[]}},"extensions":{"requestId":"\(requestId)"}}\\n'
        ;;
      get-null)
        printf '{"data":{"reminder":null},"extensions":{"requestId":"\(requestId)"}}\\n'
        ;;
      list-create)
        printf '{"data":{"createReminderList":{"id":"list-2","title":"Work","allowsModifications":true}},"extensions":{"requestId":"\(requestId)"}}\\n'
        ;;
      create)
        printf '{"data":{"createReminder":{"id":"reminder-2","title":"Buy milk","completed":false,"priority":0,"alarms":[]}},"extensions":{"requestId":"\(requestId)"}}\\n'
        ;;
      update)
        printf '{"data":{"updateReminder":{"id":"reminder-1","title":"Project","notes":"sparse","completed":false,"priority":0,"alarms":[]}},"extensions":{"requestId":"\(requestId)"}}\\n'
        ;;
      delete)
        printf '{"data":{"deleteReminder":{"success":true}},"extensions":{"requestId":"\(requestId)"}}\\n'
        ;;
      delete-false)
        printf '{"data":{"deleteReminder":{"success":false}},"extensions":{"requestId":"\(requestId)"}}\\n'
        ;;
      complete)
        printf '{"data":{"setReminderCompleted":{"id":"reminder-1","title":"Project","completed":true,"priority":0,"alarms":[]}},"extensions":{"requestId":"\(requestId)"}}\\n'
        ;;
      alarms)
        printf '{"data":{"setReminderAlarms":{"id":"reminder-1","title":"Project","completed":false,"priority":0,"alarms":[]}},"extensions":{"requestId":"\(requestId)"}}\\n'
        ;;
      graphql-error)
        printf '{"data":null,"errors":[{"message":"reminders denied"}],"extensions":{"requestId":"\(requestId)"}}\\n'
        ;;
      missing-field)
        printf '{"data":{},"extensions":{"requestId":"\(requestId)"}}\\n'
        ;;
      malformed)
        printf 'not-json\\n'
        ;;
      nonzero)
        echo 'upstream failed' >&2
        exit 9
        ;;
      sleep)
        sleep 5
        ;;
    esac
    """
  }
}

private func variablesObject(_ fake: FakeAppleReminderGateway) throws -> JSONObject {
  let data = try Data(contentsOf: fake.variablesLogURL)
  let value = try JSONDecoder().decode(JSONValue.self, from: data)
  return try XCTUnwrap(testObject(value))
}

private func inputObject(_ fake: FakeAppleReminderGateway) throws -> JSONObject {
  try XCTUnwrap(testObject(variablesObject(fake)["input"]))
}

private func gatewayBinarySource(_ output: AdapterExecutionOutput) -> String? {
  testObject(output.payload["appleGateway"])
    .flatMap { testObject($0["binary"]) }
    .flatMap { testString($0["source"]) }
}

private func assertFakeGatewayWasNotInvoked(_ fake: FakeAppleReminderGateway, file: StaticString = #filePath, line: UInt = #line) {
  let fileManager = FileManager.default
  for url in [fake.argumentLogURL, fake.environmentLogURL, fake.queryLogURL, fake.variablesLogURL] {
    XCTAssertFalse(fileManager.fileExists(atPath: url.path), "\(url.lastPathComponent) should not exist", file: file, line: line)
  }
}

private func assertReminderSelectionUsesGatewaySchema(_ fake: FakeAppleReminderGateway) throws {
  let query = try String(contentsOf: fake.queryLogURL)
  XCTAssertTrue(query.contains("completed: isCompleted"), query)
  XCTAssertTrue(query.contains("modificationDate: lastModifiedDate"), query)
  XCTAssertFalse(query.contains("\n      completed\n"), query)
  XCTAssertFalse(query.contains("\n      modificationDate\n"), query)
}

private func assertDeleteSelectionUsesGatewaySchema(_ fake: FakeAppleReminderGateway) throws {
  let query = try String(contentsOf: fake.queryLogURL)
  XCTAssertTrue(query.contains("deleteReminder(reminderId: $reminderId)"), query)
  XCTAssertTrue(query.contains("\n    success\n"), query)
  XCTAssertFalse(query.contains("\n    reminderId\n"), query)
  XCTAssertFalse(query.contains("\n      reminderId\n"), query)
}

private func testObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object)? = value else {
    return nil
  }
  return object
}

private func testArray(_ value: JSONValue?) -> [JSONValue]? {
  guard case let .array(array)? = value else {
    return nil
  }
  return array
}

private func testString(_ value: JSONValue?) -> String? {
  guard case let .string(string)? = value else {
    return nil
  }
  return string
}
