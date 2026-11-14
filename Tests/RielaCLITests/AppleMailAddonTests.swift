import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class AppleMailAddonTests: XCTestCase {
  func testAppleMailListBuildsQueryAndParsesMetadata() async throws {
    let fake = try FakeAppleMailGateway(mode: "list-success", requestId: "req-list")
    defer { fake.cleanup() }

    let output = try await runAppleMail(
      name: "riela/apple-mail-list",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "first": .integer(2),
        "query": .string("quarterly")
      ],
      addonInputs: [
        "mailboxId": .string("{{mailboxId}}"),
        "unreadOnly": .string("{{unreadOnly}}")
      ],
      variables: ["mailboxId": .string("mailbox-1"), "unreadOnly": .bool(true)]
    )

    let query = try String(contentsOf: fake.queryLogURL)
    XCTAssertTrue(query.contains("permissions { mailFullDiskAccess }"))
    XCTAssertTrue(query.contains("mailAccounts"))
    XCTAssertTrue(query.contains("mailboxes"))
    XCTAssertTrue(query.contains("mailMessages(input: {first: 2, mailboxId: \"mailbox-1\", query: \"quarterly\", unreadOnly: true})"))
    let appleMail = try XCTUnwrap(testObject(output.payload["appleMail"]))
    XCTAssertEqual(testArray(appleMail["accounts"])?.count, 1)
    XCTAssertEqual(testArray(appleMail["mailboxes"])?.count, 1)
    let messages = try XCTUnwrap(testArray(appleMail["messages"]))
    let message = try XCTUnwrap(testObject(messages.first))
    XCTAssertEqual(message["id"], .string("mail-1"))
    XCTAssertEqual(message["cursor"], .string("cursor-1"))
    XCTAssertEqual(appleMail["totalCount"], .integer(1))
    XCTAssertEqual(output.payload["messageCount"], .integer(1))
    XCTAssertEqual(output.when["has_messages"], true)
  }

  func testAppleMailBinaryResolutionAndEnvironmentFiltering() async throws {
    let configFake = try FakeAppleMailGateway(mode: "list-success", requestId: "config")
    let envFake = try FakeAppleMailGateway(mode: "list-success", requestId: "env")
    let pathFake = try FakeAppleMailGateway(mode: "list-success", requestId: "path", executableName: "apple-gateway")
    defer {
      configFake.cleanup()
      envFake.cleanup()
      pathFake.cleanup()
    }

    let configOutput = try await runAppleMail(
      name: "riela/apple-mail-list",
      config: ["binaryPath": .string(configFake.executableURL.path)],
      environment: ["APPLE_GATEWAY_BIN": envFake.executableURL.path, "PATH": pathFake.binURL.path]
    )
    XCTAssertEqual(binarySource(configOutput), "config")
    XCTAssertEqual(requestId(configOutput), "config")

    let envOutput = try await runAppleMail(
      name: "riela/apple-mail-list",
      environment: ["APPLE_GATEWAY_BIN": envFake.executableURL.path, "PATH": pathFake.binURL.path]
    )
    XCTAssertEqual(binarySource(envOutput), "environment")
    XCTAssertEqual(requestId(envOutput), "env")

    let pathOutput = try await runAppleMail(
      name: "riela/apple-mail-list",
      environment: [
        "PATH": pathFake.binURL.path,
        "OPENAI_API_KEY": "sentinel-openai",
        "GITHUB_TOKEN": "sentinel-github",
        "USER": "riela-test"
      ]
    )
    XCTAssertEqual(binarySource(pathOutput), "path")
    let childEnvironment = try String(contentsOf: pathFake.environmentLogURL)
    XCTAssertTrue(childEnvironment.contains("USER=riela-test"))
    XCTAssertFalse(childEnvironment.contains("sentinel-openai"))
    XCTAssertFalse(childEnvironment.contains("sentinel-github"))
  }

  func testAppleMailDoesNotResolveBinaryPathFromInputsVariablesOrPayload() async throws {
    let maliciousFake = try FakeAppleMailGateway(mode: "list-success", requestId: "payload")
    let envFake = try FakeAppleMailGateway(mode: "list-success", requestId: "env")
    defer {
      maliciousFake.cleanup()
      envFake.cleanup()
    }

    let output = try await runAppleMail(
      name: "riela/apple-mail-list",
      addonInputs: ["binaryPath": .string("{{binaryPath}}")],
      environment: ["APPLE_GATEWAY_BIN": envFake.executableURL.path],
      variables: ["binaryPath": .string(maliciousFake.executableURL.path)],
      resolvedInputPayload: ["binaryPath": .string(maliciousFake.executableURL.path)]
    )

    XCTAssertEqual(binarySource(output), "environment")
    XCTAssertEqual(requestId(output), "env")
    XCTAssertFalse(FileManager.default.fileExists(atPath: maliciousFake.argumentLogURL.path))
  }

  func testAppleMailMapsFullDiskAccessDenialToPolicyBlocked() async throws {
    let denied = try FakeAppleMailGateway(mode: "fda-denied", requestId: "denied")
    let notDetermined = try FakeAppleMailGateway(mode: "fda-not-determined", requestId: "not-determined")
    defer {
      denied.cleanup()
      notDetermined.cleanup()
    }

    try await assertMailFailure(
      name: "riela/apple-mail-list",
      config: ["binaryPath": .string(denied.executableURL.path)],
      code: .policyBlocked,
      messageContains: "Full Disk Access"
    )
    try await assertMailFailure(
      name: "riela/apple-mail-list",
      config: ["binaryPath": .string(notDetermined.executableURL.path)],
      code: .policyBlocked,
      messageContains: "Full Disk Access"
    )
  }

  func testAppleMailErrorMappingForProviderInvalidOutputMissingBinaryAndTimeout() async throws {
    let graphqlError = try FakeAppleMailGateway(mode: "graphql-error", requestId: "graphql-error")
    let malformed = try FakeAppleMailGateway(mode: "malformed", requestId: "malformed")
    let missingData = try FakeAppleMailGateway(mode: "missing-data", requestId: "missing-data")
    let sleep = try FakeAppleMailGateway(mode: "sleep", requestId: "sleep")
    defer {
      graphqlError.cleanup()
      malformed.cleanup()
      missingData.cleanup()
      sleep.cleanup()
    }

    try await assertMailFailure(
      name: "riela/apple-mail-list",
      config: ["binaryPath": .string(graphqlError.executableURL.path)],
      code: .providerError,
      messageContains: "upstream mail failure"
    )
    try await assertMailFailure(
      name: "riela/apple-mail-list",
      config: ["binaryPath": .string(malformed.executableURL.path)],
      code: .invalidOutput,
      messageContains: "not valid JSON"
    )
    try await assertMailFailure(
      name: "riela/apple-mail-list",
      config: ["binaryPath": .string(missingData.executableURL.path)],
      code: .invalidOutput,
      messageContains: "GraphQL data is missing"
    )
    try await assertMailFailure(
      name: "riela/apple-mail-list",
      environment: ["PATH": FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path],
      code: .policyBlocked,
      messageContains: "requires apple-gateway"
    )
    try await assertMailFailure(
      name: "riela/apple-mail-list",
      config: ["binaryPath": .string(sleep.executableURL.path)],
      code: .timeout,
      messageContains: "deadline",
      context: AdapterExecutionContext(deadline: Date().addingTimeInterval(0.1))
    )
  }

  func testAppleMailMessageMaterializesSelectedFilesAndSkipsOversize() async throws {
    let fake = try FakeAppleMailGateway(mode: "message-success", requestId: "req-message")
    let downloadRoot = fake.rootURL.appendingPathComponent("tmp/downloads", isDirectory: true)
    defer { fake.cleanup() }

    let output = try await runAppleMail(
      name: "riela/apple-mail-message",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "messageId": .string("message-1"),
        "downloadDir": .string(downloadRoot.path),
        "materializeBodyText": .bool(true),
        "materializeAttachments": .bool(true),
        "maxDownloadBytes": .integer(25)
      ]
    )

    let appleMail = try XCTUnwrap(testObject(output.payload["appleMail"]))
    let materialized = try XCTUnwrap(testArray(appleMail["materialized"]))
    XCTAssertEqual(materialized.count, 2)
    let paths = materialized.compactMap { testObject($0).flatMap { testString($0["localPath"]) } }
    XCTAssertEqual(try String(contentsOfFile: paths[0]), "downloaded-body-key")
    XCTAssertEqual(try String(contentsOfFile: paths[1]), "downloaded-attachment-ok")
    XCTAssertTrue(paths.allSatisfy { $0.hasPrefix(downloadRoot.path + "/") })
    XCTAssertTrue(paths.contains { $0.hasSuffix("escape.txt") })
    let skipped = try XCTUnwrap(testArray(appleMail["skippedDownloads"]))
    XCTAssertEqual(skipped.count, 1)
    XCTAssertEqual(testObject(skipped.first)?["reason"], .string("exceeds_maxDownloadBytes"))
    XCTAssertEqual(output.when["found"], true)
    let downloadLog = try String(contentsOf: fake.downloadLogURL)
    XCTAssertTrue(downloadLog.contains("body-key"))
    XCTAssertTrue(downloadLog.contains("attachment-ok"))
    XCTAssertFalse(downloadLog.contains("attachment-big"))
  }

  func testAppleMailMessageAcceptsPrivateRuntimeDownloadDir() async throws {
    let fake = try FakeAppleMailGateway(mode: "message-success", requestId: "runtime-root")
    let downloadRoot = fake.rootURL
      .appendingPathComponent("tmp/.riela-data/apple-mail-addon-\(UUID().uuidString)", isDirectory: true)
    defer { fake.cleanup() }

    let output = try await runAppleMail(
      name: "riela/apple-mail-message",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "messageId": .string("message-1"),
        "downloadDir": .string(downloadRoot.path)
      ]
    )

    let appleMail = try XCTUnwrap(testObject(output.payload["appleMail"]))
    let materialized = try XCTUnwrap(testArray(appleMail["materialized"]))
    XCTAssertEqual(materialized.count, 1)
    let entry = try XCTUnwrap(testObject(materialized.first))
    let localPath = try XCTUnwrap(testString(entry["localPath"]))
    XCTAssertTrue(localPath.hasPrefix(downloadRoot.path + "/"))
    XCTAssertEqual(try String(contentsOfFile: localPath), "downloaded-body-key")
  }

  func testAppleMailMessageRejectsOwnerPrivateNonRuntimeDownloadDir() async throws {
    let fake = try FakeAppleMailGateway(mode: "message-success", requestId: "non-runtime-root")
    defer { fake.cleanup() }

    let ownerPrivateNonRuntimeRoot = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".ssh", isDirectory: true)
    try await assertMailFailure(
      name: "riela/apple-mail-message",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "messageId": .string("message-1"),
        "downloadDir": .string(ownerPrivateNonRuntimeRoot.path)
      ],
      code: .policyBlocked,
      messageContains: "ignored/private runtime path"
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: fake.downloadLogURL.path))
  }

  func testAppleMailMessageChecksActualDownloadedBytesBeforeWriting() async throws {
    for mode in ["message-underreported-download", "message-missing-byte-size-download"] {
      let fake = try FakeAppleMailGateway(mode: mode, requestId: "req-\(mode)")
      let downloadRoot = fake.rootURL.appendingPathComponent("tmp/downloads", isDirectory: true)
      defer { fake.cleanup() }

      let output = try await runAppleMail(
        name: "riela/apple-mail-message",
        config: [
          "binaryPath": .string(fake.executableURL.path),
          "messageId": .string("message-1"),
          "downloadDir": .string(downloadRoot.path),
          "materializeBodyText": .bool(true),
          "maxDownloadBytes": .integer(5)
        ]
      )

      let appleMail = try XCTUnwrap(testObject(output.payload["appleMail"]))
      XCTAssertEqual(testArray(appleMail["materialized"])?.count, 0)
      let skipped = try XCTUnwrap(testArray(appleMail["skippedDownloads"]))
      let skippedEntry = try XCTUnwrap(testObject(skipped.first))
      XCTAssertEqual(skippedEntry["reason"], .string("exceeds_maxDownloadBytes"))
      XCTAssertEqual(skippedEntry["materializedByteSize"], .integer(19))
      XCTAssertFalse(FileManager.default.fileExists(atPath: downloadRoot.appendingPathComponent("body.txt").path))
      let downloadLog = try String(contentsOf: fake.downloadLogURL)
      XCTAssertTrue(downloadLog.contains("body-key"))
    }
  }

  func testAppleMailMessageRejectsInvalidMaterializationConfigTypes() async throws {
    let fake = try FakeAppleMailGateway(mode: "message-success", requestId: "invalid-config")
    let downloadRoot = fake.rootURL.appendingPathComponent("tmp/downloads", isDirectory: true)
    defer { fake.cleanup() }

    try await assertMailFailure(
      name: "riela/apple-mail-message",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "messageId": .string("message-1"),
        "downloadDir": .string(downloadRoot.path),
        "materializeBodyText": .string("true")
      ],
      code: .policyBlocked,
      messageContains: "materializeBodyText must be a boolean"
    )
    try await assertMailFailure(
      name: "riela/apple-mail-message",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "messageId": .string("message-1"),
        "downloadDir": .string(downloadRoot.path),
        "maxDownloadBytes": .string("0")
      ],
      code: .policyBlocked,
      messageContains: "maxDownloadBytes must be an integer"
    )
    try await assertMailFailure(
      name: "riela/apple-mail-message",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "messageId": .string("message-1"),
        "downloadDir": .string(downloadRoot.path),
        "materializeAttachments": .string("true")
      ],
      code: .policyBlocked,
      messageContains: "materializeAttachments must be a boolean"
    )
  }

  func testAppleMailMessageIgnoresRuntimeMaterializationControls() async throws {
    let fake = try FakeAppleMailGateway(mode: "message-success", requestId: "runtime-controls")
    let downloadRoot = fake.rootURL.appendingPathComponent("tmp/downloads", isDirectory: true)
    defer { fake.cleanup() }

    let output = try await runAppleMail(
      name: "riela/apple-mail-message",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "messageId": .string("message-1"),
        "downloadDir": .string(downloadRoot.path),
        "materializeBodyText": .bool(false)
      ],
      addonInputs: [
        "materializeRawSource": .string("{{materializeRawSource}}"),
        "maxDownloadBytes": .string("{{maxDownloadBytes}}")
      ],
      variables: [
        "materializeBodyHtml": .bool(true),
        "materializeAttachments": .bool(true),
        "materializeRawSource": .bool(true),
        "maxDownloadBytes": .integer(999)
      ],
      resolvedInputPayload: [
        "materializeBodyHtml": .bool(true),
        "materializeAttachments": .bool(true),
        "materializeRawSource": .bool(true),
        "maxDownloadBytes": .integer(999)
      ]
    )

    let appleMail = try XCTUnwrap(testObject(output.payload["appleMail"]))
    XCTAssertEqual(testArray(appleMail["materialized"])?.count, 0)
    XCTAssertEqual(testArray(appleMail["skippedDownloads"])?.count, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fake.downloadLogURL.path))
  }

  func testAppleMailMessageIgnoresRuntimeMaxDownloadBytes() async throws {
    let fake = try FakeAppleMailGateway(mode: "message-success", requestId: "runtime-cap")
    let downloadRoot = fake.rootURL.appendingPathComponent("tmp/downloads", isDirectory: true)
    defer { fake.cleanup() }

    let output = try await runAppleMail(
      name: "riela/apple-mail-message",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "messageId": .string("message-1"),
        "downloadDir": .string(downloadRoot.path),
        "maxDownloadBytes": .integer(5)
      ],
      addonInputs: ["maxDownloadBytes": .string("{{maxDownloadBytes}}")],
      variables: ["maxDownloadBytes": .integer(999)],
      resolvedInputPayload: ["maxDownloadBytes": .integer(999)]
    )

    let appleMail = try XCTUnwrap(testObject(output.payload["appleMail"]))
    XCTAssertEqual(testArray(appleMail["materialized"])?.count, 0)
    let skipped = try XCTUnwrap(testArray(appleMail["skippedDownloads"]))
    XCTAssertEqual(skipped.count, 1)
    XCTAssertEqual(testObject(skipped.first)?["reason"], .string("exceeds_maxDownloadBytes"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fake.downloadLogURL.path))
  }

  func testAppleMailMessageRejectsMalformedFileDescriptorContainers() async throws {
    let cases = [
      MalformedDescriptorCase(mode: "malformed-files", config: [:], message: "files must be an object"),
      MalformedDescriptorCase(mode: "malformed-body-descriptor", config: [:], message: "files.bodyText must be an object"),
      MalformedDescriptorCase(
        mode: "malformed-attachments-container",
        config: ["materializeAttachments": .bool(true)],
        message: "files.attachments must be an array"
      ),
      MalformedDescriptorCase(
        mode: "malformed-attachment-entry",
        config: ["materializeAttachments": .bool(true)],
        message: "files.attachments[0] must be an object"
      )
    ]

    for testCase in cases {
      let fake = try FakeAppleMailGateway(mode: testCase.mode, requestId: testCase.mode)
      let downloadRoot = fake.rootURL.appendingPathComponent("tmp/downloads", isDirectory: true)
      defer { fake.cleanup() }

      var config = testCase.config
      config["binaryPath"] = .string(fake.executableURL.path)
      config["messageId"] = .string("message-1")
      config["downloadDir"] = .string(downloadRoot.path)
      try await assertMailFailure(
        name: "riela/apple-mail-message",
        config: config,
        code: .invalidOutput,
        messageContains: testCase.message
      )
    }
  }

  func testAppleMailMessageSoftNotFoundAndMissingMessageId() async throws {
    let fake = try FakeAppleMailGateway(mode: "message-null", requestId: "not-found")
    defer { fake.cleanup() }

    let output = try await runAppleMail(
      name: "riela/apple-mail-message",
      config: ["binaryPath": .string(fake.executableURL.path), "messageId": .string("missing")]
    )
    XCTAssertEqual(output.when["found"], false)
    let appleMail = try XCTUnwrap(testObject(output.payload["appleMail"]))
    XCTAssertEqual(appleMail["message"], .null)

    try await assertMailFailure(
      name: "riela/apple-mail-message",
      config: ["binaryPath": .string(fake.executableURL.path)],
      code: .policyBlocked,
      messageContains: "requires messageId"
    )
  }

  func testAppleMailMessageDownloadFailureMapsToProviderError() async throws {
    let fake = try FakeAppleMailGateway(mode: "download-nonzero", requestId: "download-fail")
    defer { fake.cleanup() }

    try await assertMailFailure(
      name: "riela/apple-mail-message",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "messageId": .string("message-1"),
        "downloadDir": .string(fake.rootURL.appendingPathComponent("tmp/downloads").path)
      ],
      code: .providerError,
      messageContains: "exit code 9"
    )
  }

  private func runAppleMail(
    name: String,
    config: JSONObject = [:],
    addonInputs: JSONObject = [:],
    environment: [String: String] = [:],
    variables: JSONObject = [:],
    resolvedInputPayload: JSONObject = [:],
    context: AdapterExecutionContext = AdapterExecutionContext()
  ) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(environment: environment).execute(
      WorkflowAddonExecutionInput(
        workflowId: "apple-mail-test",
        stepId: "apple-mail",
        nodeId: "apple-mail",
        addon: WorkflowNodeAddonRef(
          name: name,
          version: "1",
          config: config,
          inputs: addonInputs
        ),
        variables: variables,
        resolvedInputPayload: resolvedInputPayload
      ),
      context: context
    )
  }

  private func assertMailFailure(
    name: String,
    config: JSONObject = [:],
    addonInputs: JSONObject = [:],
    environment: [String: String] = [:],
    variables: JSONObject = [:],
    resolvedInputPayload: JSONObject = [:],
    code: AdapterExecutionErrorCode,
    messageContains: String,
    context: AdapterExecutionContext = AdapterExecutionContext()
  ) async throws {
    do {
      _ = try await runAppleMail(
        name: name,
        config: config,
        addonInputs: addonInputs,
        environment: environment,
        variables: variables,
        resolvedInputPayload: resolvedInputPayload,
        context: context
      )
      XCTFail("expected Apple Mail add-on to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, code)
      XCTAssertTrue(error.message.contains(messageContains), error.message)
    }
  }

  private func binarySource(_ output: AdapterExecutionOutput) -> String? {
    testObject(output.payload["appleGateway"])
      .flatMap { testObject($0["binary"]) }
      .flatMap { testString($0["source"]) }
  }

  private func requestId(_ output: AdapterExecutionOutput) -> String? {
    testObject(output.payload["appleMail"]).flatMap { testString($0["requestId"]) }
  }
}

