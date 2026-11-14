import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class GoogleAnalyticsGatewayAddonTests: XCTestCase {
  func testReadRendersDocumentAndVariables() async throws {
    let fake = try FakeGoogleAnalyticsGateway(mode: "accounts-success")
    defer { fake.cleanup() }

    let output = try await runAnalytics(
      name: "riela/google-analytics-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "queryTemplate": .string("query P($id: ID!) { gaProperty(propertyId: $id) { name displayName } }"),
        "variablesTemplate": .object(["id": .string("{{workflowInput.propertyId}}")]),
        "whenFlags": .object(["has_accounts": .string("data.gaAccountSummaries.nodes.0.name")])
      ],
      variables: [
        "workflowInput": .object(["propertyId": .string("properties/123")])
      ]
    )

    let document = try String(contentsOf: fake.queryLogURL)
    XCTAssertTrue(document.contains("gaProperty(propertyId: $id)"))
    let variablesJSON = try String(contentsOf: fake.variablesLogURL)
    XCTAssertTrue(variablesJSON.contains("\"id\":\"properties/123\""))
    XCTAssertEqual(output.when["has_accounts"], true)
    XCTAssertEqual(output.when["ok"], true)
    let data = analyticsTestObject(output.payload["data"])
    XCTAssertNotNil(data?["gaAccountSummaries"])
    XCTAssertEqual(analyticsBinaryPath(output), fake.executableURL.path)
  }

  func testEnvironmentBindingsInjectOnlyAllowedAnalyticsVariables() async throws {
    let fake = try FakeGoogleAnalyticsGateway(mode: "accounts-success")
    defer { fake.cleanup() }

    _ = try await runAnalytics(
      name: "riela/google-analytics-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "queryTemplate": .string("{ gaAccountSummaries { nodes { name } } }")
      ],
      env: [
        "GOOGLE_ANALYTICS_GATEWAY_ACCESS_TOKEN": .object(["fromEnv": .string("RIELA_GA_ACCESS_TOKEN")])
      ],
      environment: [
        "RIELA_GA_ACCESS_TOKEN": "sentinel-token",
        "OPENAI_API_KEY": "sentinel-openai"
      ]
    )

    let childEnvironment = try String(contentsOf: fake.environmentLogURL)
    XCTAssertTrue(childEnvironment.contains("GOOGLE_ANALYTICS_GATEWAY_ACCESS_TOKEN=sentinel-token"))
    XCTAssertFalse(childEnvironment.contains("sentinel-openai"))
  }

  func testEnvironmentBindingRejectsNonAnalyticsTargetNames() async throws {
    let fake = try FakeGoogleAnalyticsGateway(mode: "accounts-success")
    defer { fake.cleanup() }

    try await assertAnalyticsFailure(
      name: "riela/google-analytics-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "queryTemplate": .string("{ gaAccountSummaries { nodes { name } } }")
      ],
      env: ["LD_PRELOAD": .object(["fromEnv": .string("RIELA_GA_ACCESS_TOKEN")])],
      environment: ["RIELA_GA_ACCESS_TOKEN": "sentinel-token"],
      code: .policyBlocked,
      messageContains: "addon.env target 'LD_PRELOAD'"
    )
  }

  func testWriteAndAdminResolveTierSpecificExecutablesFromPath() async throws {
    let writerFake = try FakeGoogleAnalyticsGateway(
      mode: "mutation-success",
      executableName: "google-analytics-gateway-writer"
    )
    let adminFake = try FakeGoogleAnalyticsGateway(
      mode: "mutation-success",
      executableName: "google-analytics-gateway-admin"
    )
    defer {
      writerFake.cleanup()
      adminFake.cleanup()
    }

    let writeOutput = try await runAnalytics(
      name: "riela/google-analytics-gateway-write",
      config: ["queryTemplate": .string("mutation { gtmPublishVersion(input: { path: \"v\" }) { path } }")],
      environment: ["PATH": writerFake.binURL.path]
    )
    XCTAssertEqual(analyticsBinaryPath(writeOutput), writerFake.executableURL.path)

    let adminOutput = try await runAnalytics(
      name: "riela/google-analytics-gateway-admin",
      config: ["queryTemplate": .string("mutation { gaDeleteProperty(input: { propertyId: \"p\" }) { name } }")],
      environment: ["PATH": adminFake.binURL.path]
    )
    XCTAssertEqual(analyticsBinaryPath(adminOutput), adminFake.executableURL.path)
  }

  func testGraphQLErrorEnvelopeFailsWithStableCode() async throws {
    let fake = try FakeGoogleAnalyticsGateway(mode: "graphql-error")
    defer { fake.cleanup() }

    try await assertAnalyticsFailure(
      name: "riela/google-analytics-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "queryTemplate": .string("{ gaAccountSummaries { nodes { name } } }")
      ],
      code: .providerError,
      messageContains: "PERMISSION_DENIED"
    )
  }

  func testNonzeroExitWithoutJSONReportsExitCode() async throws {
    let fake = try FakeGoogleAnalyticsGateway(mode: "nonzero-plain")
    defer { fake.cleanup() }

    try await assertAnalyticsFailure(
      name: "riela/google-analytics-gateway-read",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "queryTemplate": .string("{ gaAccountSummaries { nodes { name } } }")
      ],
      code: .providerError,
      messageContains: "exit code 3"
    )
  }

  func testMissingQueryTemplateIsRejected() async throws {
    try await assertAnalyticsFailure(
      name: "riela/google-analytics-gateway-read",
      config: [:],
      code: .policyBlocked,
      messageContains: "config.queryTemplate is required"
    )
  }

  private func runAnalytics(
    name: String,
    config: JSONObject = [:],
    env: JSONObject? = nil,
    environment: [String: String] = [:],
    variables: JSONObject = [:]
  ) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(environment: environment).execute(
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
    name: String,
    config: JSONObject = [:],
    env: JSONObject? = nil,
    environment: [String: String] = [:],
    code: AdapterExecutionErrorCode,
    messageContains: String
  ) async throws {
    do {
      _ = try await runAnalytics(name: name, config: config, env: env, environment: environment)
      XCTFail("expected google-analytics-gateway add-on to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, code)
      XCTAssertTrue(error.message.contains(messageContains), error.message)
    }
  }

  private func analyticsBinaryPath(_ output: AdapterExecutionOutput) -> String? {
    guard case let .object(gateway)? = output.payload["googleAnalyticsGateway"],
          case let .object(binary)? = gateway["binary"],
          case let .string(path)? = binary["path"] else {
      return nil
    }
    return path
  }
}

