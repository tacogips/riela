import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class GoogleDocumentsGatewayAddonTests: XCTestCase {
  func testSheetReadRendersCommandAndSortedEqualsBoundFlags() async throws {
    let fake = try FakeGoogleDocumentsGateway(mode: "values-success")
    defer { fake.cleanup() }

    let output = try await runDocuments(
      name: "riela/google-sheet-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "command": .string("values get"),
        "argsTemplate": .object([
          "spreadsheet-id": .string("{{workflowInput.spreadsheetId}}"),
          "range": .string("Sheet1!A1:B2")
        ]),
        "whenFlags": .object(["has_values": .string("data.data.values.0.0")])
      ],
      variables: [
        "workflowInput": .object(["spreadsheetId": .string("SHEET-1")])
      ]
    )

    let invocation = try String(contentsOf: fake.argumentsLogURL)
    XCTAssertEqual(invocation, "values get --range=Sheet1!A1:B2 --spreadsheet-id=SHEET-1")
    XCTAssertEqual(output.payload["command"], .string("values get"))
    XCTAssertEqual(output.when["has_values"], true)
    XCTAssertEqual(output.when["ok"], true)
    XCTAssertEqual(documentsBinaryPath(output), fake.executableURL.path)
  }

  func testBooleanArrayAndOmittedFlagEncodings() async throws {
    let fake = try FakeGoogleDocumentsGateway(mode: "values-success")
    defer { fake.cleanup() }

    _ = try await runDocuments(
      name: "riela/google-drive-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "command": .string("files list"),
        "argsTemplate": .object([
          "page-all": .bool(true),
          "online": .bool(false),
          "page-size": .integer(25),
          "fields": .array([.string("id"), .string("name")])
        ])
      ]
    )

    let invocation = try String(contentsOf: fake.argumentsLogURL)
    XCTAssertEqual(invocation, "files list --fields=id --fields=name --page-all --page-size=25")
  }

  func testInteractiveAuthCommandsAreRefused() async throws {
    let fake = try FakeGoogleDocumentsGateway(mode: "values-success")
    defer { fake.cleanup() }

    try await assertDocumentsFailure(
      name: "riela/google-docs-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "command": .string("auth login")
      ],
      code: .policyBlocked,
      messageContains: "refuses 'auth login'"
    )
    try await assertDocumentsFailure(
      name: "riela/google-docs-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "command": .string("auth revoke")
      ],
      code: .policyBlocked,
      messageContains: "refuses 'auth revoke'"
    )
  }

  func testMalformedCommandAndFlagNamesAreRejected() async throws {
    let fake = try FakeGoogleDocumentsGateway(mode: "values-success")
    defer { fake.cleanup() }

    try await assertDocumentsFailure(
      name: "riela/google-docs-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "command": .string("document get extra-word")
      ],
      code: .policyBlocked,
      messageContains: "config.command must be one or two lowercase command words"
    )
    try await assertDocumentsFailure(
      name: "riela/google-docs-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "command": .string("--document-id")
      ],
      code: .policyBlocked,
      messageContains: "config.command must be one or two lowercase command words"
    )
    try await assertDocumentsFailure(
      name: "riela/google-docs-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "command": .string("document get"),
        "argsTemplate": .object(["Evil Flag": .string("x")])
      ],
      code: .policyBlocked,
      messageContains: "flag 'Evil Flag'"
    )
  }

  func testMissingCommandIsRejected() async throws {
    try await assertDocumentsFailure(
      name: "riela/google-docs-gateway-read",
      config: [:],
      code: .policyBlocked,
      messageContains: "config.command is required"
    )
  }

  func testEnvironmentBindingsAllowOnlyOwnRoleCredentials() async throws {
    let fake = try FakeGoogleDocumentsGateway(mode: "values-success")
    defer { fake.cleanup() }

    _ = try await runDocuments(
      name: "riela/google-docs-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "command": .string("document get"),
        "argsTemplate": .object(["document-id": .string("DOC-1")])
      ],
      env: [
        "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_JSON": .object([
          "fromEnv": .string("RIELA_DOCS_READER_TOKEN_STORE")
        ])
      ],
      environment: [
        "RIELA_DOCS_READER_TOKEN_STORE": "sentinel-token-store",
        "OPENAI_API_KEY": "sentinel-openai"
      ]
    )
    let childEnvironment = try String(contentsOf: fake.environmentLogURL)
    XCTAssertTrue(childEnvironment.contains("GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_JSON=sentinel-token-store"))
    XCTAssertFalse(childEnvironment.contains("sentinel-openai"))

    try await assertDocumentsFailure(
      name: "riela/google-docs-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "command": .string("document get")
      ],
      env: [
        "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DRIVE_WRITER_TOKEN_STORE_JSON": .object([
          "fromEnv": .string("RIELA_DOCS_READER_TOKEN_STORE")
        ])
      ],
      environment: ["RIELA_DOCS_READER_TOKEN_STORE": "sentinel"],
      code: .policyBlocked,
      messageContains: "addon.env target 'GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DRIVE_WRITER_TOKEN_STORE_JSON'"
    )
  }

  func testEnvironmentBindingsAllowCredentialDirectoryRelocation() async throws {
    let fake = try FakeGoogleDocumentsGateway(mode: "values-success")
    defer { fake.cleanup() }

    _ = try await runDocuments(
      name: "riela/google-docs-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "command": .string("document get"),
        "argsTemplate": .object(["document-id": .string("DOC-1")])
      ],
      env: [
        "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DIR": .object([
          "fromEnv": .string("RIELA_DOCS_CREDENTIAL_DIR")
        ])
      ],
      environment: ["RIELA_DOCS_CREDENTIAL_DIR": "/tmp/riela-credentials"]
    )
    let childEnvironment = try String(contentsOf: fake.environmentLogURL)
    XCTAssertTrue(childEnvironment.contains("GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DIR=/tmp/riela-credentials"))
  }

  func testRoleBinariesResolveFromPath() async throws {
    let writerFake = try FakeGoogleDocumentsGateway(
      mode: "values-success",
      executableName: "google-sheet-gateway-writer"
    )
    defer { writerFake.cleanup() }

    let output = try await runDocuments(
      name: "riela/google-sheet-gateway-write",
      config: [
        "command": .string("values clear"),
        "argsTemplate": .object([
          "spreadsheet-id": .string("SHEET-1"),
          "range": .string("Sheet1!A1"),
          "confirm-clear": .bool(true)
        ])
      ],
      environment: ["PATH": writerFake.binURL.path]
    )
    XCTAssertEqual(documentsBinaryPath(output), writerFake.executableURL.path)
  }

  func testErrorEnvelopeMapsArgumentCodesToInvalidInput() async throws {
    let invalidFake = try FakeGoogleDocumentsGateway(mode: "invalid-argument")
    defer { invalidFake.cleanup() }

    try await assertDocumentsFailure(
      name: "riela/google-docs-gateway-read",
      config: [
        "binaryPath": .string(invalidFake.executableURL.path),
        "command": .string("document get")
      ],
      code: .invalidInput,
      messageContains: "INVALID_ARGUMENT"
    )

    let providerFake = try FakeGoogleDocumentsGateway(mode: "provider-error")
    defer { providerFake.cleanup() }

    try await assertDocumentsFailure(
      name: "riela/google-docs-gateway-read",
      config: [
        "binaryPath": .string(providerFake.executableURL.path),
        "command": .string("document get"),
        "argsTemplate": .object(["document-id": .string("DOC-1")])
      ],
      code: .providerError,
      messageContains: "AUTH_REQUIRED"
    )
  }

  func testNonzeroExitWithoutJSONReportsExitCode() async throws {
    let fake = try FakeGoogleDocumentsGateway(mode: "nonzero-plain")
    defer { fake.cleanup() }

    try await assertDocumentsFailure(
      name: "riela/google-docs-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "command": .string("document get"),
        "argsTemplate": .object(["document-id": .string("DOC-1")])
      ],
      code: .providerError,
      messageContains: "exit code 5"
    )
  }

  private func runDocuments(
    name: String,
    config: JSONObject = [:],
    env: JSONObject? = nil,
    environment: [String: String] = [:],
    variables: JSONObject = [:]
  ) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(environment: environment).execute(
      WorkflowAddonExecutionInput(
        workflowId: "google-documents-gateway-test",
        stepId: "documents-step",
        nodeId: "documents-node",
        addon: WorkflowNodeAddonRef(
          name: name,
          version: "1",
          config: config,
          env: env,
          inputs: [:]
        ),
        variables: variables,
        resolvedInputPayload: [:]
      ),
      context: AdapterExecutionContext()
    )
  }

  private func assertDocumentsFailure(
    name: String,
    config: JSONObject = [:],
    env: JSONObject? = nil,
    environment: [String: String] = [:],
    code: AdapterExecutionErrorCode,
    messageContains: String
  ) async throws {
    do {
      _ = try await runDocuments(name: name, config: config, env: env, environment: environment)
      XCTFail("expected google-documents-gateway add-on to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, code)
      XCTAssertTrue(error.message.contains(messageContains), error.message)
    }
  }

  private func documentsBinaryPath(_ output: AdapterExecutionOutput) -> String? {
    guard case let .object(gateway)? = output.payload["googleDocumentsGateway"],
          case let .object(binary)? = gateway["binary"],
          case let .string(path)? = binary["path"] else {
      return nil
    }
    return path
  }
}

