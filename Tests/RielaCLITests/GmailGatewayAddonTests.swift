import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

/// gmail-gateway is linked into this process, so these tests record what the
/// add-on hands its GraphQL surface — mode, document, and the environment the
/// gateway is allowed to see — instead of stubbing an executable on `PATH`.
/// gmail-gateway's own tests cover the surface.
final class GmailGatewayAddonTests: XCTestCase {
  func testReaderRendersValuesIntoDocumentAndUsesQueryFlag() async throws {
    let gateway = RecordingGatewayGraphQLRunner(
      response: #"{"data":{"threads":{"nodes":[{"id":"THREAD-1","subject":"Hello"}]}}}"#
    )

    let output = try await runGmail(
      gateway: gateway,
      name: "riela/gmail-gateway-reader",
      config: [
        "queryTemplate": .string("{ threads(accountId: \"{{workflowInput.accountId}}\", first: 5) { nodes { id subject } } }"),
        "whenFlags": .object(["has_threads": .string("data.threads.nodes.0.id")])
      ],
      variables: [
        "workflowInput": .object(["accountId": .string("personal")])
      ]
    )

    let call = try XCTUnwrap(gateway.lastCall())
    XCTAssertEqual(call.tier, "gmail-gateway-reader")
    XCTAssertTrue(call.document.contains("threads(accountId: \"personal\", first: 5)"))
    // gmail-gateway takes no GraphQL variables; values render into the text.
    XCTAssertNil(call.variablesJSON)
    XCTAssertEqual(output.when["has_threads"], true)
    XCTAssertEqual(output.when["ok"], true)
    let data = gmailTestObject(output.payload["data"])
    XCTAssertNotNil(data?["threads"])
    XCTAssertEqual(gmailTier(output), "gmail-gateway-reader")
  }

  func testVariablesTemplateIsRejectedBecauseCLIDoesNotSupportVariables() async throws {
    try await assertGmailFailure(
      gateway: RecordingGatewayGraphQLRunner(),
      name: "riela/gmail-gateway-reader",
      config: [
        "queryTemplate": .string("{ accounts { id } }"),
        "variablesTemplate": .object(["id": .string("personal")])
      ],
      code: .policyBlocked,
      messageContains: "config.variablesTemplate is not supported"
    )
  }