private struct FakeAppleMailGateway {
  var rootURL: URL
  var binURL: URL
  var executableURL: URL
  var argumentLogURL: URL
  var environmentLogURL: URL
  var queryLogURL: URL
  var downloadLogURL: URL

  init(mode: String, requestId: String, executableName: String = "fake-apple-gateway") throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-apple-mail-addon-\(UUID().uuidString)", isDirectory: true)
    binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
    executableURL = binURL.appendingPathComponent(executableName)
    argumentLogURL = rootURL.appendingPathComponent("args.log")
    environmentLogURL = rootURL.appendingPathComponent("environment.log")
    queryLogURL = rootURL.appendingPathComponent("query.graphql")
    downloadLogURL = rootURL.appendingPathComponent("downloads.log")
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
    printf "%s\\n" "$@" > "\(argumentLogURL.path)"
    {
      printf "OPENAI_API_KEY=%s\\n" "${OPENAI_API_KEY:-}"
      printf "GITHUB_TOKEN=%s\\n" "${GITHUB_TOKEN:-}"
      printf "PATH=%s\\n" "${PATH:-}"
      printf "USER=%s\\n" "${USER:-}"
    } > "\(environmentLogURL.path)"
    if [ "$1" = "file" ]; then
      key=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--key" ]; then
          shift
          key="$1"
        fi
        shift
      done
      printf "%s\\n" "$key" >> "\(downloadLogURL.path)"
      if [ "\(mode)" = "download-nonzero" ]; then
        echo "download failed" >&2
        exit 9
      fi
      printf "downloaded-%s" "$key"
      exit 0
    fi
    printf "%s" "$3" > "\(queryLogURL.path)"
    case "\(mode)" in
      list-success)
        /bin/cat <<'JSON'
    {
      "data": {
        "permissions": {"mailFullDiskAccess": "AUTHORIZED"},
        "mailAccounts": [{"id": "account-1", "name": "iCloud", "kind": "icloud"}],
        "mailboxes": [{"id": "mailbox-1", "accountId": "account-1", "name": "Inbox", "path": "Inbox", "totalCount": 1, "unreadCount": 1}],
        "mailMessages": {
          "totalCount": 1,
          "pageInfo": {"hasNextPage": false, "endCursor": null},
          "edges": [{"cursor": "cursor-1", "node": {
            "id": "mail-1",
            "mailboxId": "mailbox-1",
            "accountId": "account-1",
            "messageId": "message-1",
            "subject": "Quarterly",
            "snippet": "Hello",
            "from": {"raw": "A <a@example.com>", "name": "A", "email": "a@example.com"},
            "to": [],
            "cc": [],
            "dateSent": "2026-07-07T00:00:00Z",
            "dateReceived": "2026-07-07T00:01:00Z",
            "isRead": false,
            "isFlagged": false,
            "hasAttachments": true,
            "files": {"bodyText": {"downloadKey": "body-key", "kind": "bodyText", "filename": "body.txt", "mimeType": "text/plain", "byteSize": 10}, "attachments": []}
          }}]
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
        ;;
      message-success|download-nonzero)
        /bin/cat <<'JSON'
    {
      "data": {
        "permissions": {"mailFullDiskAccess": "AUTHORIZED"},
        "mailMessage": {
          "id": "mail-1",
          "mailboxId": "mailbox-1",
          "accountId": "account-1",
          "messageId": "message-1",
          "subject": "Quarterly",
          "snippet": "Hello",
          "from": {"raw": "A <a@example.com>", "name": "A", "email": "a@example.com"},
          "to": [],
          "cc": [],
          "dateSent": "2026-07-07T00:00:00Z",
          "dateReceived": "2026-07-07T00:01:00Z",
          "isRead": false,
          "isFlagged": false,
          "hasAttachments": true,
          "files": {
            "bodyText": {"downloadKey": "body-key", "kind": "bodyText", "filename": "../body.txt", "mimeType": "text/plain", "byteSize": 10},
            "bodyHtml": {"downloadKey": "html-key", "kind": "bodyHtml", "filename": "body.html", "mimeType": "text/html", "byteSize": 10},
            "rawSource": {"downloadKey": "raw-key", "kind": "rawSource", "filename": "raw.eml", "mimeType": "message/rfc822", "byteSize": 10},
            "attachments": [
              {"downloadKey": "attachment-ok", "kind": "attachment", "filename": "../../escape.txt", "mimeType": "text/plain", "byteSize": 18},
              {"downloadKey": "attachment-big", "kind": "attachment", "filename": "big.bin", "mimeType": "application/octet-stream", "byteSize": 99}
            ]
          }
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
        ;;
      message-underreported-download)
        /bin/cat <<'JSON'
    {
      "data": {
        "permissions": {"mailFullDiskAccess": "AUTHORIZED"},
        "mailMessage": {
          "id": "mail-1",
          "messageId": "message-1",
          "files": {
            "bodyText": {"downloadKey": "body-key", "kind": "bodyText", "filename": "body.txt", "mimeType": "text/plain", "byteSize": 1},
            "attachments": []
          }
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
        ;;
      message-missing-byte-size-download)
        /bin/cat <<'JSON'
    {
      "data": {
        "permissions": {"mailFullDiskAccess": "AUTHORIZED"},
        "mailMessage": {
          "id": "mail-1",
          "messageId": "message-1",
          "files": {
            "bodyText": {"downloadKey": "body-key", "kind": "bodyText", "filename": "body.txt", "mimeType": "text/plain"},
            "attachments": []
          }
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
        ;;
    \(malformedDescriptorScriptCases(requestId: requestId))
      message-null)
        printf '{"data":{"permissions":{"mailFullDiskAccess":"AUTHORIZED"},"mailMessage":null},"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      fda-denied)
        /bin/cat <<'JSON'
    {
      "data": {
        "permissions": {"mailFullDiskAccess": "DENIED"},
        "mailAccounts": [],
        "mailboxes": [],
        "mailMessages": {
          "totalCount": 0,
          "pageInfo": {"hasNextPage": false, "endCursor": null},
          "edges": []
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
        ;;
      fda-not-determined)
        printf '{"data":null,"errors":[{"message":"Mail Full Disk Access is NOT_DETERMINED"}],"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      graphql-error)
        printf '{"data":null,"errors":[{"message":"upstream mail failure"}],"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      missing-data)
        printf '{"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      malformed)
        printf 'not-json\\n'
        ;;
      sleep)
        sleep 5
        ;;
    esac
    """
  }
}

private struct MalformedDescriptorCase {
  var mode: String
  var config: JSONObject
  var message: String
}

private func malformedDescriptorScriptCases(requestId: String) -> String {
  """
      malformed-files)
        /bin/cat <<'JSON'
    {
      "data": {
        "permissions": {"mailFullDiskAccess": "AUTHORIZED"},
        "mailMessage": {
          "id": "mail-1",
          "messageId": "message-1",
          "files": []
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
  JSON
        ;;
      malformed-body-descriptor)
        /bin/cat <<'JSON'
    {
      "data": {
        "permissions": {"mailFullDiskAccess": "AUTHORIZED"},
        "mailMessage": {
          "id": "mail-1",
          "messageId": "message-1",
          "files": {
            "bodyText": "not-a-descriptor",
            "attachments": []
          }
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
  JSON
        ;;
      malformed-attachments-container)
        /bin/cat <<'JSON'
    {
      "data": {
        "permissions": {"mailFullDiskAccess": "AUTHORIZED"},
        "mailMessage": {
          "id": "mail-1",
          "messageId": "message-1",
          "files": {
            "bodyText": null,
            "attachments": {"downloadKey": "attachment-key"}
          }
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
  JSON
        ;;
      malformed-attachment-entry)
        /bin/cat <<'JSON'
    {
      "data": {
        "permissions": {"mailFullDiskAccess": "AUTHORIZED"},
        "mailMessage": {
          "id": "mail-1",
          "messageId": "message-1",
          "files": {
            "bodyText": null,
            "attachments": ["not-a-descriptor"]
          }
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
  JSON
        ;;
  """
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