private struct FakeGoogleAnalyticsGateway {
  var rootURL: URL
  var binURL: URL
  var executableURL: URL
  var queryLogURL: URL
  var variablesLogURL: URL
  var environmentLogURL: URL

  init(mode: String, executableName: String = "fake-google-analytics-gateway") throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-google-analytics-gateway-addon-\(UUID().uuidString)", isDirectory: true)
    binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
    executableURL = binURL.appendingPathComponent(executableName)
    queryLogURL = rootURL.appendingPathComponent("query.graphql")
    variablesLogURL = rootURL.appendingPathComponent("variables.json")
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
    printf "%s" "$3" > "\(queryLogURL.path)"
    if [ "$4" = "--variables" ]; then
      printf "%s" "$5" > "\(variablesLogURL.path)"
    fi
    {
      printf "GOOGLE_ANALYTICS_GATEWAY_ACCESS_TOKEN=%s\\n" "${GOOGLE_ANALYTICS_GATEWAY_ACCESS_TOKEN:-}"
      printf "GOOGLE_ANALYTICS_GATEWAY_CONFIG=%s\\n" "${GOOGLE_ANALYTICS_GATEWAY_CONFIG:-}"
      printf "OPENAI_API_KEY=%s\\n" "${OPENAI_API_KEY:-}"
    } > "\(environmentLogURL.path)"
    case "\(mode)" in
      accounts-success)
        printf '{"data":{"gaAccountSummaries":{"nodes":[{"name":"accountSummaries/1","displayName":"Main"}]}}}\\n'
        ;;
      mutation-success)
        printf '{"data":{"result":{"ok":true}}}\\n'
        ;;
      graphql-error)
        printf '{"data":null,"errors":[{"message":"caller lacks analytics access","extensions":{"code":"PERMISSION_DENIED"}}]}\\n'
        exit 4
        ;;
      nonzero-plain)
        echo "credential profile unavailable" >&2
        exit 3
        ;;
    esac
    """
  }
}

private func analyticsTestObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object)? = value else {
    return nil
  }
  return object
}
