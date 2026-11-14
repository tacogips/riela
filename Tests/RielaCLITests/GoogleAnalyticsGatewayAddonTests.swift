import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

/// The google-analytics gateway is linked into this process, so these tests
/// record what the add-on hands its GraphQL runtime — tier, document,
/// variables, and the environment the gateway is allowed to see — instead of
/// stubbing an executable on `PATH`. The gateway's own tests cover the runtime.
final class GoogleAnalyticsGatewayAddonTests: XCTestCase {
  func testReadRendersDocumentAndVariables() async throws {
    let gateway = RecordingGatewayGraphQLRunner(
      response: #"{"data":{"gaAccountSummaries":{"nodes":[{"name":"accountSummaries/1","displayName":"Main"}]}}}"#
    )

    let output = try await runAnalytics(
      gateway: gateway,
      name: "riela/google-analytics-gateway-read",
      config: [
        "queryTemplate": .string("query P($id: ID!) { gaProperty(propertyId: $id) { name displayName } }"),
        "variablesTemplate": .object(["id": .string("{{workflowInput.propertyId}}")]),
        "whenFlags": .object(["has_accounts": .string("data.gaAccountSummaries.nodes.0.name")])
      ],
      variables: [
        "workflowInput": .object(["propertyId": .string("properties/123")])
      ]
    )

    let call = try XCTUnwrap(gateway.lastCall())
    XCTAssertTrue(call.document.contains("gaProperty(propertyId: $id)"))
    XCTAssertTrue(try XCTUnwrap(call.variablesJSON).contains("\"id\":\"properties/123\""))
    XCTAssertEqual(output.when["has_accounts"], true)
    XCTAssertEqual(output.when["ok"], true)
    let data = analyticsTestObject(output.payload["data"])
    XCTAssertNotNil(data?["gaAccountSummaries"])
    XCTAssertEqual(analyticsTier(output), "google-analytics-gateway-reader")
  }

