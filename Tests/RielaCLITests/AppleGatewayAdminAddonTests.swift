import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class AppleGatewayAdminAddonTests: XCTestCase {
  func testAdminAddonsResolveBinaryFromConfigEnvThenPathAndSanitizeEnvironment() async throws {
    let configFake = try FakeAdminAppleGateway(mode: "permissions-status")
    let envFake = try FakeAdminAppleGateway(mode: "permissions-status")
    let pathFake = try FakeAdminAppleGateway(mode: "permissions-status", executableName: "apple-gateway")
    defer {
      configFake.cleanup()
      envFake.cleanup()
      pathFake.cleanup()
    }

    let configOutput = try await runAdminAddon(
      "riela/apple-gateway-permissions-status",
      config: ["binaryPath": .string(configFake.executableURL.path)],
      environment: [
        "APPLE_GATEWAY_BIN": envFake.executableURL.path,
        "PATH": pathFake.binURL.path,
        "OPENAI_API_KEY": "sentinel-openai",
        "GITHUB_TOKEN": "sentinel-github",
        "RIELA_SECRET": "sentinel-riela",
        "USER": "riela-test"
      ]
    )
    XCTAssertEqual(adminGatewayBinarySource(configOutput), "config")
    XCTAssertEqual(try configFake.arguments(), ["permissions", "status", "--json"])
    let childEnvironment = try String(contentsOf: configFake.environmentLogURL)
    XCTAssertTrue(childEnvironment.contains("USER=riela-test"))
    XCTAssertFalse(childEnvironment.contains("sentinel-openai"))
    XCTAssertFalse(childEnvironment.contains("sentinel-github"))
    XCTAssertFalse(childEnvironment.contains("sentinel-riela"))

    let envOutput = try await runAdminAddon(
      "riela/apple-gateway-permissions-status",
      environment: [
        "APPLE_GATEWAY_BIN": envFake.executableURL.path,
        "PATH": pathFake.binURL.path
      ]
    )
    XCTAssertEqual(adminGatewayBinarySource(envOutput), "environment")

    let pathOutput = try await runAdminAddon(
      "riela/apple-gateway-permissions-status",
      environment: ["PATH": pathFake.binURL.path]
    )
    XCTAssertEqual(adminGatewayBinarySource(pathOutput), "path")
  }

  func testAdminAddonsIgnoreBinaryPathOutsideLiteralConfigAndRejectAddonEnvAndVersions() async throws {
    let maliciousFake = try FakeAdminAppleGateway(mode: "permissions-status")
    let envFake = try FakeAdminAppleGateway(mode: "permissions-status")
    defer {
      maliciousFake.cleanup()
      envFake.cleanup()
    }

    let output = try await runAdminAddon(
      "riela/apple-gateway-permissions-status",
      inputs: ["binaryPath": .string("{{binaryPath}}")],
      environment: ["APPLE_GATEWAY_BIN": envFake.executableURL.path],
      variables: ["binaryPath": .string(maliciousFake.executableURL.path)],
      resolvedInputPayload: ["binaryPath": .string(maliciousFake.executableURL.path)]
    )
    XCTAssertEqual(adminGatewayBinarySource(output), "environment")
    XCTAssertFalse(FileManager.default.fileExists(atPath: maliciousFake.argumentLogURL.path))

    try await assertAdminFailure(
      "riela/apple-gateway-permissions-status",
      version: "2",
      config: ["binaryPath": .string(envFake.executableURL.path)],
      code: .policyBlocked,
      messageContains: "unsupported"
    )
    try await assertAdminFailure(
      "riela/apple-gateway-permissions-status",
      config: ["binaryPath": .string(envFake.executableURL.path)],
      addonEnv: ["APPLE_GATEWAY_BIN": .object(["fromEnv": .string("APPLE_GATEWAY_BIN")])],
      code: .policyBlocked,
      messageContains: "does not support addon.env"
    )
  }

  func testAdminAddonsTerminateWhenDeadlineExpires() async throws {
    let fake = try FakeAdminAppleGateway(mode: "sleep")
    defer { fake.cleanup() }

    let startedAt = Date()
    try await assertAdminFailure(
      "riela/apple-gateway-schema",
      config: ["binaryPath": .string(fake.executableURL.path)],
      context: AdapterExecutionContext(deadline: Date().addingTimeInterval(0.1)),
      code: .timeout,
      messageContains: "deadline"
    )
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
  }

  func testGraphQLBuildsQueryVariablesArgumentsAndParsesEnvelope() async throws {
    let fake = try FakeAdminAppleGateway(mode: "graphql-success")
    defer { fake.cleanup() }

    let output = try await runAdminAddon(
      "riela/apple-gateway-graphql",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "query": .string("{ viewer { id } }"),
        "variables": .object(["limit": .integer(3)])
      ]
    )

    XCTAssertEqual(try fake.arguments(), [
      "graphql",
      "--query",
      "{ viewer { id } }",
      "--variables",
      "{\"limit\":3}"
    ])
    let appleGateway = try XCTUnwrap(adminGatewayObject(output))
    let data = try XCTUnwrap(adminObject(appleGateway["data"]))
    let viewer = try XCTUnwrap(adminObject(data["viewer"]))
    XCTAssertEqual(viewer["id"], .string("viewer-1"))
    XCTAssertEqual(appleGateway["requestId"], .string("req-admin"))
    XCTAssertEqual(output.payload["replyText"], .string("Apple Gateway GraphQL query completed."))
  }

  func testGraphQLPrefersFilesAndPrependsConfig() async throws {
    let fake = try FakeAdminAppleGateway(mode: "graphql-success")
    defer { fake.cleanup() }

    _ = try await runAdminAddon(
      "riela/apple-gateway-graphql",
      config: [
        "binaryPath": .string(fake.executableURL.path),
        "config": .string("/tmp/ignored-config.json"),
        "query": .string("ignored"),
        "variables": .string("{\"ignored\":true}")
      ],
      inputs: [
        "configPath": .string("/tmp/gateway-config.json"),
        "queryFile": .string("/tmp/query.graphql"),
        "variablesFile": .string("/tmp/variables.json")
      ]
    )

    XCTAssertEqual(try fake.arguments(), [
      "--config",
      "/tmp/gateway-config.json",
      "graphql",
      "--query-file",
      "/tmp/query.graphql",
      "--variables-file",
      "/tmp/variables.json"
    ])
  }

  func testGraphQLValidationAndOutputErrors() async throws {
    let successFake = try FakeAdminAppleGateway(mode: "graphql-success")
    let errorFake = try FakeAdminAppleGateway(mode: "graphql-error")
    let malformedFake = try FakeAdminAppleGateway(mode: "malformed")
    let nonzeroFake = try FakeAdminAppleGateway(mode: "nonzero")
    defer {
      successFake.cleanup()
      errorFake.cleanup()
      malformedFake.cleanup()
      nonzeroFake.cleanup()
    }

    try await assertAdminFailure(
      "riela/apple-gateway-graphql",
      config: ["binaryPath": .string(successFake.executableURL.path)],
      code: .policyBlocked,
      messageContains: "requires query or queryFile"
    )
    try await assertAdminFailure(
      "riela/apple-gateway-graphql",
      config: [
        "binaryPath": .string(errorFake.executableURL.path),
        "query": .string("{ viewer { id } }")
      ],
      code: .providerError,
      messageContains: "permission denied"
    )
    try await assertAdminFailure(
      "riela/apple-gateway-graphql",
      config: [
        "binaryPath": .string(malformedFake.executableURL.path),
        "query": .string("{ viewer { id } }")
      ],
      code: .invalidOutput,
      messageContains: "not valid JSON"
    )
    try await assertAdminFailure(
      "riela/apple-gateway-graphql",
      config: [
        "binaryPath": .string(nonzeroFake.executableURL.path),
        "query": .string("{ viewer { id } }")
      ],
      code: .providerError,
      messageContains: "exit code 7"
    )
  }

  func testSchemaArgumentsAndValidation() async throws {
    let defaultFake = try FakeAdminAppleGateway(mode: "schema")
    let roleFake = try FakeAdminAppleGateway(mode: "schema")
    let emptyFake = try FakeAdminAppleGateway(mode: "empty")
    defer {
      defaultFake.cleanup()
      roleFake.cleanup()
      emptyFake.cleanup()
    }

    let defaultOutput = try await runAdminAddon(
      "riela/apple-gateway-schema",
      config: ["binaryPath": .string(defaultFake.executableURL.path)]
    )
    XCTAssertEqual(try defaultFake.arguments(), ["schema", "print"])
    XCTAssertEqual(adminGatewayObject(defaultOutput)?["role"], .string("default"))
    XCTAssertEqual(adminGatewayObject(defaultOutput)?["schemaSDL"], .string("type Query { viewer: Viewer }"))

    _ = try await runAdminAddon(
      "riela/apple-gateway-schema",
      config: [
        "binaryPath": .string(roleFake.executableURL.path),
        "role": .string("full")
      ],
      inputs: ["role": .string("reader")]
    )
    XCTAssertEqual(try roleFake.arguments(), ["schema", "print", "--role", "reader"])

    try await assertAdminFailure(
      "riela/apple-gateway-schema",
      config: [
        "binaryPath": .string(defaultFake.executableURL.path),
        "role": .string("writer")
      ],
      code: .policyBlocked,
      messageContains: "role must be full or reader"
    )
    try await assertAdminFailure(
      "riela/apple-gateway-schema",
      config: ["binaryPath": .string(emptyFake.executableURL.path)],
      code: .invalidOutput,
      messageContains: "schema stdout was empty"
    )
  }

  func testPermissionsStatusAndRequestArgumentsAndValidation() async throws {
    let statusFake = try FakeAdminAppleGateway(mode: "permissions-status")
    let nonJSONFake = try FakeAdminAppleGateway(mode: "malformed")
    let requestFake = try FakeAdminAppleGateway(mode: "permissions-request")
    defer {
      statusFake.cleanup()
      nonJSONFake.cleanup()
      requestFake.cleanup()
    }

    let statusOutput = try await runAdminAddon(
      "riela/apple-gateway-permissions-status",
      config: ["binaryPath": .string(statusFake.executableURL.path)]
    )
    XCTAssertEqual(try statusFake.arguments(), ["permissions", "status", "--json"])
    let permissions = try XCTUnwrap(adminObject(adminGatewayObject(statusOutput)?["permissions"]))
    XCTAssertEqual(permissions["notes"], .string("authorized"))

    try await assertAdminFailure(
      "riela/apple-gateway-permissions-status",
      config: ["binaryPath": .string(nonJSONFake.executableURL.path)],
      code: .invalidOutput,
      messageContains: "not valid JSON"
    )

    let requestOutput = try await runAdminAddon(
      "riela/apple-gateway-permissions-request",
      config: [
        "binaryPath": .string(requestFake.executableURL.path),
        "domain": .string("notes")
      ]
    )
    XCTAssertEqual(try requestFake.arguments(), ["permissions", "request", "--domain", "notes"])
    XCTAssertEqual(adminGatewayObject(requestOutput)?["domain"], .string("notes"))

    try await assertAdminFailure(
      "riela/apple-gateway-permissions-request",
      config: ["binaryPath": .string(requestFake.executableURL.path)],
      code: .policyBlocked,
      messageContains: "requires domain"
    )
    try await assertAdminFailure(
      "riela/apple-gateway-permissions-request",
      config: [
        "binaryPath": .string(requestFake.executableURL.path),
        "domain": .string("contacts")
      ],
      code: .policyBlocked,
      messageContains: "domain is unsupported"
    )
  }

  func testConfigValidateFileDownloadAndCachePruneArguments() async throws {
    let configFake = try FakeAdminAppleGateway(mode: "config-validate")
    let nonzeroConfigFake = try FakeAdminAppleGateway(mode: "nonzero")
    let fileFake = try FakeAdminAppleGateway(mode: "file-download")
    let cacheFake = try FakeAdminAppleGateway(mode: "cache-prune")
    defer {
      configFake.cleanup()
      nonzeroConfigFake.cleanup()
      fileFake.cleanup()
      cacheFake.cleanup()
    }

    let configOutput = try await runAdminAddon(
      "riela/apple-gateway-config-validate",
      config: [
        "binaryPath": .string(configFake.executableURL.path),
        "configPath": .string("/tmp/gateway-config.json")
      ]
    )
    XCTAssertEqual(try configFake.arguments(), ["config", "validate", "--config", "/tmp/gateway-config.json"])
    XCTAssertEqual(adminGatewayObject(configOutput)?["valid"], .bool(true))

    _ = try await runAdminAddon(
      "riela/apple-gateway-config-validate",
      config: ["binaryPath": .string(configFake.executableURL.path)]
    )
    XCTAssertEqual(try configFake.arguments(), ["config", "validate"])

    try await assertAdminFailure(
      "riela/apple-gateway-config-validate",
      config: [
        "binaryPath": .string(nonzeroConfigFake.executableURL.path),
        "configPath": .string("/tmp/bad-config.json")
      ],
      code: .providerError,
      messageContains: "upstream denied"
    )

    let fileOutput = try await runAdminAddon(
      "riela/apple-gateway-file-download",
      config: [
        "binaryPath": .string(fileFake.executableURL.path),
        "keys": .array([.string("k1"), .string("k2")]),
        "outputDir": .string("/tmp/apple-gateway-downloads")
      ]
    )
    XCTAssertEqual(try fileFake.arguments(), [
      "file",
      "download",
      "--key",
      "k1",
      "--key",
      "k2",
      "--output-dir",
      "/tmp/apple-gateway-downloads"
    ])
    XCTAssertEqual(adminGatewayObject(fileOutput)?["keys"], .array([.string("k1"), .string("k2")]))

    _ = try await runAdminAddon(
      "riela/apple-gateway-file-download",
      config: [
        "binaryPath": .string(fileFake.executableURL.path),
        "keys": .array([.string("single")])
      ]
    )
    XCTAssertEqual(try fileFake.arguments(), ["file", "download", "--key", "single"])

    try await assertAdminFailure(
      "riela/apple-gateway-file-download",
      config: ["binaryPath": .string(fileFake.executableURL.path), "keys": .array([])],
      code: .policyBlocked,
      messageContains: "requires at least one key"
    )

    let cacheOutput = try await runAdminAddon(
      "riela/apple-gateway-cache-prune",
      config: [
        "binaryPath": .string(cacheFake.executableURL.path),
        "all": .bool(true)
      ]
    )
    XCTAssertEqual(try cacheFake.arguments(), ["cache", "prune", "--all"])
    XCTAssertEqual(adminGatewayObject(cacheOutput)?["all"], .bool(true))

    _ = try await runAdminAddon(
      "riela/apple-gateway-cache-prune",
      config: ["binaryPath": .string(cacheFake.executableURL.path)]
    )
    XCTAssertEqual(try cacheFake.arguments(), ["cache", "prune"])
  }

  private func runAdminAddon(
    _ name: String,
    version: String = "1",
    config: JSONObject = [:],
    inputs: JSONObject = [:],
    environment: [String: String] = [:],
    variables: JSONObject = [:],
    resolvedInputPayload: JSONObject = [:],
    addonEnv: JSONObject? = nil,
    context: AdapterExecutionContext = AdapterExecutionContext()
  ) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(environment: environment).execute(
      WorkflowAddonExecutionInput(
        workflowId: "apple-gateway-admin",
        stepId: "admin-step",
        nodeId: "admin-step",
        addon: WorkflowNodeAddonRef(
          name: name,
          version: version,
          config: config,
          env: addonEnv,
          inputs: inputs
        ),
        variables: variables,
        resolvedInputPayload: resolvedInputPayload
      ),
      context: context
    )
  }

  private func assertAdminFailure(
    _ name: String,
    version: String = "1",
    config: JSONObject = [:],
    inputs: JSONObject = [:],
    addonEnv: JSONObject? = nil,
    context: AdapterExecutionContext = AdapterExecutionContext(),
    code: AdapterExecutionErrorCode,
    messageContains: String
  ) async throws {
    do {
      _ = try await runAdminAddon(
        name,
        version: version,
        config: config,
        inputs: inputs,
        addonEnv: addonEnv,
        context: context
      )
      XCTFail("expected apple gateway admin add-on to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, code)
      XCTAssertTrue(error.message.contains(messageContains), error.message)
    }
  }
}

