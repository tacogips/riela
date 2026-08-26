import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class GmailGatewayAddonTests: XCTestCase {
  func testReaderRendersValuesIntoDocumentAndUsesQueryFlag() async throws {
    let fake = try FakeGmailGateway(mode: "threads-success")
    defer { fake.cleanup() }

    let output = try await runGmail(
      name: "riela/gmail-gateway-reader",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "queryTemplate": .string("{ threads(accountId: \"{{workflowInput.accountId}}\", first: 5) { nodes { id subject } } }"),
        "whenFlags": .object(["has_threads": .string("data.threads.nodes.0.id")])
      ],
      variables: [
        "workflowInput": .object(["accountId": .string("personal")])
      ]
    )

    let invocation = try String(contentsOf: fake.invocationLogURL)
    XCTAssertTrue(invocation.hasPrefix("graphql --query "))
    let document = try String(contentsOf: fake.queryLogURL)
    XCTAssertTrue(document.contains("threads(accountId: \"personal\", first: 5)"))
    XCTAssertEqual(output.when["has_threads"], true)
    XCTAssertEqual(output.when["ok"], true)
    let data = gmailTestObject(output.payload["data"])
    XCTAssertNotNil(data?["threads"])
    XCTAssertEqual(gmailBinaryPath(output), fake.executableURL.path)
  }

  func testVariablesTemplateIsRejectedBecauseCLIDoesNotSupportVariables() async throws {
    let fake = try FakeGmailGateway(mode: "threads-success")
    defer { fake.cleanup() }

    try await assertGmailFailure(
      name: "riela/gmail-gateway-reader",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "queryTemplate": .string("{ accounts { id } }"),
        "variablesTemplate": .object(["id": .string("personal")])
      ],
      code: .policyBlocked,
      messageContains: "config.variablesTemplate is not supported"
    )
  }

  func testEnvironmentBindingsAllowConfigAndCredentialShapes() async throws {
    let fake = try FakeGmailGateway(mode: "threads-success")
    defer { fake.cleanup() }

    _ = try await runGmail(
      name: "riela/gmail-gateway-reader",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "queryTemplate": .string("{ accounts { id } }")
      ],
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

    let childEnvironment = try String(contentsOf: fake.environmentLogURL)
    XCTAssertTrue(childEnvironment.contains("GMAIL_GATEWAY_CONFIG=/tmp/config.toml"))
    XCTAssertTrue(childEnvironment.contains("GMAIL_GATEWAY_CREDENTIAL_DIR=/tmp/riela-credentials"))
    XCTAssertTrue(childEnvironment.contains("GMAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_TOKEN_STORE_JSON=sentinel-token-store"))
    XCTAssertFalse(childEnvironment.contains("sentinel-openai"))
  }

  func testEnvironmentBindingRejectsNonGmailTargetNames() async throws {
    let fake = try FakeGmailGateway(mode: "threads-success")
    defer { fake.cleanup() }

    try await assertGmailFailure(
      name: "riela/gmail-gateway-reader",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "queryTemplate": .string("{ accounts { id } }")
      ],
      env: ["LD_PRELOAD": .object(["fromEnv": .string("RIELA_GMAIL_TOKEN_STORE")])],
      environment: ["RIELA_GMAIL_TOKEN_STORE": "sentinel"],
      code: .policyBlocked,
      messageContains: "addon.env target 'LD_PRELOAD'"
    )
  }

  func testEnvironmentBindingRejectsMalformedCredentialSuffix() async throws {
    let fake = try FakeGmailGateway(mode: "threads-success")
    defer { fake.cleanup() }

    try await assertGmailFailure(
      name: "riela/gmail-gateway-reader",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "queryTemplate": .string("{ accounts { id } }")
      ],
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

  func testDraftAndSenderResolveTierSpecificExecutablesFromPath() async throws {
    let draftFake = try FakeGmailGateway(mode: "send-success", executableName: "gmail-gateway-draft")
    let senderFake = try FakeGmailGateway(mode: "send-success", executableName: "gmail-gateway-sender")
    defer {
      draftFake.cleanup()
      senderFake.cleanup()
    }

    let draftOutput = try await runGmail(
      name: "riela/gmail-gateway-draft",
      config: ["queryTemplate": .string("mutation { sendMessage(input: { accountId: \"personal\" }) { operation } }")],
      environment: ["PATH": draftFake.binURL.path]
    )
    XCTAssertEqual(gmailBinaryPath(draftOutput), draftFake.executableURL.path)

    let senderOutput = try await runGmail(
      name: "riela/gmail-gateway-sender",
      config: ["queryTemplate": .string("mutation { sendMessage(input: { accountId: \"personal\" }) { operation } }")],
      environment: ["PATH": senderFake.binURL.path]
    )
    XCTAssertEqual(gmailBinaryPath(senderOutput), senderFake.executableURL.path)
  }

  func testGraphQLErrorEnvelopeFailsWithStableCode() async throws {
    let fake = try FakeGmailGateway(mode: "graphql-error")
    defer { fake.cleanup() }

    try await assertGmailFailure(
      name: "riela/gmail-gateway-reader",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "queryTemplate": .string("{ nope { id } }")
      ],
      code: .providerError,
      messageContains: "INVALID_ARGUMENT"
    )
  }

  func testCLIErrorWithEmptyStdoutReportsExitCodeAndStderr() async throws {
    let fake = try FakeGmailGateway(mode: "cli-error")
    defer { fake.cleanup() }

    try await assertGmailFailure(
      name: "riela/gmail-gateway-reader",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "queryTemplate": .string("{ accounts { id } }")
      ],
      code: .providerError,
      messageContains: "exit code 2"
    )
  }

  func testMissingQueryTemplateIsRejected() async throws {
    try await assertGmailFailure(
      name: "riela/gmail-gateway-reader",
      config: [:],
      code: .policyBlocked,
      messageContains: "config.queryTemplate is required"
    )
  }

  private func runGmail(
    name: String,
    config: JSONObject = [:],
    env: JSONObject? = nil,
    environment: [String: String] = [:],
    variables: JSONObject = [:]
  ) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(environment: environment).execute(
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
    name: String,
    config: JSONObject = [:],
    env: JSONObject? = nil,
    environment: [String: String] = [:],
    code: AdapterExecutionErrorCode,
    messageContains: String
  ) async throws {
    do {
      _ = try await runGmail(name: name, config: config, env: env, environment: environment)
      XCTFail("expected gmail-gateway add-on to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, code)
      XCTAssertTrue(error.message.contains(messageContains), error.message)
    }
  }

  private func gmailBinaryPath(_ output: AdapterExecutionOutput) -> String? {
    guard case let .object(gateway)? = output.payload["gmailGateway"],
          case let .object(binary)? = gateway["binary"],
          case let .string(path)? = binary["path"] else {
      return nil
    }
    return path
  }
}

