import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class AppleGatewayAddonTests: XCTestCase {
  func testAppleNotesListBuildsArgumentsAndParsesSuccessEnvelope() async throws {
    let fake = try FakeAppleGateway(requestId: "req-success")
    defer { fake.cleanup() }

    let output = try await runAppleNotesList(
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "first": .integer(2),
        "query": .string("project plan"),
        "includePlaintext": .bool(true)
      ]
    )

    XCTAssertEqual(try String(contentsOf: fake.argumentLogURL), "graphql\n--query\n")
    let query = try String(contentsOf: fake.queryLogURL)
    XCTAssertTrue(query.contains("noteAccounts"))
    XCTAssertTrue(query.contains("noteFolders"))
    XCTAssertTrue(query.contains("notes(input: {first: 2, query: \"project plan\"})"))
    XCTAssertTrue(query.contains("plaintext"))

    let appleNotes = try XCTUnwrap(appleGatewayTestObject(output.payload["appleNotes"]))
    XCTAssertEqual(appleGatewayTestArray(appleNotes["accounts"])?.count, 1)
    XCTAssertEqual(appleGatewayTestArray(appleNotes["folders"])?.count, 1)
    let notes = try XCTUnwrap(appleGatewayTestArray(appleNotes["notes"]))
    let note = try XCTUnwrap(appleGatewayTestObject(notes.first))
    XCTAssertEqual(note["id"], .string("note-1"))
    XCTAssertEqual(note["cursor"], .string("cursor-1"))
    XCTAssertEqual(appleNotes["totalCount"], .integer(1))
    XCTAssertEqual(appleNotes["requestId"], .string("req-success"))
    XCTAssertEqual(output.payload["noteCount"], .number(1))
    XCTAssertEqual(output.when["has_notes"], true)
  }

  func testAppleNotesListDrainsLargeStdoutAndStderrBeforeProcessExit() async throws {
    let fake = try FakeAppleGateway(requestId: "large-output", mode: "large-output")
    defer { fake.cleanup() }

    let output = try await runAppleNotesList(
      config: ["binaryPath": .string(fake.executableURL.path)]
    )

    let appleNotes = try XCTUnwrap(appleGatewayTestObject(output.payload["appleNotes"]))
    XCTAssertEqual(appleGatewayTestArray(appleNotes["accounts"])?.count, 1)
    XCTAssertEqual(appleNotes["requestId"], .string("large-output"))
    XCTAssertEqual(output.payload["noteCount"], .number(1))
  }

  func testAppleNotesListTerminatesProcessWhenDeadlineExpires() async throws {
    let fake = try FakeAppleGateway(requestId: "timeout", mode: "sleep")
    defer { fake.cleanup() }

    let startedAt = Date()
    do {
      _ = try await runAppleNotesList(
        config: ["binaryPath": .string(fake.executableURL.path)],
        context: AdapterExecutionContext(deadline: Date().addingTimeInterval(0.1))
      )
      XCTFail("expected apple-gateway deadline to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
      XCTAssertTrue(error.message.contains("deadline"))
      XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }
  }

  func testAppleNotesListResolvesBinaryFromConfigEnvThenPath() async throws {
    let configFake = try FakeAppleGateway(requestId: "config")
    let envFake = try FakeAppleGateway(requestId: "env")
    let pathFake = try FakeAppleGateway(requestId: "path", executableName: "apple-gateway")
    defer {
      configFake.cleanup()
      envFake.cleanup()
      pathFake.cleanup()
    }

    let configOutput = try await runAppleNotesList(
      config: ["binaryPath": .string(configFake.executableURL.path)],
      environment: [
        "APPLE_GATEWAY_BIN": envFake.executableURL.path,
        "PATH": pathFake.binURL.path
      ]
    )
    XCTAssertEqual(gatewayBinarySource(configOutput), "config")
    XCTAssertEqual(requestId(configOutput), "config")

    let envOutput = try await runAppleNotesList(
      environment: [
        "APPLE_GATEWAY_BIN": envFake.executableURL.path,
        "PATH": pathFake.binURL.path
      ]
    )
    XCTAssertEqual(gatewayBinarySource(envOutput), "environment")
    XCTAssertEqual(requestId(envOutput), "env")

    let pathOutput = try await runAppleNotesList(
      environment: [
        "PATH": pathFake.binURL.path
      ]
    )
    XCTAssertEqual(gatewayBinarySource(pathOutput), "path")
    XCTAssertEqual(requestId(pathOutput), "path")
  }

  func testAppleNotesListDoesNotResolveBinaryPathFromPayloadVariablesOrAddonInputs() async throws {
    let maliciousFake = try FakeAppleGateway(requestId: "payload")
    let envFake = try FakeAppleGateway(requestId: "env")
    defer {
      maliciousFake.cleanup()
      envFake.cleanup()
    }

    let output = try await runAppleNotesList(
      addonInputs: ["binaryPath": .string("{{binaryPath}}")],
      environment: ["APPLE_GATEWAY_BIN": envFake.executableURL.path],
      variables: ["binaryPath": .string(maliciousFake.executableURL.path)],
      resolvedInputPayload: ["binaryPath": .string(maliciousFake.executableURL.path)]
    )

    XCTAssertEqual(gatewayBinarySource(output), "environment")
    XCTAssertEqual(requestId(output), "env")
    XCTAssertFalse(FileManager.default.fileExists(atPath: maliciousFake.argumentLogURL.path))
  }

  func testAppleNotesListDoesNotForwardSecretLikeEnvironmentToSubprocess() async throws {
    let fake = try FakeAppleGateway(requestId: "sanitized-env")
    defer { fake.cleanup() }

    _ = try await runAppleNotesList(
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

  func testAppleNotesListMapsGraphQLErrorsToProviderError() async throws {
    let fake = try FakeAppleGateway(requestId: "graphql-error", mode: "graphql-error")
    defer { fake.cleanup() }

    do {
      _ = try await runAppleNotesList(
        config: ["binaryPath": .string(fake.executableURL.path)]
      )
      XCTFail("expected GraphQL error envelope to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertTrue(error.message.contains("notes permission denied"))
    }
  }

  func testAppleNotesListMapsNonZeroExitToProviderError() async throws {
    let fake = try FakeAppleGateway(requestId: "nonzero", mode: "nonzero")
    defer { fake.cleanup() }

    do {
      _ = try await runAppleNotesList(
        config: ["binaryPath": .string(fake.executableURL.path)]
      )
      XCTFail("expected non-zero process exit to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertTrue(error.message.contains("exit code 7"))
      XCTAssertTrue(error.message.contains("upstream denied"))
    }
  }

  func testAppleNotesListMapsMalformedJsonAndMissingDataToInvalidOutput() async throws {
    let malformedFake = try FakeAppleGateway(requestId: "malformed", mode: "malformed")
    let missingDataFake = try FakeAppleGateway(requestId: "missing-data", mode: "missing-data")
    defer {
      malformedFake.cleanup()
      missingDataFake.cleanup()
    }

    try await assertAppleGatewayFailure(
      config: ["binaryPath": .string(malformedFake.executableURL.path)],
      code: .invalidOutput,
      messageContains: "not valid JSON"
    )
    try await assertAppleGatewayFailure(
      config: ["binaryPath": .string(missingDataFake.executableURL.path)],
      code: .invalidOutput,
      messageContains: "GraphQL data is missing"
    )
  }

  func testAppleNotesListMapsMalformedNestedNotesDataToInvalidOutput() async throws {
    let malformedEdgesFake = try FakeAppleGateway(requestId: "malformed-edges", mode: "malformed-edges")
    let missingEdgeNodeFake = try FakeAppleGateway(requestId: "missing-edge-node", mode: "missing-edge-node")
    defer {
      malformedEdgesFake.cleanup()
      missingEdgeNodeFake.cleanup()
    }

    try await assertAppleGatewayFailure(
      config: ["binaryPath": .string(malformedEdgesFake.executableURL.path)],
      code: .invalidOutput,
      messageContains: "data.notes.edges must be an array"
    )
    try await assertAppleGatewayFailure(
      config: ["binaryPath": .string(missingEdgeNodeFake.executableURL.path)],
      code: .invalidOutput,
      messageContains: "data.notes.edges[0].node must be an object"
    )
  }

  func testAppleNotesListMapsMissingOrNonExecutableBinaryToPolicyBlocked() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-apple-gateway-nonexec-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let nonExecutable = root.appendingPathComponent("apple-gateway")
    try Data("#!/bin/sh\n".utf8).write(to: nonExecutable)

    try await assertAppleGatewayFailure(
      config: ["binaryPath": .string(nonExecutable.path)],
      code: .policyBlocked,
      messageContains: "config.binaryPath is not executable"
    )
    try await assertAppleGatewayFailure(
      environment: ["PATH": root.path],
      code: .policyBlocked,
      messageContains: "requires apple-gateway"
    )
  }

  private func runAppleNotesList(
    config: JSONObject = [:],
    addonInputs: JSONObject = [:],
    environment: [String: String] = [:],
    variables: JSONObject = [:],
    resolvedInputPayload: JSONObject = [:],
    context: AdapterExecutionContext = AdapterExecutionContext()
  ) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(environment: environment).execute(
      WorkflowAddonExecutionInput(
        workflowId: "apple-notes-list",
        stepId: "list-apple-notes",
        nodeId: "list-apple-notes",
        addon: WorkflowNodeAddonRef(
          name: "riela/apple-notes-list",
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

  private func assertAppleGatewayFailure(
    config: JSONObject = [:],
    environment: [String: String] = [:],
    code: AdapterExecutionErrorCode,
    messageContains: String
  ) async throws {
    do {
      _ = try await runAppleNotesList(config: config, environment: environment)
      XCTFail("expected apple gateway add-on to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, code)
      XCTAssertTrue(error.message.contains(messageContains), error.message)
    }
  }

  private func gatewayBinarySource(_ output: AdapterExecutionOutput) -> String? {
    appleGatewayTestObject(output.payload["appleGateway"])
      .flatMap { appleGatewayTestObject($0["binary"]) }
      .flatMap { appleGatewayTestString($0["source"]) }
  }

  private func requestId(_ output: AdapterExecutionOutput) -> String? {
    appleGatewayTestObject(output.payload["appleNotes"]).flatMap { appleGatewayTestString($0["requestId"]) }
  }
}

private struct FakeAppleGateway {
  var rootURL: URL
  var binURL: URL
  var executableURL: URL
  var argumentLogURL: URL
  var environmentLogURL: URL
  var queryLogURL: URL

  init(requestId: String, executableName: String = "fake-apple-gateway", mode: String = "success") throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-apple-gateway-addon-\(UUID().uuidString)", isDirectory: true)
    binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
    executableURL = binURL.appendingPathComponent(executableName)
    argumentLogURL = rootURL.appendingPathComponent("args.log")
    environmentLogURL = rootURL.appendingPathComponent("environment.log")
    queryLogURL = rootURL.appendingPathComponent("query.graphql")
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
    case "\(mode)" in
      success)
        /bin/cat <<'JSON'
    {
      "data": {
        "noteAccounts": [{"id": "account-1", "name": "iCloud", "isDefault": true}],
        "noteFolders": [{
          "id": "folder-1",
          "accountId": "account-1",
          "name": "Notes",
          "parentFolderId": null,
          "noteCount": 1
        }],
        "notes": {
          "totalCount": 1,
          "pageInfo": {"hasNextPage": false, "endCursor": null},
          "edges": [{
            "cursor": "cursor-1",
            "node": {
              "id": "note-1",
              "accountId": "account-1",
              "folderId": "folder-1",
              "name": "Project Plan",
              "snippet": "Ship it",
              "plaintext": "Ship it",
              "isPasswordProtected": false,
              "isShared": false,
              "creationDate": "2026-07-07T00:00:00Z",
              "modificationDate": "2026-07-07T01:00:00Z"
            }
          }]
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
        ;;
      graphql-error)
        printf '{"data":null,"errors":[{"message":"notes permission denied"}],"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      missing-data)
        printf '{"extensions":{"requestId":"%s"}}\\n' "\(requestId)"
        ;;
      malformed-edges)
        /bin/cat <<'JSON'
    {
      "data": {
        "noteAccounts": [{"id": "account-1", "name": "iCloud", "isDefault": true}],
        "noteFolders": [{
          "id": "folder-1",
          "accountId": "account-1",
          "name": "Notes",
          "parentFolderId": null,
          "noteCount": 1
        }],
        "notes": {
          "totalCount": 5,
          "pageInfo": {"hasNextPage": false, "endCursor": null},
          "edges": {"cursor": "cursor-1"}
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
        ;;
      missing-edge-node)
        /bin/cat <<'JSON'
    {
      "data": {
        "noteAccounts": [{"id": "account-1", "name": "iCloud", "isDefault": true}],
        "noteFolders": [{
          "id": "folder-1",
          "accountId": "account-1",
          "name": "Notes",
          "parentFolderId": null,
          "noteCount": 1
        }],
        "notes": {
          "totalCount": 5,
          "pageInfo": {"hasNextPage": false, "endCursor": null},
          "edges": [{"cursor": "cursor-1"}]
        }
      },
      "extensions": {"requestId": "\(requestId)"}
    }
    JSON
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
      large-output)
        printf '%131072s' '' | /usr/bin/tr ' ' e >&2
        printf '{"data":{"noteAccounts":[{"id":"account-1","name":"'
        printf '%131072s' '' | /usr/bin/tr ' ' a
        printf '","isDefault":true}],'
        printf '"noteFolders":[{"id":"folder-1","accountId":"account-1",'
        printf '"name":"Notes","parentFolderId":null,"noteCount":1}],'
        printf '"notes":{"totalCount":1,'
        printf '"pageInfo":{"hasNextPage":false,"endCursor":null},'
        printf '"edges":[{"cursor":"cursor-1","node":{"id":"note-1",'
        printf '"accountId":"account-1","folderId":"folder-1",'
        printf '"name":"Large Output","snippet":"large",'
        printf '"isPasswordProtected":false,"isShared":false,'
        printf '"creationDate":"2026-07-07T00:00:00Z",'
        printf '"modificationDate":"2026-07-07T01:00:00Z"}}]}},'
        printf '"extensions":{"requestId":"\(requestId)"}}\\n'
        ;;
    esac
    """
  }
}

private func appleGatewayTestObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object)? = value else {
    return nil
  }
  return object
}

private func appleGatewayTestArray(_ value: JSONValue?) -> [JSONValue]? {
  guard case let .array(array)? = value else {
    return nil
  }
  return array
}

private func appleGatewayTestString(_ value: JSONValue?) -> String? {
  guard case let .string(string)? = value else {
    return nil
  }
  return string
}