  func testEnvironmentBindingsAllowConfigAndCredentialShapes() async throws {
    let gateway = RecordingGatewayGraphQLRunner(response: #"{"data":{"accounts":[]}}"#)

    _ = try await runGmail(
      gateway: gateway,
      name: "riela/gmail-gateway-reader",
      config: ["queryTemplate": .string("{ accounts { id } }")],
      env: [
        "GMAIL_GATEWAY_CONFIG": .object(["fromEnv": .string("RIELA_GMAIL_CONFIG")]),
        "GMAIL_GATEWAY_CREDENTIAL_DIR": .object(["fromEnv": .string("RIELA_GMAIL_CREDENTIAL_DIR")]),
        "GMAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_TOKEN_STORE_JSON": .object([
          "fromEnv": .string("RIELA_GMAIL_TOKEN_STORE")
        ])
      ],
      environment: [
        "RIELA_GMAIL_CONFIG": "/tmp/config.toml",
        "RIELA_GMAIL_CREDENTIAL_DIR": "/tmp/riela-credentials",
        "RIELA_GMAIL_TOKEN_STORE": "sentinel-token-store",
        "OPENAI_API_KEY": "sentinel-openai"
      ]
    )

    let call = try XCTUnwrap(gateway.lastCall())
    XCTAssertEqual(call.environment["GMAIL_GATEWAY_CONFIG"], "/tmp/config.toml")
    XCTAssertEqual(call.environment["GMAIL_GATEWAY_CREDENTIAL_DIR"], "/tmp/riela-credentials")
    XCTAssertEqual(
      call.environment["GMAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_TOKEN_STORE_JSON"],
      "sentinel-token-store"
    )
    // Hosting the gateway in this process must not widen what it can read:
    // ambient secrets are still withheld.
    XCTAssertNil(call.environment["OPENAI_API_KEY"])
  }

  func testEnvironmentBindingRejectsNonGmailTargetNames() async throws {
    try await assertGmailFailure(
      gateway: RecordingGatewayGraphQLRunner(),
      name: "riela/gmail-gateway-reader",
      config: ["queryTemplate": .string("{ accounts { id } }")],
      env: ["LD_PRELOAD": .object(["fromEnv": .string("RIELA_GMAIL_TOKEN_STORE")])],
      environment: ["RIELA_GMAIL_TOKEN_STORE": "sentinel"],
      code: .policyBlocked,
      messageContains: "addon.env target 'LD_PRELOAD'"
    )
  }

  func testEnvironmentBindingRejectsMalformedCredentialSuffix() async throws {
    try await assertGmailFailure(
      gateway: RecordingGatewayGraphQLRunner(),
      name: "riela/gmail-gateway-reader",
      config: ["queryTemplate": .string("{ accounts { id } }")],
      env: [
        "GMAIL_GATEWAY_CREDENTIAL_bad-id_TOKEN_STORE_JSON": .object([
          "fromEnv": .string("RIELA_GMAIL_TOKEN_STORE")
        ])
      ],
      environment: ["RIELA_GMAIL_TOKEN_STORE": "sentinel"],
      code: .policyBlocked,
      messageContains: "addon.env target 'GMAIL_GATEWAY_CREDENTIAL_bad-id_TOKEN_STORE_JSON'"
    )
  }

  func testDraftAndSenderPinTheirOwnTier() async throws {
    let response = #"{"data":{"sendMessage":{"operation":"CREATE_DRAFT","messageId":"MSG-1"}}}"#
    let draft = RecordingGatewayGraphQLRunner(response: response)
    let sender = RecordingGatewayGraphQLRunner(response: response)
    let document = "mutation { sendMessage(input: { accountId: \"personal\" }) { operation } }"

    let draftOutput = try await runGmail(
      gateway: draft,
      name: "riela/gmail-gateway-draft",
      config: ["queryTemplate": .string(document)]
    )
    XCTAssertEqual(gmailTier(draftOutput), "gmail-gateway-draft")
    XCTAssertEqual(draft.lastCall()?.tier, "gmail-gateway-draft")

    let senderOutput = try await runGmail(
      gateway: sender,
      name: "riela/gmail-gateway-sender",
      config: ["queryTemplate": .string(document)]
    )
    XCTAssertEqual(gmailTier(senderOutput), "gmail-gateway-sender")
    XCTAssertEqual(sender.lastCall()?.tier, "gmail-gateway-sender")
  }

  func testGraphQLErrorEnvelopeFailsWithStableCode() async throws {
    try await assertGmailFailure(
      gateway: RecordingGatewayGraphQLRunner(
        response: #"{"data":null,"errors":[{"message":"Unsupported GraphQL query","extensions":{"code":"INVALID_ARGUMENT","exitCode":5,"requestId":"req-1"}}]}"#
      ),
      name: "riela/gmail-gateway-reader",
      config: ["queryTemplate": .string("{ nope { id } }")],
      code: .providerError,
      messageContains: "INVALID_ARGUMENT"
    )
  }

  func testGatewayFailureIsSurfacedAsAProviderError() async throws {
    try await assertGmailFailure(
      gateway: RecordingGatewayGraphQLRunner(
        failure: AdapterExecutionError(
          .providerError,
          "gmail-gateway gmail-gateway-reader failed with exit code 2: GraphQL variables are not supported yet"
        )
      ),
      name: "riela/gmail-gateway-reader",
      config: ["queryTemplate": .string("{ accounts { id } }")],
      code: .providerError,
      messageContains: "exit code 2"
    )
  }

  func testMissingQueryTemplateIsRejected() async throws {
    try await assertGmailFailure(
      gateway: RecordingGatewayGraphQLRunner(),
      name: "riela/gmail-gateway-reader",
      config: [:],
      code: .policyBlocked,
      messageContains: "config.queryTemplate is required"
    )
  }

  private func runGmail(
    gateway: RecordingGatewayGraphQLRunner,
    name: String,
    config: JSONObject = [:],
    env: JSONObject? = nil,
    environment: [String: String] = [:],
    variables: JSONObject = [:]
  ) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(
      environment: environment,
      localGatewayGraphQLRunner: gateway.runner
    ).execute(
      WorkflowAddonExecutionInput(
        workflowId: "gmail-gateway-test",
        stepId: "gmail-step",
        nodeId: "gmail-node",
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

  private func assertGmailFailure(
    gateway: RecordingGatewayGraphQLRunner,
    name: String,
    config: JSONObject = [:],
    env: JSONObject? = nil,
    environment: [String: String] = [:],
    code: AdapterExecutionErrorCode,
    messageContains: String
  ) async throws {
    do {
      _ = try await runGmail(
        gateway: gateway,
        name: name,
        config: config,
        env: env,
        environment: environment
      )
      XCTFail("expected gmail-gateway add-on to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, code)
      XCTAssertTrue(error.message.contains(messageContains), error.message)
    }
  }

  private func gmailTier(_ output: AdapterExecutionOutput) -> String? {
    guard case let .object(gateway)? = output.payload["gmailGateway"],
          case let .object(runtime)? = gateway["runtime"],
          case let .string(tier)? = runtime["tier"] else {
      return nil
    }
    return tier
  }
}

private func gmailTestObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object)? = value else {
    return nil
  }
  return object
}
