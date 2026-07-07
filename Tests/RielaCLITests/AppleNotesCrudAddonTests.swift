import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class AppleNotesCrudAddonTests: XCTestCase {
  func testAppleNoteGetPassesNoteIdAsVariablesAndParsesNote() async throws {
    let fake = try CrudFakeAppleGateway(mode: "get")
    defer { fake.cleanup() }

    let output = try await runAppleNoteAddon(
      "riela/apple-note-get",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: ["noteId": .string("note-1")]
    )

    XCTAssertEqual(output.when["has_note"], true)
    let note = try XCTUnwrap(crudTestObject(output.payload["appleNote"]))
    XCTAssertEqual(note["id"], .string("note-1"))
    XCTAssertEqual(note["plaintext"], .string("plain body"))
    XCTAssertFalse(try String(contentsOf: fake.queryLogURL).contains("note-1"))
    XCTAssertTrue(try String(contentsOf: fake.variablesLogURL).contains(#""noteId":"note-1""#))
  }

  func testAppleNoteGetMaterializesBodyFileThroughDownloadKey() async throws {
    let fake = try CrudFakeAppleGateway(mode: "get-body-file")
    defer { fake.cleanup() }
    let downloadRoot = fake.rootURL.appendingPathComponent("downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)

    let output = try await runAppleNoteAddon(
      "riela/apple-note-get",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "materializeBody": .bool(true),
        "downloadDir": .string(downloadRoot.path)
      ],
      inputs: ["noteId": .string("note-large")]
    )

    let note = try XCTUnwrap(crudTestObject(output.payload["appleNote"]))
    let bodyFile = try XCTUnwrap(crudTestObject(note["bodyFile"]))
    let localPath = try XCTUnwrap(crudTestString(bodyFile["localPath"]))
    XCTAssertTrue(FileManager.default.fileExists(atPath: localPath))
    XCTAssertEqual(crudTestObject(note["body"])?.getString("materializedPath"), localPath)
    let args = try String(contentsOf: fake.argumentLogURL)
    XCTAssertTrue(args.contains("file\n"))
    XCTAssertTrue(args.contains("--key\nbody-key\n"))
    XCTAssertTrue(args.contains("--output-dir\n\(downloadRoot.path)\n"))
  }

  func testAppleNoteGetMaterializeFailsWhenDownloadKeyMappingIsMissing() async throws {
    let fake = try CrudFakeAppleGateway(mode: "get-body-file-missing-download-mapping")
    defer { fake.cleanup() }
    let downloadRoot = fake.rootURL.appendingPathComponent("downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)

    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "materializeBody": .bool(true),
        "downloadDir": .string(downloadRoot.path)
      ],
      inputs: ["noteId": .string("note-large")],
      code: .providerError,
      messageContains: "body-key"
    )
  }

  func testAppleNoteGetMaterializeWithoutRootFailsPolicyBlocked() async throws {
    let fake = try CrudFakeAppleGateway(mode: "get-body-file")
    defer { fake.cleanup() }

    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "materializeBody": .bool(true)
      ],
      inputs: ["noteId": .string("note-large")],
      code: .policyBlocked,
      messageContains: "materializeBody requires"
    )
  }

  func testAppleNoteCreateSuccessAndMissingTitleValidation() async throws {
    let fake = try CrudFakeAppleGateway(mode: "create")
    defer { fake.cleanup() }

    let output = try await runAppleNoteAddon(
      "riela/apple-note-create",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: ["title": .string("New Note"), "bodyText": .string("hello")]
    )

    XCTAssertEqual(output.payload["created"], .bool(true))
    XCTAssertEqual(crudTestObject(output.payload["appleNote"])?.getString("id"), "created-1")
    let variables = try String(contentsOf: fake.variablesLogURL)
    XCTAssertTrue(variables.contains(#""title":"New Note""#))
    XCTAssertTrue(variables.contains(#""bodyText":"hello""#))

    try await assertAppleNoteFailure(
      "riela/apple-note-create",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: ["bodyText": .string("hello")],
      code: .policyBlocked,
      messageContains: "title is required"
    )
  }

  func testAppleNoteUpdateReplaceAndAppendModes() async throws {
    let replaceFake = try CrudFakeAppleGateway(mode: "update")
    let appendFake = try CrudFakeAppleGateway(mode: "update")
    defer {
      replaceFake.cleanup()
      appendFake.cleanup()
    }

    let replaceOutput = try await runAppleNoteAddon(
      "riela/apple-note-update-body",
      config: ["binaryPath": .string(replaceFake.executableURL.path)],
      inputs: ["noteId": .string("note-1"), "mode": .string("REPLACE"), "bodyText": .string("replacement")]
    )
    XCTAssertEqual(replaceOutput.payload["updated"], .bool(true))
    XCTAssertTrue(try String(contentsOf: replaceFake.variablesLogURL).contains(#""mode":"REPLACE""#))

    let appendOutput = try await runAppleNoteAddon(
      "riela/apple-note-update-body",
      config: ["binaryPath": .string(appendFake.executableURL.path), "mode": .string("APPEND")],
      inputs: ["noteId": .string("note-1"), "bodyText": .string("appendix")]
    )
    XCTAssertEqual(appendOutput.payload["updated"], .bool(true))
    XCTAssertTrue(try String(contentsOf: appendFake.variablesLogURL).contains(#""mode":"APPEND""#))
  }

  func testAppleNoteDeleteAndMoveSuccess() async throws {
    let deleteFake = try CrudFakeAppleGateway(mode: "delete")
    let moveFake = try CrudFakeAppleGateway(mode: "move")
    defer {
      deleteFake.cleanup()
      moveFake.cleanup()
    }

    let deleteOutput = try await runAppleNoteAddon(
      "riela/apple-note-delete",
      config: ["binaryPath": .string(deleteFake.executableURL.path)],
      inputs: ["noteId": .string("note-1")]
    )
    XCTAssertEqual(deleteOutput.payload["deleted"], .bool(true))
    XCTAssertEqual(crudTestObject(deleteOutput.payload["deleteResult"])?.getBool("success"), true)

    let moveOutput = try await runAppleNoteAddon(
      "riela/apple-note-move",
      config: ["binaryPath": .string(moveFake.executableURL.path)],
      inputs: ["noteId": .string("note-1"), "folderId": .string("folder-2")]
    )
    XCTAssertEqual(moveOutput.payload["moved"], .bool(true))
    XCTAssertEqual(crudTestObject(moveOutput.payload["appleNote"])?.getString("folderId"), "folder-2")
    XCTAssertTrue(try String(contentsOf: moveFake.variablesLogURL).contains(#""folderId":"folder-2""#))
  }

  func testAppleNoteGraphQLErrorsPreserveLockedAndPermissionDetails() async throws {
    let lockedFake = try CrudFakeAppleGateway(mode: "note-locked")
    let permissionFake = try CrudFakeAppleGateway(mode: "permission-denied")
    defer {
      lockedFake.cleanup()
      permissionFake.cleanup()
    }

    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: ["binaryPath": .string(lockedFake.executableURL.path)],
      inputs: ["noteId": .string("locked")],
      code: .providerError,
      messageContains: "NOTE_LOCKED"
    )
    try await assertAppleNoteFailure(
      "riela/apple-note-delete",
      config: ["binaryPath": .string(permissionFake.executableURL.path)],
      inputs: ["noteId": .string("note-1")],
      code: .providerError,
      messageContains: "permission denied"
    )
  }

  func testAppleNoteCrudMapsProcessAndEnvelopeFailures() async throws {
    let nonzeroFake = try CrudFakeAppleGateway(mode: "nonzero")
    let malformedFake = try CrudFakeAppleGateway(mode: "malformed")
    let missingMutationFake = try CrudFakeAppleGateway(mode: "missing-mutation")
    defer {
      nonzeroFake.cleanup()
      malformedFake.cleanup()
      missingMutationFake.cleanup()
    }

    try await assertAppleNoteFailure(
      "riela/apple-note-create",
      config: ["binaryPath": .string(nonzeroFake.executableURL.path)],
      inputs: ["title": .string("New"), "bodyText": .string("body")],
      code: .providerError,
      messageContains: "exit code 9"
    )
    try await assertAppleNoteFailure(
      "riela/apple-note-create",
      config: ["binaryPath": .string(malformedFake.executableURL.path)],
      inputs: ["title": .string("New"), "bodyText": .string("body")],
      code: .invalidOutput,
      messageContains: "not valid JSON"
    )
    try await assertAppleNoteFailure(
      "riela/apple-note-create",
      config: ["binaryPath": .string(missingMutationFake.executableURL.path)],
      inputs: ["title": .string("New"), "bodyText": .string("body")],
      code: .invalidOutput,
      messageContains: "data.createNote is missing"
    )
  }

  func testAppleNoteCrudMapsBinaryTimeoutEnvAndVersionFailures() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-apple-notes-crud-nonexec-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let nonExecutable = root.appendingPathComponent("apple-gateway")
    try Data("#!/bin/sh\n".utf8).write(to: nonExecutable)

    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: ["binaryPath": .string(nonExecutable.path)],
      inputs: ["noteId": .string("note-1")],
      code: .policyBlocked,
      messageContains: "config.binaryPath is not executable"
    )

    let sleepFake = try CrudFakeAppleGateway(mode: "sleep")
    defer { sleepFake.cleanup() }
    let startedAt = Date()
    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: ["binaryPath": .string(sleepFake.executableURL.path)],
      inputs: ["noteId": .string("note-1")],
      code: .timeout,
      messageContains: "deadline",
      context: AdapterExecutionContext(deadline: Date().addingTimeInterval(0.1))
    )
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)

    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: ["binaryPath": .string(sleepFake.executableURL.path)],
      inputs: ["noteId": .string("note-1")],
      env: ["UNSAFE": .object(["fromEnv": .string("UNSAFE")])],
      code: .policyBlocked,
      messageContains: "does not support addon.env"
    )
    try await assertAppleNoteFailure(
      "riela/apple-note-get",
      config: ["binaryPath": .string(sleepFake.executableURL.path)],
      inputs: ["noteId": .string("note-1")],
      version: "2",
      code: .policyBlocked,
      messageContains: "unsupported"
    )
  }

  func testAppleNoteCrudVariablesAreNotInjectedIntoGraphQLDocument() async throws {
    let fake = try CrudFakeAppleGateway(mode: "create")
    defer { fake.cleanup() }
    let title = "quote \" brace } newline\nsentinel"

    _ = try await runAppleNoteAddon(
      "riela/apple-note-create",
      config: ["binaryPath": .string(fake.executableURL.path)],
      inputs: ["title": .string(title), "bodyText": .string("body")]
    )

    let query = try String(contentsOf: fake.queryLogURL)
    let variables = try String(contentsOf: fake.variablesLogURL)
    XCTAssertFalse(query.contains("sentinel"))
    XCTAssertFalse(query.contains(title))
    XCTAssertTrue(variables.contains(#""title":"quote \" brace } newline\nsentinel""#))
  }

  private func runAppleNoteAddon(
    _ addonName: String,
    version: String = "1",
    config: JSONObject = [:],
    inputs: JSONObject = [:],
    env: JSONObject? = nil,
    environment: [String: String] = [:],
    context: AdapterExecutionContext = AdapterExecutionContext()
  ) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(environment: environment).execute(
      WorkflowAddonExecutionInput(
        workflowId: "apple-notes-crud",
        stepId: "apple-note-step",
        nodeId: "apple-note-step",
        addon: WorkflowNodeAddonRef(
          name: addonName,
          version: version,
          config: config,
          env: env,
          inputs: inputs
        ),
        variables: [:],
        resolvedInputPayload: [:]
      ),
      context: context
    )
  }

  private func assertAppleNoteFailure(
    _ addonName: String,
    config: JSONObject,
    inputs: JSONObject,
    env: JSONObject? = nil,
    version: String = "1",
    code: AdapterExecutionErrorCode,
    messageContains: String,
    context: AdapterExecutionContext = AdapterExecutionContext()
  ) async throws {
    do {
      _ = try await runAppleNoteAddon(
        addonName,
        version: version,
        config: config,
        inputs: inputs,
        env: env,
        context: context
      )
      XCTFail("expected Apple Notes CRUD add-on to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, code)
      XCTAssertTrue(error.message.contains(messageContains), error.message)
    }
  }
}

private struct CrudFakeAppleGateway {
  var rootURL: URL
  var binURL: URL
  var executableURL: URL
  var argumentLogURL: URL
  var queryLogURL: URL
  var variablesLogURL: URL

  init(mode: String) throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-apple-notes-crud-\(UUID().uuidString)", isDirectory: true)
    binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
    executableURL = binURL.appendingPathComponent("fake-apple-gateway")
    argumentLogURL = rootURL.appendingPathComponent("args.log")
    queryLogURL = rootURL.appendingPathComponent("query.graphql")
    variablesLogURL = rootURL.appendingPathComponent("variables.json")
    try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
    try script(mode: mode).write(to: executableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: rootURL)
  }

  private func script(mode: String) -> String {
    """
    #!/bin/sh
    {
      printf "CALL\\n"
      for arg in "$@"; do printf "%s\\n" "$arg"; done
    } >> "\(argumentLogURL.path)"

    command="$1"
    if [ "$command" = "file" ]; then
      shift
      subcommand="$1"
      shift
      key=""
      output_dir=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --key)
            shift
            key="$1"
            ;;
          --output-dir)
            shift
            output_dir="$1"
            ;;
        esac
        shift
      done
      mkdir -p "$output_dir"
      local_path="$output_dir/body.txt"
      printf "large body" > "$local_path"
      if [ "\(mode)" = "get-body-file-missing-download-mapping" ]; then
        printf '{"files":[{"downloadKey":"other-key","localPath":"%s","byteSize":10}]}\\n' "$local_path"
        exit 0
      fi
      printf '{"files":[{"downloadKey":"%s","localPath":"%s","byteSize":10}]}\\n' "$key" "$local_path"
      exit 0
    fi

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
      get)
        /bin/cat <<'JSON'
    {
      "data": {
        "note": {
          "id": "note-1",
          "accountId": "account-1",
          "folderId": "folder-1",
          "name": "Project",
          "snippet": "plain",
          "plaintext": "plain body",
          "isPasswordProtected": false,
          "isShared": false,
          "creationDate": "2026-07-07T00:00:00Z",
          "modificationDate": "2026-07-07T01:00:00Z"
        }
      },
      "extensions": {"requestId": "crud-get"}
    }
    JSON
        ;;
      get-body-file)
        /bin/cat <<'JSON'
    {
      "data": {
        "note": {
          "id": "note-large",
          "accountId": "account-1",
          "folderId": "folder-1",
          "name": "Large",
          "snippet": "large",
          "bodyFile": {"downloadKey": "body-key", "kind": "html", "byteSize": 1000},
          "isPasswordProtected": false,
          "isShared": false,
          "creationDate": "2026-07-07T00:00:00Z",
          "modificationDate": "2026-07-07T01:00:00Z"
        }
      },
      "extensions": {"requestId": "crud-get-body"}
    }
    JSON
        ;;
      get-body-file-missing-download-mapping)
        /bin/cat <<'JSON'
    {
      "data": {
        "note": {
          "id": "note-large",
          "accountId": "account-1",
          "folderId": "folder-1",
          "name": "Large",
          "snippet": "large",
          "bodyFile": {"downloadKey": "body-key", "kind": "html", "byteSize": 1000},
          "isPasswordProtected": false,
          "isShared": false,
          "creationDate": "2026-07-07T00:00:00Z",
          "modificationDate": "2026-07-07T01:00:00Z"
        }
      },
      "extensions": {"requestId": "crud-get-body-missing-download"}
    }
    JSON
        ;;
      create)
        /bin/cat <<'JSON'
    {
      "data": {
        "createNote": {
          "id": "created-1",
          "accountId": "account-1",
          "folderId": "folder-1",
          "name": "New Note",
          "snippet": "hello",
          "creationDate": "2026-07-07T00:00:00Z",
          "modificationDate": "2026-07-07T00:00:00Z"
        }
      },
      "extensions": {"requestId": "crud-create"}
    }
    JSON
        ;;
      update)
        /bin/cat <<'JSON'
    {"data":{"updateNoteBody":{"id":"note-1","name":"Updated","snippet":"updated","modificationDate":"2026-07-07T02:00:00Z"}},"extensions":{"requestId":"crud-update"}}
    JSON
        ;;
      delete)
        /bin/cat <<'JSON'
    {"data":{"deleteNote":{"success":true}},"extensions":{"requestId":"crud-delete"}}
    JSON
        ;;
      move)
        /bin/cat <<'JSON'
    {"data":{"moveNote":{"id":"note-1","folderId":"folder-2","name":"Moved","modificationDate":"2026-07-07T03:00:00Z"}},"extensions":{"requestId":"crud-move"}}
    JSON
        ;;
      note-locked)
        printf '{"data":null,"errors":[{"message":"note is locked","extensions":{"code":"NOTE_LOCKED"}}],"extensions":{"requestId":"locked"}}\\n'
        ;;
      permission-denied)
        printf '{"data":null,"errors":[{"message":"notes permission denied","extensions":{"code":"PERMISSION_DENIED"}}],"extensions":{"requestId":"denied"}}\\n'
        ;;
      nonzero)
        echo 'upstream failed' >&2
        exit 9
        ;;
      malformed)
        printf 'not-json\\n'
        ;;
      missing-mutation)
        printf '{"data":{},"extensions":{"requestId":"missing"}}\\n'
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
    crudTestString(self[key])
  }

  func getBool(_ key: String) -> Bool? {
    guard case let .bool(value)? = self[key] else {
      return nil
    }
    return value
  }
}

private func crudTestObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object)? = value else {
    return nil
  }
  return object
}

private func crudTestString(_ value: JSONValue?) -> String? {
  guard case let .string(string)? = value else {
    return nil
  }
  return string
}
