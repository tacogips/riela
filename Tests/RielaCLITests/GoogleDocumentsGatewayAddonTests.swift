import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

/// google-documents-gateway is linked into this process, so these tests record
/// what the add-on hands its command runner — role, arguments, and the
/// environment the gateway is allowed to see — instead of stubbing an
/// executable on `PATH`. The gateway's own tests cover the runner.
final class GoogleDocumentsGatewayAddonTests: XCTestCase {
  private static let valuesResponse = #"{"ok":true,"data":{"data":{"values":[["A1","B1"]]}}}"#
  func testSheetReadRendersCommandAndSortedEqualsBoundFlags() async throws {
    let gateway = RecordingGoogleDocumentsGatewayRunner(response: Self.valuesResponse)

    let output = try await runDocuments(
      gateway: gateway,
      name: "riela/google-sheet-gateway-read",
      config: [
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

    let call = try XCTUnwrap(gateway.lastCall())
    XCTAssertEqual(call.tier, "google-sheet-gateway-reader")
    XCTAssertEqual(
      call.arguments,
      ["values", "get", "--range=Sheet1!A1:B2", "--spreadsheet-id=SHEET-1"]
    )
    XCTAssertEqual(output.payload["command"], .string("values get"))
    XCTAssertEqual(output.when["has_values"], true)
    XCTAssertEqual(output.when["ok"], true)
    XCTAssertEqual(documentsTier(output), "google-sheet-gateway-reader")
  }

  func testBooleanArrayAndOmittedFlagEncodings() async throws {
    let gateway = RecordingGoogleDocumentsGatewayRunner(response: Self.valuesResponse)

    _ = try await runDocuments(
      gateway: gateway,
      name: "riela/google-drive-gateway-read",
      config: [
        "command": .string("files list"),
        "argsTemplate": .object([
          "page-all": .bool(true),
          "online": .bool(false),
          "page-size": .integer(25),
          "fields": .array([.string("id"), .string("name")])
        ])
      ]
    )

    XCTAssertEqual(
      gateway.lastCall()?.arguments,
      ["files", "list", "--fields=id", "--fields=name", "--page-all", "--page-size=25"]
    )
  }

  func testInteractiveAuthCommandsAreRefused() async throws {

    try await assertDocumentsFailure(
      name: "riela/google-docs-gateway-read",
      config: [
        "command": .string("auth login")
      ],
      code: .policyBlocked,
      messageContains: "refuses 'auth login'"
    )
    try await assertDocumentsFailure(
      name: "riela/google-docs-gateway-read",
      config: [
        "command": .string("auth revoke")
      ],
      code: .policyBlocked,
      messageContains: "refuses 'auth revoke'"
    )
  }

  func testMalformedCommandAndFlagNamesAreRejected() async throws {

    try await assertDocumentsFailure(
      name: "riela/google-docs-gateway-read",
      config: [
        "command": .string("document get extra-word")
      ],
      code: .policyBlocked,
      messageContains: "config.command must be one or two lowercase command words"
    )
    try await assertDocumentsFailure(
      name: "riela/google-docs-gateway-read",
      config: [
        "command": .string("--document-id")
      ],
      code: .policyBlocked,
      messageContains: "config.command must be one or two lowercase command words"
    )
    try await assertDocumentsFailure(
      name: "riela/google-docs-gateway-read",
      config: [
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
    let gateway = RecordingGoogleDocumentsGatewayRunner(response: Self.valuesResponse)

    _ = try await runDocuments(
      gateway: gateway,
      name: "riela/google-docs-gateway-read",
      config: [
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
    let call = try XCTUnwrap(gateway.lastCall())
    XCTAssertEqual(
      call.environment["GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_JSON"],
      "sentinel-token-store"
    )
    // Hosting the gateway in this process must not widen what it can read:
    // ambient secrets are still withheld.
    XCTAssertNil(call.environment["OPENAI_API_KEY"])

    try await assertDocumentsFailure(
      name: "riela/google-docs-gateway-read",
      config: [
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
    let gateway = RecordingGoogleDocumentsGatewayRunner(response: Self.valuesResponse)

    _ = try await runDocuments(
      gateway: gateway,
      name: "riela/google-docs-gateway-read",
      config: [
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
    XCTAssertEqual(
      gateway.lastCall()?.environment["GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DIR"],
      "/tmp/riela-credentials"
    )
  }

  func testEachAddonPinsItsOwnRole() async throws {
    let gateway = RecordingGoogleDocumentsGatewayRunner(response: Self.valuesResponse)

    let output = try await runDocuments(
      gateway: gateway,
      name: "riela/google-sheet-gateway-write",
      config: [
        "command": .string("values clear"),
        "argsTemplate": .object([
          "spreadsheet-id": .string("SHEET-1"),
          "range": .string("Sheet1!A1"),
          "confirm-clear": .bool(true)
        ])
      ]
    )
    XCTAssertEqual(documentsTier(output), "google-sheet-gateway-writer")
    XCTAssertEqual(gateway.lastCall()?.tier, "google-sheet-gateway-writer")
  }

  func testErrorEnvelopeMapsArgumentCodesToInvalidInput() async throws {
    try await assertDocumentsFailure(
      gateway: RecordingGoogleDocumentsGatewayRunner(
        response: #"{"ok":false,"error":{"code":"INVALID_ARGUMENT","message":"unknown flag"}}"#
      ),
      name: "riela/google-docs-gateway-read",
      config: ["command": .string("document get")],
      code: .invalidInput,
      messageContains: "INVALID_ARGUMENT"
    )

    try await assertDocumentsFailure(
      gateway: RecordingGoogleDocumentsGatewayRunner(
        response: #"{"ok":false,"error":{"code":"AUTH_REQUIRED","message":"configure a credential"}}"#
      ),
      name: "riela/google-docs-gateway-read",
      config: [
        "command": .string("document get"),
        "argsTemplate": .object(["document-id": .string("DOC-1")])
      ],
      code: .providerError,
      messageContains: "AUTH_REQUIRED"
    )
  }

  func testNonEnvelopeOutputIsRejected() async throws {
    try await assertDocumentsFailure(
      gateway: RecordingGoogleDocumentsGatewayRunner(response: "credential store unavailable"),
      name: "riela/google-docs-gateway-read",
      config: [
        "command": .string("document get"),
        "argsTemplate": .object(["document-id": .string("DOC-1")])
      ],
      code: .invalidOutput,
      messageContains: "not a google-documents-gateway JSON envelope"
    )
  }

  func testGatewayFailureIsSurfacedAsAProviderError() async throws {
    try await assertDocumentsFailure(
      gateway: RecordingGoogleDocumentsGatewayRunner(
        failure: AdapterExecutionError(
          .providerError,
          "google-docs-gateway-reader failed with exit code 5"
        )
      ),
      name: "riela/google-docs-gateway-read",
      config: [
        "command": .string("document get"),
        "argsTemplate": .object(["document-id": .string("DOC-1")])
      ],
      code: .providerError,
      messageContains: "exit code 5"
    )
  }

  private func runDocuments(
    gateway: RecordingGoogleDocumentsGatewayRunner = RecordingGoogleDocumentsGatewayRunner(),
    name: String,
    config: JSONObject = [:],
    env: JSONObject? = nil,
    environment: [String: String] = [:],
    variables: JSONObject = [:]
  ) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(
      environment: environment,
      googleDocumentsGatewayRunner: gateway.runner
    ).execute(
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
    gateway: RecordingGoogleDocumentsGatewayRunner = RecordingGoogleDocumentsGatewayRunner(),
    name: String,
    config: JSONObject = [:],
    env: JSONObject? = nil,
    environment: [String: String] = [:],
    code: AdapterExecutionErrorCode,
    messageContains: String
  ) async throws {
    do {
      _ = try await runDocuments(
        gateway: gateway,
        name: name,
        config: config,
        env: env,
        environment: environment
      )
      XCTFail("expected google-documents-gateway add-on to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, code)
      XCTAssertTrue(error.message.contains(messageContains), error.message)
    }
  }

  private func documentsTier(_ output: AdapterExecutionOutput) -> String? {
    guard case let .object(gateway)? = output.payload["googleDocumentsGateway"],
          case let .object(runtime)? = gateway["runtime"],
          case let .string(tier)? = runtime["tier"] else {
      return nil
    }
    return tier
  }
}