  func testEnvironmentBindingsInjectOnlyAllowedAnalyticsVariables() async throws {
    let gateway = RecordingGatewayGraphQLRunner(response: #"{"data":{"gaAccountSummaries":{"nodes":[]}}}"#)

    _ = try await runAnalytics(
      gateway: gateway,
      name: "riela/google-analytics-gateway-read",
      config: ["queryTemplate": .string("{ gaAccountSummaries { nodes { name } } }")],
      env: [
        "GOOGLE_ANALYTICS_GATEWAY_ACCESS_TOKEN": .object(["fromEnv": .string("RIELA_GA_ACCESS_TOKEN")])
      ],
      environment: [
        "RIELA_GA_ACCESS_TOKEN": "sentinel-token",
        "OPENAI_API_KEY": "sentinel-openai"
      ]
    )

    let call = try XCTUnwrap(gateway.lastCall())
    XCTAssertEqual(call.environment["GOOGLE_ANALYTICS_GATEWAY_ACCESS_TOKEN"], "sentinel-token")
    // Hosting the gateway in this process must not widen what it can read:
    // ambient secrets are still withheld.
    XCTAssertNil(call.environment["OPENAI_API_KEY"])
    XCTAssertNil(call.environment["RIELA_GA_ACCESS_TOKEN"])
  }

  func testEnvironmentBindingRejectsNonAnalyticsTargetNames() async throws {
    try await assertAnalyticsFailure(
      gateway: RecordingGatewayGraphQLRunner(response: "{}"),
      name: "riela/google-analytics-gateway-read",
      config: ["queryTemplate": .string("{ gaAccountSummaries { nodes { name } } }")],
      env: ["LD_PRELOAD": .object(["fromEnv": .string("RIELA_GA_ACCESS_TOKEN")])],
      environment: ["RIELA_GA_ACCESS_TOKEN": "sentinel-token"],
      code: .policyBlocked,
      messageContains: "addon.env target 'LD_PRELOAD'"
    )
  }

  func testWriteAndAdminPinTheirOwnTier() async throws {
    let gateway = RecordingGatewayGraphQLRunner(response: #"{"data":{"result":{"ok":true}}}"#)

    let writeOutput = try await runAnalytics(
      gateway: gateway,
      name: "riela/google-analytics-gateway-write",
      config: ["queryTemplate": .string("mutation { gtmPublishVersion(input: { path: \"v\" }) { path } }")]
    )
    XCTAssertEqual(analyticsTier(writeOutput), "google-analytics-gateway-writer")
    XCTAssertEqual(gateway.lastCall()?.tier, "google-analytics-gateway-writer")

    let adminOutput = try await runAnalytics(
      gateway: gateway,
      name: "riela/google-analytics-gateway-admin",
      config: ["queryTemplate": .string("mutation { gaDeleteProperty(input: { propertyId: \"p\" }) { name } }")]
    )
    XCTAssertEqual(analyticsTier(adminOutput), "google-analytics-gateway-admin")
    XCTAssertEqual(gateway.lastCall()?.tier, "google-analytics-gateway-admin")
  }

  func testGraphQLErrorEnvelopeFailsWithStableCode() async throws {
    try await assertAnalyticsFailure(
      gateway: RecordingGatewayGraphQLRunner(
        response: #"{"data":null,"errors":[{"message":"caller lacks analytics access","extensions":{"code":"PERMISSION_DENIED"}}]}"#
      ),
      name: "riela/google-analytics-gateway-read",
      config: ["queryTemplate": .string("{ gaAccountSummaries { nodes { name } } }")],
      code: .providerError,
      messageContains: "PERMISSION_DENIED"
    )
  }

  func testGatewayFailureIsSurfacedAsAProviderError() async throws {
    try await assertAnalyticsFailure(
      gateway: RecordingGatewayGraphQLRunner(
        failure: AdapterExecutionError(.providerError, "google-analytics-gateway failed: credential profile unavailable")
      ),
      name: "riela/google-analytics-gateway-read",
      config: ["queryTemplate": .string("{ gaAccountSummaries { nodes { name } } }")],
      code: .providerError,
      messageContains: "credential profile unavailable"
    )
  }

  func testNonJSONOutputIsRejected() async throws {
    try await assertAnalyticsFailure(
      gateway: RecordingGatewayGraphQLRunner(response: "not json at all"),
      name: "riela/google-analytics-gateway-read",
      config: ["queryTemplate": .string("{ gaAccountSummaries { nodes { name } } }")],
      code: .invalidOutput,
      messageContains: "riela/google-analytics-gateway-read"
    )
  }

  func testMissingQueryTemplateIsRejected() async throws {
    try await assertAnalyticsFailure(
      gateway: RecordingGatewayGraphQLRunner(response: "{}"),
      name: "riela/google-analytics-gateway-read",
      config: [:],
      code: .policyBlocked,
      messageContains: "config.queryTemplate is required"
    )
  }

  private func runAnalytics(
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
        workflowId: "google-analytics-gateway-test",
        stepId: "analytics-step",
        nodeId: "analytics-node",
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

  private func assertAnalyticsFailure(
    gateway: RecordingGatewayGraphQLRunner,
    name: String,
    config: JSONObject = [:],
    env: JSONObject? = nil,
    environment: [String: String] = [:],
    code: AdapterExecutionErrorCode,
    messageContains: String
  ) async throws {
    do {
      _ = try await runAnalytics(
        gateway: gateway,
        name: name,
        config: config,
        env: env,
        environment: environment
      )
      XCTFail("expected google-analytics-gateway add-on to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, code)
      XCTAssertTrue(error.message.contains(messageContains), error.message)
    }
  }

  private func analyticsTier(_ output: AdapterExecutionOutput) -> String? {
    guard case let .object(gateway)? = output.payload["googleAnalyticsGateway"],
          case let .object(runtime)? = gateway["runtime"],
          case let .string(tier)? = runtime["tier"] else {
      return nil
    }
    return tier
  }
}

private func analyticsTestObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object)? = value else {
    return nil
  }
  return object
}