private struct FakeAdminAppleGateway {
  var rootURL: URL
  var binURL: URL
  var executableURL: URL
  var argumentLogURL: URL
  var environmentLogURL: URL

  init(mode: String, executableName: String = "fake-apple-gateway") throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-apple-gateway-admin-\(UUID().uuidString)", isDirectory: true)
    binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
    executableURL = binURL.appendingPathComponent(executableName)
    argumentLogURL = rootURL.appendingPathComponent("args.log")
    environmentLogURL = rootURL.appendingPathComponent("environment.log")
    try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
    try script(mode: mode).write(to: executableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: rootURL)
  }

  func arguments() throws -> [String] {
    try String(contentsOf: argumentLogURL)
      .split(whereSeparator: \.isNewline)
      .map(String.init)
  }

  private func script(mode: String) -> String {
    """
    #!/bin/sh
    printf '%s\\n' "$@" > "\(argumentLogURL.path)"
    {
      printf "OPENAI_API_KEY=%s\\n" "${OPENAI_API_KEY:-}"
      printf "GITHUB_TOKEN=%s\\n" "${GITHUB_TOKEN:-}"
      printf "RIELA_SECRET=%s\\n" "${RIELA_SECRET:-}"
      printf "PATH=%s\\n" "${PATH:-}"
      printf "USER=%s\\n" "${USER:-}"
    } > "\(environmentLogURL.path)"
    case "\(mode)" in
      graphql-success)
        printf '{"data":{"viewer":{"id":"viewer-1"}},"extensions":{"requestId":"req-admin","trace":"ok"}}\\n'
        ;;
      graphql-error)
        printf '{"data":null,"errors":[{"message":"permission denied"}],"extensions":{"requestId":"req-error"}}\\n'
        ;;
      schema)
        printf 'type Query { viewer: Viewer }\\n'
        ;;
      permissions-status)
        printf '{"notes":"authorized","calendar":"notDetermined"}\\n'
        ;;
      permissions-request)
        printf '{"domain":"notes","requested":true}\\n'
        ;;
      config-validate)
        printf 'config ok\\n'
        ;;
      file-download)
        printf '{"files":[{"key":"k1","path":"/tmp/k1"},{"key":"k2","path":"/tmp/k2"}]}\\n'
        ;;
      cache-prune)
        printf '{"pruned":true}\\n'
        ;;
      malformed)
        printf 'not-json\\n'
        ;;
      empty)
        printf ''
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

private func adminGatewayObject(_ output: AdapterExecutionOutput) -> JSONObject? {
  adminObject(output.payload["appleGateway"])
}

private func adminGatewayBinarySource(_ output: AdapterExecutionOutput) -> String? {
  adminGatewayObject(output)
    .flatMap { adminObject($0["binary"]) }
    .flatMap { adminString($0["source"]) }
}

private func adminObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object)? = value else {
    return nil
  }
  return object
}

private func adminString(_ value: JSONValue?) -> String? {
  guard case let .string(string)? = value else {
    return nil
  }
  return string
}
