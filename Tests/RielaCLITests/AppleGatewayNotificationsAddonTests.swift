import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class AppleGatewayNotificationsAddonTests: XCTestCase {
  func testNotificationsListBuildsQueryAndParsesEnvelope() async throws {
    let fake = try NotificationsFakeAppleGateway(requestId: "req-list", mode: "list-success")
    defer { fake.cleanup() }

    let output = try await runNotificationAddon(
      "riela/apple-notifications-list",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "source": .string("GATEWAY_HELPER"),
        "first": .integer(2)
      ],
      inputs: ["appBundleId": .string("com.example.app")]
    )

    XCTAssertEqual(try String(contentsOf: fake.argumentLogURL), "graphql\n--query\n")
    let query = try String(contentsOf: fake.queryLogURL)
    XCTAssertTrue(query.contains("notifications(input: {first: 2, source: GATEWAY_HELPER, appBundleId: \"com.example.app\"})"), query)
    XCTAssertTrue(query.contains("deliveredAt"), query)

    let appleNotifications = try XCTUnwrap(notificationTestObject(output.payload["appleNotifications"]))
    let notifications = try XCTUnwrap(notificationTestArray(appleNotifications["notifications"]))
    let notification = try XCTUnwrap(notificationTestObject(notifications.first))
    XCTAssertEqual(notification["id"], .string("notification-1"))
    XCTAssertEqual(notification["cursor"], .string("cursor-1"))
    XCTAssertEqual(appleNotifications["totalCount"], .integer(1))
    XCTAssertEqual(appleNotifications["requestId"], .string("req-list"))
    XCTAssertEqual(output.payload["notificationCount"], .integer(1))
    XCTAssertEqual(output.when["has_notifications"], true)
    XCTAssertEqual(gatewayBinarySource(output), "config")
  }

  func testNotificationPostBuildsMutationAndExposesPostedId() async throws {
    let fake = try NotificationsFakeAppleGateway(requestId: "req-post", mode: "post-success")
    defer { fake.cleanup() }

    let output = try await runNotificationAddon(
      "riela/apple-notification-post",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "title": .string("Deploy {{target}}"),
        "subtitle": .string("Riela"),
        "body": .string("Ready"),
        "sound": .bool(true),
        "actions": .array([.string("Open"), .string("Reply {{target}}")]),
        "allowReply": .bool(true),
        "waitSeconds": .integer(12),
        "allowFallback": .bool(true)
      ],
      variables: ["target": .string("prod")]
    )

    let query = try String(contentsOf: fake.queryLogURL)
    let expectedInput = "postNotification(input: {title: \"Deploy prod\", subtitle: \"Riela\", body: \"Ready\", "
      + "sound: true, actions: [\"Open\", \"Reply prod\"], allowReply: true, waitSeconds: 12, allowFallback: true})"
    XCTAssertTrue(query.contains(expectedInput), query)
    XCTAssertEqual(output.payload["postedNotificationId"], .string("posted-1"))
    XCTAssertEqual(output.when["delivered"], true)
    XCTAssertEqual(output.when["used_fallback"], false)
    let appleNotification = try XCTUnwrap(notificationTestObject(output.payload["appleNotification"]))
    let posted = try XCTUnwrap(notificationTestObject(appleNotification["posted"]))
    XCTAssertEqual(posted["id"], .string("posted-1"))
    XCTAssertEqual(posted["delivered"], .bool(true))
    XCTAssertEqual(posted["usedFallback"], .bool(false))
    let activation = try XCTUnwrap(notificationTestObject(posted["activation"]))
    XCTAssertEqual(activation["kind"], .string("ACTION"))
    XCTAssertEqual(activation["actionLabel"], .string("Open"))
    XCTAssertEqual(activation["replyText"], .string("ack"))
  }

  func testNotificationPostParsesFallbackResult() async throws {
    let fake = try NotificationsFakeAppleGateway(requestId: "req-fallback", mode: "post-fallback")
    defer { fake.cleanup() }

    let output = try await runNotificationAddon(
      "riela/apple-notification-post",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "title": .string("Fallback demo"),
        "sound": .bool(false),
        "allowFallback": .bool(true)
      ]
    )

    XCTAssertTrue(try String(contentsOf: fake.queryLogURL).contains("sound: false"))
    XCTAssertEqual(output.payload["postedNotificationId"], .string("posted-fallback"))
    XCTAssertEqual(output.when["delivered"], false)
    XCTAssertEqual(output.when["used_fallback"], true)
  }

  func testNotificationsDismissBuildsIdAndAllMutations() async throws {
    let idsFake = try NotificationsFakeAppleGateway(requestId: "req-dismiss", mode: "dismiss-success")
    let allFake = try NotificationsFakeAppleGateway(requestId: "req-dismiss-all", mode: "dismiss-all-success")
    defer {
      idsFake.cleanup()
      allFake.cleanup()
    }

    let idsOutput = try await runNotificationAddon(
      "riela/apple-notifications-dismiss",
      config: ["binaryPath": .string(idsFake.executableURL.path)],
      inputs: ["ids": .array([.string("{{postedId}}")])],
      variables: ["postedId": .string("posted-1")]
    )
    XCTAssertTrue(try String(contentsOf: idsFake.queryLogURL).contains("dismissNotifications(ids: [\"posted-1\"])"))
    let idsPayload = try XCTUnwrap(notificationTestObject(idsOutput.payload["appleNotifications"]))
    XCTAssertEqual(idsPayload["dismissedCount"], .integer(1))
    XCTAssertEqual(idsPayload["mode"], .string("ids"))
    XCTAssertEqual(idsOutput.payload["dismissedCount"], .integer(1))

    let allOutput = try await runNotificationAddon(
      "riela/apple-notifications-dismiss",
      config: [
        "binaryPath": .string(allFake.executableURL.path),
        "all": .bool(true)
      ]
    )
    XCTAssertTrue(try String(contentsOf: allFake.queryLogURL).contains("dismissAllGatewayNotifications"))
    let allPayload = try XCTUnwrap(notificationTestObject(allOutput.payload["appleNotifications"]))
    XCTAssertEqual(allPayload["dismissedCount"], .integer(3))
    XCTAssertEqual(allPayload["mode"], .string("all"))
  }

  func testAppleNotificationsExampleDismissesPostedNotificationId() async throws {
    let fake = try NotificationsFakeAppleGateway(requestId: "req-example", mode: "example-workflow")
    let sessionStore = notificationsRepositoryTmpRoot()
      .appendingPathComponent("riela-apple-notifications-sessions-\(UUID().uuidString)", isDirectory: true)
    defer {
      fake.cleanup()
      try? FileManager.default.removeItem(at: sessionStore)
    }

    let result = await RielaCLIApplication().run([
      "workflow", "run", "apple-notifications",
      "--workflow-definition-dir", notificationsRepositoryRoot().appendingPathComponent("examples", isDirectory: true).path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ], environment: ["APPLE_GATEWAY_BIN": fake.executableURL.path])

    XCTAssertEqual(result.exitCode, .success, "\(result.stderr)\n\(result.stdout)")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(payload.status, .completed)
    let dismissOutput = try XCTUnwrap(
      payload.session.executions.first { $0.stepId == "dismiss-posted-notification" }?.acceptedOutput?.payload
    )
    XCTAssertEqual(dismissOutput["dismissedCount"], .integer(1))

    let queryHistory = try String(contentsOf: fake.queryHistoryLogURL)
    XCTAssertTrue(queryHistory.contains("postNotification(input:"), queryHistory)
    XCTAssertTrue(queryHistory.contains("dismissNotifications(ids: [\"posted-example\"])"), queryHistory)
    XCTAssertFalse(queryHistory.contains("dismissAllGatewayNotifications"), queryHistory)
  }

  func testNotificationsValidateAuthoredInputsBeforeExecution() async throws {
    let fake = try NotificationsFakeAppleGateway(requestId: "validation", mode: "post-success")
    defer { fake.cleanup() }
    let binaryConfig: JSONObject = ["binaryPath": .string(fake.executableURL.path)]

    try await assertNotificationFailure(
      "riela/apple-notification-post",
      config: binaryConfig,
      code: .policyBlocked,
      messageContains: "title is required"
    )
    try await assertNotificationFailure(
      "riela/apple-notification-post",
      config: binaryConfig.merging(["title": .string("x"), "waitSeconds": .integer(301)]) { _, new in new },
      code: .policyBlocked,
      messageContains: "waitSeconds must be between 0 and 300"
    )
    try await assertNotificationFailure(
      "riela/apple-notification-post",
      config: binaryConfig.merging(["title": .string("x"), "sound": .string("yes")]) { _, new in new },
      code: .policyBlocked,
      messageContains: "sound must be a boolean"
    )
    try await assertNotificationFailure(
      "riela/apple-notification-post",
      config: binaryConfig.merging(["title": .string("x"), "actions": .array([.integer(1)])]) { _, new in new },
      code: .policyBlocked,
      messageContains: "actions[0] must be a string"
    )
    try await assertNotificationFailure(
      "riela/apple-notifications-list",
      config: binaryConfig.merging(["source": .string("DATABASE")]) { _, new in new },
      code: .policyBlocked,
      messageContains: "source must be GATEWAY_HELPER or SYSTEM_DB"
    )
    try await assertNotificationFailure(
      "riela/apple-notifications-dismiss",
      config: binaryConfig,
      code: .policyBlocked,
      messageContains: "requires exactly one"
    )
    try await assertNotificationFailure(
      "riela/apple-notifications-dismiss",
      config: binaryConfig.merging(["all": .bool(true), "ids": .array([.string("posted-1")])]) { _, new in new },
      code: .policyBlocked,
      messageContains: "requires exactly one"
    )
    try await assertNotificationFailure(
      "riela/apple-notifications-dismiss",
      config: binaryConfig.merging(["ids": .array([.string("   ")])]) { _, new in new },
      code: .policyBlocked,
      messageContains: "requires exactly one"
    )
  }

  func testNotificationsRejectUnsupportedVersionAndAddonEnv() async throws {
    let fake = try NotificationsFakeAppleGateway(requestId: "policy", mode: "list-success")
    defer { fake.cleanup() }

    try await assertNotificationFailure(
      "riela/apple-notifications-list",
      version: "2",
      config: ["binaryPath": .string(fake.executableURL.path)],
      code: .policyBlocked,
      messageContains: "unsupported riela/apple-notifications-list version '2'"
    )
    try await assertNotificationFailure(
      "riela/apple-notifications-list",
      config: ["binaryPath": .string(fake.executableURL.path)],
      env: ["TOKEN": .object(["fromEnv": .string("TOKEN")])],
      code: .policyBlocked,
      messageContains: "does not support addon.env"
    )
  }

  func testNotificationsBinaryPrecedenceIgnoresInputsAndPayloadBinaryPath() async throws {
    let configFake = try NotificationsFakeAppleGateway(requestId: "config", mode: "list-success")
    let envFake = try NotificationsFakeAppleGateway(requestId: "env", mode: "list-success")
    let pathFake = try NotificationsFakeAppleGateway(requestId: "path", executableName: "apple-gateway", mode: "list-success")
    let maliciousFake = try NotificationsFakeAppleGateway(requestId: "malicious", mode: "list-success")
    defer {
      configFake.cleanup()
      envFake.cleanup()
      pathFake.cleanup()
      maliciousFake.cleanup()
    }

    let configOutput = try await runNotificationAddon(
      "riela/apple-notifications-list",
      config: ["binaryPath": .string(configFake.executableURL.path)],
      environment: ["APPLE_GATEWAY_BIN": envFake.executableURL.path, "PATH": pathFake.binURL.path]
    )
    XCTAssertEqual(gatewayBinarySource(configOutput), "config")
    XCTAssertEqual(requestId(configOutput), "config")

    let envOutput = try await runNotificationAddon(
      "riela/apple-notifications-list",
      environment: ["APPLE_GATEWAY_BIN": envFake.executableURL.path, "PATH": pathFake.binURL.path]
    )
    XCTAssertEqual(gatewayBinarySource(envOutput), "environment")
    XCTAssertEqual(requestId(envOutput), "env")

    let pathOutput = try await runNotificationAddon(
      "riela/apple-notifications-list",
      inputs: ["binaryPath": .string("{{binaryPath}}")],
      environment: ["PATH": pathFake.binURL.path],
      variables: ["binaryPath": .string(maliciousFake.executableURL.path)],
      resolvedInputPayload: ["binaryPath": .string(maliciousFake.executableURL.path)]
    )
    XCTAssertEqual(gatewayBinarySource(pathOutput), "path")
    XCTAssertEqual(requestId(pathOutput), "path")
    XCTAssertFalse(FileManager.default.fileExists(atPath: maliciousFake.argumentLogURL.path))
  }

  func testNotificationsDoNotForwardSecretLikeEnvironment() async throws {
    let fake = try NotificationsFakeAppleGateway(requestId: "env", mode: "list-success")
    defer { fake.cleanup() }

    _ = try await runNotificationAddon(
      "riela/apple-notifications-list",
      config: ["binaryPath": .string(fake.executableURL.path)],
      environment: [
        "HOME": "/tmp/riela-home",
        "OPENAI_API_KEY": "sentinel-openai",
        "GITHUB_TOKEN": "sentinel-github",
        "RIELA_SECRET": "sentinel-riela",
        "PATH": "/usr/bin:/bin",
        "TMPDIR": "/tmp",
        "USER": "riela-test"
      ]
    )

    let childEnvironment = try String(contentsOf: fake.environmentLogURL)
    XCTAssertTrue(childEnvironment.contains("PATH=/usr/bin:/bin"))
    XCTAssertTrue(childEnvironment.contains("USER=riela-test"))
    XCTAssertFalse(childEnvironment.contains("sentinel-openai"))
    XCTAssertFalse(childEnvironment.contains("sentinel-github"))
    XCTAssertFalse(childEnvironment.contains("sentinel-riela"))
  }

  func testNotificationsMapProviderAndOutputFailures() async throws {
    let helperFake = try NotificationsFakeAppleGateway(requestId: "helper", mode: "helper-unavailable")
    let fullDiskFake = try NotificationsFakeAppleGateway(requestId: "full-disk", mode: "full-disk")
    let nonzeroFake = try NotificationsFakeAppleGateway(requestId: "nonzero", mode: "nonzero")
    let malformedFake = try NotificationsFakeAppleGateway(requestId: "malformed", mode: "malformed")
    let missingDataFake = try NotificationsFakeAppleGateway(requestId: "missing-data", mode: "missing-data")
    let missingMutationFake = try NotificationsFakeAppleGateway(requestId: "missing-mutation", mode: "missing-mutation")
    defer {
      helperFake.cleanup()
      fullDiskFake.cleanup()
      nonzeroFake.cleanup()
      malformedFake.cleanup()
      missingDataFake.cleanup()
      missingMutationFake.cleanup()
    }

    try await assertNotificationFailure(
      "riela/apple-notification-post",
      config: ["binaryPath": .string(helperFake.executableURL.path), "title": .string("x")],
      code: .providerError,
      messageContains: "AppleGatewayNotifier.app; run `apple-gateway permissions status --json`"
    )
    try await assertNotificationFailure(
      "riela/apple-notifications-list",
      config: ["binaryPath": .string(fullDiskFake.executableURL.path), "source": .string("SYSTEM_DB")],
      code: .providerError,
      messageContains: "grant Full Disk Access"
    )
    try await assertNotificationFailure(
      "riela/apple-notifications-list",
      config: ["binaryPath": .string(nonzeroFake.executableURL.path)],
      code: .providerError,
      messageContains: "exit code 7"
    )
    try await assertNotificationFailure(
      "riela/apple-notifications-list",
      config: ["binaryPath": .string(malformedFake.executableURL.path)],
      code: .invalidOutput,
      messageContains: "not valid JSON"
    )
    try await assertNotificationFailure(
      "riela/apple-notifications-list",
      config: ["binaryPath": .string(missingDataFake.executableURL.path)],
      code: .invalidOutput,
      messageContains: "GraphQL data is missing"
    )
    try await assertNotificationFailure(
      "riela/apple-notification-post",
      config: ["binaryPath": .string(missingMutationFake.executableURL.path), "title": .string("x")],
      code: .invalidOutput,
      messageContains: "GraphQL data.postNotification is missing"
    )
  }

  func testNotificationPostHonorsDeadlineTimeout() async throws {
    let fake = try NotificationsFakeAppleGateway(requestId: "sleep", mode: "sleep")
    defer { fake.cleanup() }

    let startedAt = Date()
    try await assertNotificationFailure(
      "riela/apple-notification-post",
      config: ["binaryPath": .string(fake.executableURL.path), "title": .string("x"), "waitSeconds": .integer(1)],
      code: .timeout,
      messageContains: "deadline",
      context: AdapterExecutionContext(deadline: Date().addingTimeInterval(0.1))
    )
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
  }

  private func runNotificationAddon(
    _ addonName: String,
    version: String = "1",
    config: JSONObject = [:],
    env: JSONObject? = nil,
    inputs: JSONObject = [:],
    environment: [String: String] = [:],
    variables: JSONObject = [:],
    resolvedInputPayload: JSONObject = [:],
    context: AdapterExecutionContext = AdapterExecutionContext()
  ) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(environment: environment).execute(
      WorkflowAddonExecutionInput(
        workflowId: "apple-notifications",
        stepId: "apple-notifications-step",
        nodeId: "apple-notifications-step",
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

  private func assertNotificationFailure(
    _ addonName: String,
    version: String = "1",
    config: JSONObject = [:],
    env: JSONObject? = nil,
    inputs: JSONObject = [:],
    code: AdapterExecutionErrorCode,
    messageContains: String,
    context: AdapterExecutionContext = AdapterExecutionContext()
  ) async throws {
    do {
      _ = try await runNotificationAddon(
        addonName,
        version: version,
        config: config,
        env: env,
        inputs: inputs,
        context: context
      )
      XCTFail("expected Apple Notifications add-on to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, code)
      XCTAssertTrue(error.message.contains(messageContains), error.message)
    }
  }

  private func gatewayBinarySource(_ output: AdapterExecutionOutput) -> String? {
    notificationTestObject(output.payload["appleGateway"])
      .flatMap { notificationTestObject($0["binary"]) }
      .flatMap { notificationTestString($0["source"]) }
  }

  private func requestId(_ output: AdapterExecutionOutput) -> String? {
    notificationTestObject(output.payload["appleNotifications"]).flatMap { notificationTestString($0["requestId"]) }
  }
}

private struct NotificationsFakeAppleGateway {
  var rootURL: URL
  var binURL: URL
  var executableURL: URL
  var argumentLogURL: URL
  var environmentLogURL: URL
  var queryLogURL: URL
  var queryHistoryLogURL: URL

  init(requestId: String, executableName: String = "fake-apple-gateway", mode: String) throws {
    let tmpRoot = notificationsRepositoryTmpRoot()
    try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    rootURL = tmpRoot
      .appendingPathComponent("riela-apple-notifications-\(UUID().uuidString)", isDirectory: true)
    binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
    executableURL = binURL.appendingPathComponent(executableName)
    argumentLogURL = rootURL.appendingPathComponent("args.log")
    environmentLogURL = rootURL.appendingPathComponent("environment.log")
    queryLogURL = rootURL.appendingPathComponent("query.graphql")
    queryHistoryLogURL = rootURL.appendingPathComponent("queries.graphql")
    try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
    try script(requestId: requestId, mode: mode).write(to: executableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: rootURL)
  }

  private func script(requestId: String, mode: String) -> String {
    """
    #!/bin/sh
    printf "%s\\n%s\\n" "$1" "$2" > "\(argumentLogURL.path)"
    printf "%s" "$3" > "\(queryLogURL.path)"
    {
      printf "OPENAI_API_KEY=%s\\n" "${OPENAI_API_KEY:-}"
      printf "GITHUB_TOKEN=%s\\n" "${GITHUB_TOKEN:-}"
      printf "RIELA_SECRET=%s\\n" "${RIELA_SECRET:-}"
      printf "PATH=%s\\n" "${PATH:-}"
      printf "USER=%s\\n" "${USER:-}"
    } > "\(environmentLogURL.path)"
    printf "%s\\n---\\n" "$3" >> "\(queryHistoryLogURL.path)"
    case "\(mode)" in
      example-workflow)
        case "$3" in
          *postNotification*)
            /bin/cat <<'JSON'
    {
      "data": {
        "postNotification": {
          "id": "posted-example",
          "delivered": true,
          "usedFallback": false,
          "activation": null
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
            ;;
          *dismissNotifications*posted-example*)
            printf '{"data":{"dismissNotifications":{"dismissedCount":1}},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
            ;;
          *dismissNotifications*)
            printf '{"data":null,"errors":[{"message":"dismiss missing posted-example id"}],"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
            ;;
          *)
            printf '{"data":null,"errors":[{"message":"unexpected query"}],"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
            ;;
        esac
        ;;
      list-success)
        /bin/cat <<'JSON'
    {
      "data": {
        "notifications": {
          "totalCount": 1,
          "pageInfo": {"hasNextPage": false, "endCursor": null},
          "edges": [{
            "cursor": "cursor-1",
            "node": {
              "id": "notification-1",
              "source": "GATEWAY_HELPER",
              "appBundleId": "com.example.app",
              "title": "Build complete",
              "subtitle": "Riela",
              "body": "Done",
              "deliveredAt": "2026-07-07T00:00:00Z"
            }
          }]
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
        ;;
      post-success)
        /bin/cat <<'JSON'
    {
      "data": {
        "postNotification": {
          "id": "posted-1",
          "delivered": true,
          "usedFallback": false,
          "activation": {"kind": "ACTION", "actionLabel": "Open", "replyText": "ack"}
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
        ;;
      post-fallback)
        /bin/cat <<'JSON'
    {
      "data": {
        "postNotification": {
          "id": "posted-fallback",
          "delivered": false,
          "usedFallback": true,
          "activation": null
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
        ;;
      dismiss-success)
        printf '{"data":{"dismissNotifications":{"dismissedCount":1}},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      dismiss-all-success)
        printf '{"data":{"dismissAllGatewayNotifications":{"dismissedCount":3}},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      helper-unavailable)
        printf '{"data":null,"errors":[{"message":"AppleGatewayNotifier helper unavailable"}],"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      full-disk)
        printf '{"data":null,"errors":[{"message":"notification DB requires Full Disk Access"}],"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      missing-data)
        printf '{"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      missing-mutation)
        printf '{"data":{},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      malformed)
        printf 'not-json\\n'
        ;;
      nonzero)
        echo 'upstream denied' >&2
        exit 7
        ;;
      sleep)
        sleep 5
        ;;
    esac
    """
  }
}

private func notificationTestObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object)? = value else {
    return nil
  }
  return object
}

private func notificationTestArray(_ value: JSONValue?) -> [JSONValue]? {
  guard case let .array(array)? = value else {
    return nil
  }
  return array
}

private func notificationTestString(_ value: JSONValue?) -> String? {
  guard case let .string(string)? = value else {
    return nil
  }
  return string
}

private func notificationsRepositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

private func notificationsRepositoryTmpRoot() -> URL {
  notificationsRepositoryRoot().appendingPathComponent("tmp", isDirectory: true)
}