private struct FakeGmailGateway {
  var rootURL: URL
  var binURL: URL
  var executableURL: URL
  var invocationLogURL: URL
  var queryLogURL: URL
  var environmentLogURL: URL

  init(mode: String, executableName: String = "fake-gmail-gateway") throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-gmail-gateway-addon-\(UUID().uuidString)", isDirectory: true)
    binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
    executableURL = binURL.appendingPathComponent(executableName)
    invocationLogURL = rootURL.appendingPathComponent("invocation.log")
    queryLogURL = rootURL.appendingPathComponent("query.graphql")
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
    printf "%s %s %s" "$1" "$2" "$3" > "\(invocationLogURL.path)"
    if [ "$2" = "--query" ]; then
      printf "%s" "$3" > "\(queryLogURL.path)"
    fi
    {
      printf "GMAIL_GATEWAY_CONFIG=%s\\n" "${GMAIL_GATEWAY_CONFIG:-}"
      printf "GMAIL_GATEWAY_CREDENTIAL_DIR=%s\\n" "${GMAIL_GATEWAY_CREDENTIAL_DIR:-}"
      printf "GMAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_TOKEN_STORE_JSON=%s\\n" "${GMAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_TOKEN_STORE_JSON:-}"
      printf "OPENAI_API_KEY=%s\\n" "${OPENAI_API_KEY:-}"
    } > "\(environmentLogURL.path)"
    case "\(mode)" in
      threads-success)
        printf '{"data":{"threads":{"nodes":[{"id":"THREAD-1","subject":"Hello"}]}}}\\n'
        ;;
      send-success)
        printf '{"data":{"sendMessage":{"operation":"CREATE_DRAFT","messageId":"MSG-1"}}}\\n'
        ;;
      graphql-error)
        printf '{"data":null,"errors":[{"message":"Unsupported GraphQL query","extensions":{"code":"INVALID_ARGUMENT","exitCode":5,"requestId":"req-1"}}]}\\n'
        exit 5
        ;;
      cli-error)
        printf '{"error":{"message":"GraphQL variables are not supported yet","code":"INVALID_ARGUMENT","exitCode":2}}\\n' >&2
        exit 2
        ;;
    esac
    """
  }
}

private func gmailTestObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object)? = value else {
    return nil
  }
  return object
}