private struct FakeGoogleDocumentsGateway {
  var rootURL: URL
  var binURL: URL
  var executableURL: URL
  var argumentsLogURL: URL
  var environmentLogURL: URL

  init(mode: String, executableName: String = "fake-google-documents-gateway") throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-google-documents-gateway-addon-\(UUID().uuidString)", isDirectory: true)
    binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
    executableURL = binURL.appendingPathComponent(executableName)
    argumentsLogURL = rootURL.appendingPathComponent("arguments.log")
    environmentLogURL = rootURL.appendingPathComponent("environment.log")
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
    printf "%s" "$*" > "\(argumentsLogURL.path)"
    {
      printf "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_JSON=%s\\n" "${GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_JSON:-}"
      printf "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DIR=%s\\n" "${GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DIR:-}"
      printf "OPENAI_API_KEY=%s\\n" "${OPENAI_API_KEY:-}"
    } > "\(environmentLogURL.path)"
    case "\(mode)" in
      values-success)
        printf '{"ok":true,"data":{"operation":"values.get","data":{"range":"Sheet1!A1:B2","values":[["a","b"],["c","d"]]},"requestId":"req-1"}}\\n'
        ;;
      invalid-argument)
        printf '{"ok":false,"error":{"code":"INVALID_ARGUMENT","message":"Missing required option --document-id."}}\\n'
        exit 2
        ;;
      provider-error)
        printf '{"ok":false,"error":{"code":"AUTH_REQUIRED","message":"No stored token for docs-reader."}}\\n'
        exit 4
        ;;
      nonzero-plain)
        echo "transport unavailable" >&2
        exit 5
        ;;
    esac
    """
  }
}
