import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

final class BuiltinContainerGatewayAddonTests: XCTestCase {
  func testLiveAppleContainerDispatchesReaderWithExplicitMount() async throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(environment["RIELA_TEST_LIVE_CONTAINER"] == "1", "opt-in real container integration")
    let root = try makeRielaCLITestTemporaryDirectory("builtin-gateway-live")
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = root.appendingPathComponent("x-gateway-reader")
    let guardPath = try XCTUnwrap(environment["RIELA_TEST_GATEWAY_GUARD"], "path to Linux guard compiled from containers/gateway-support/guard.c")
    try FileManager.default.copyItem(atPath: guardPath, toPath: root.appendingPathComponent("riela-gateway-guard").path)
    try """
    #!/bin/sh
    set -eu
    [ "$1" = graphql ]
    [ "$2" = query ]
    [ "$3" = 'query { posts(limit: 3) }' ]
    [ "$4" = --json ]
    [ "$X_GW_ACCESS_TOKEN" = explicitly-bound ]
    [ -z "${UNRELATED_SECRET:-}" ]
    printf '%s\\n' '{"ok":true,"data":{"data":{"posts":[]}}}'
    """.write(to: reader, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: reader.path)
    var selectedEnvironment = environment
    selectedEnvironment["RIELA_CONTAINER_RUNTIME"] = "container"
    selectedEnvironment["SOURCE_TOKEN"] = "explicitly-bound"
    selectedEnvironment["UNRELATED_SECRET"] = "must-not-forward"
    let output = try await BuiltinWorkflowAddonResolver(environment: selectedEnvironment, workingDirectory: root).execute(
      input(.xRead, env: ["X_GW_ACCESS_TOKEN": .object(["fromEnv": .string("SOURCE_TOKEN")])], extraConfig: [
        "image": .string(ContainerGatewayAddon.xRead.defaultImage), "networkPolicy": .string("denied"),
        "mounts": .array([.object(["source": .string(root.path), "target": .string("/usr/local/bin")])])
      ]), context: AdapterExecutionContext(deadline: Date().addingTimeInterval(120)))
    XCTAssertEqual(output.provider, "container-addon")
    XCTAssertNotNil(output.payload["xGateway"])
  }

  func testGatewaysInvokePinnedReadersAndBindOnlyExplicitEnvironment() async throws {
    for gateway in [ContainerGatewayAddon.xRead, .gmailRead] {
      let runner = GatewayContainerRecordingRunner(result: .init(
        stdout: #"{"ok":true,"data":{"data":{"posts":[]}}}"#, stderr: "", terminationStatus: 0
      ))
      let output = try await BuiltinWorkflowAddonResolver(
        environment: ["RIELA_CONTAINER_RUNTIME": "/usr/local/bin/container", "SOURCE_TOKEN": "secret", "UNRELATED": "private"],
        containerProcessRunner: runner
      ).execute(input(gateway, env: ["X_GW_ACCESS_TOKEN": .object(["fromEnv": .string("SOURCE_TOKEN")])]),
        context: AdapterExecutionContext())
      let calls = await runner.calls
      let call = try XCTUnwrap(calls.dropFirst().first)
      XCTAssertEqual(calls.count, 3)
      XCTAssertEqual(calls.first?.arguments.first, "run")
      XCTAssertEqual(calls.last?.arguments.prefix(2), ["delete", "--force"])
      XCTAssertNil(calls.first?.environment["X_GW_ACCESS_TOKEN"])
      XCTAssertNil(calls.last?.environment["X_GW_ACCESS_TOKEN"])
      XCTAssertEqual(call.executableURL.path, "/usr/local/bin/container")
      XCTAssertFalse(call.arguments.contains("X_GW_ACCESS_TOKEN"))
      XCTAssertFalse(call.arguments.contains { $0.contains("secret") || $0.contains("private") })
      XCTAssertNil(call.environment["X_GW_ACCESS_TOKEN"])
      XCTAssertNil(call.environment["SOURCE_TOKEN"])
      XCTAssertNil(call.environment["UNRELATED"])
      XCTAssertFalse(call.inheritEnvironment)
      XCTAssertFalse(call.arguments.contains("--log-driver"))
      XCTAssertFalse(call.arguments.contains("UNRELATED=private"))
      XCTAssertTrue(calls[0].arguments.contains("--read-only"))
      XCTAssertTrue(call.arguments.contains("/usr/local/bin/riela-gateway-guard"))
      XCTAssertTrue(call.arguments.contains(gateway.entrypoint))
      XCTAssertEqual(Array(call.arguments.suffix(gateway.arguments(document: "query { posts(limit: 3) }").count)),
        gateway.arguments(document: "query { posts(limit: 3) }"))
      XCTAssertEqual(output.provider, "container-addon")
      guard case let .object(payload)? = output.payload[gateway.namespace] else { return XCTFail("missing gateway response") }
      XCTAssertNotNil(payload["data"])
      if gateway == .xRead {
        XCTAssertEqual(payload["data"], .object(["data": .object(["posts": .array([])])]))
      }
    }
  }

  func testDockerAndPodmanUseExplicitRuntimeAndNetworkDenial() async throws {
    for executable in ["docker", "podman"] {
      let runner = GatewayContainerRecordingRunner(result: .init(stdout: #"{"data":{}}"#, stderr: "", terminationStatus: 0))
      let executor = ContainerGatewayAddonExecutor(environment: [:], workingDirectory: URL(fileURLWithPath: "/tmp"), runner: runner)
      _ = try await executor.execute(input(.xRead, extraConfig: [
        "runnerKind": .string(executable), "networkPolicy": .string("denied")
      ]), gateway: .xRead, context: AdapterExecutionContext())
      let calls = await runner.calls
      let call = try XCTUnwrap(calls.first)
      XCTAssertEqual(call.arguments.first, executable)
      XCTAssertTrue(call.arguments.contains("none"))
      let logFlag = try XCTUnwrap(call.arguments.firstIndex(of: "--log-driver"))
      XCTAssertEqual(call.arguments[logFlag + 1], "none")
    }
  }

  func testGatewayEnvironmentPreservesRuntimeConnectionAndResolvedBindingsAcrossDrivers() async throws {
    for runtime in ["docker", "podman", "/custom/runtime"] {
      let runner = GatewayContainerRecordingRunner(result: .init(stdout: #"{"data":{}}"#, stderr: "", terminationStatus: 0))
      let executor = ContainerGatewayAddonExecutor(environment: [
        "RIELA_CONTAINER_RUNTIME": runtime, "SOURCE": "private\ncredential=value", "X_GW_ACCESS_TOKEN": "wrong-host-value",
        "DOCKER_HOST": "unix:///runtime/socket", "HOME": "/runtime/home", "UNRELATED_SECRET": "unrelated"
      ], workingDirectory: URL(fileURLWithPath: "/tmp"), runner: runner)
      _ = try await executor.execute(input(.gmailRead, env: ["X_GW_ACCESS_TOKEN": .object(["fromEnv": .string("SOURCE")])]),
        gateway: .gmailRead, context: AdapterExecutionContext())
      let calls = await runner.calls
      let call = try XCTUnwrap(calls.first)
      XCTAssertEqual(call.environment["X_GW_ACCESS_TOKEN"], "private\ncredential=value")
      XCTAssertEqual(call.environment["DOCKER_HOST"], "unix:///runtime/socket")
      XCTAssertEqual(call.environment["HOME"], "/runtime/home")
      XCTAssertNil(call.environment["UNRELATED_SECRET"])
      XCTAssertNil(call.environment["SOURCE"])
      XCTAssertTrue(call.arguments.contains("X_GW_ACCESS_TOKEN"))
      XCTAssertFalse(call.arguments.contains { $0.contains("private") || $0.contains("wrong-host-value") })
      XCTAssertEqual(call.arguments.contains("--log-driver"), runtime != "/custom/runtime")
    }
  }

  func testSharedDriverRetainsInlineEnvironmentForLaunchersWithoutProcessBindings() {
    let options = ContainerRuntimeRunOptions(environment: ["X_GW_ACCESS_TOKEN": "fixture"], mounts: [], entrypoint: nil,
      workingDirectory: nil, networkAllowed: true, readOnlyRootFilesystem: true)
    let arguments = DockerContainerDriver(executable: "docker").runArguments(image: "fixture", options: options)
    XCTAssertTrue(arguments.contains("X_GW_ACCESS_TOKEN=fixture"))
    XCTAssertFalse(arguments.contains("--log-driver"))
  }

  func testHostControlAndMalformedEnvironmentTargetsNeverLaunch() async throws {
    for name in ["PATH", "HOME", "DOCKER_HOST", "LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "BASH_ENV", "PYTHONPATH",
                 "X_GW_TOKEN=value", "X_GW_TOKEN\n", "X_GW_TOKEN\0", "GMAIL_GATEWAY_token", "X_GW_"] {
      let runner = GatewayContainerRecordingRunner(result: .init(stdout: #"{"data":{}}"#, stderr: "", terminationStatus: 0))
      let executor = ContainerGatewayAddonExecutor(environment: ["RIELA_CONTAINER_RUNTIME": "docker", "SOURCE": "fixture"],
        workingDirectory: URL(fileURLWithPath: "/tmp"), runner: runner)
      do {
        _ = try await executor.execute(input(.xRead, env: [name: .object(["fromEnv": .string("SOURCE")])]),
          gateway: .xRead, context: AdapterExecutionContext())
        XCTFail("expected blocked host control or malformed target")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .policyBlocked)
      }
      let count = await runner.calls.count
      XCTAssertEqual(count, 0)
    }
  }

  func testInvalidConfigurationDoesNotLaunch() async throws {
    let cases: [JSONObject] = [
      ["queryTemplate": .null], ["runnerKind": .string("bogus")],
      ["networkPolicy": .string("bogus")], ["mounts": .string("/private")],
      ["mounts": .array([.object(["source": .string("/"), "target": .string("/host")])])]
    ]
    for config in cases {
      let runner = GatewayContainerRecordingRunner(result: .init(stdout: "{}", stderr: "", terminationStatus: 0))
      let executor = ContainerGatewayAddonExecutor(environment: ["RIELA_CONTAINER_RUNTIME": "docker"],
        workingDirectory: URL(fileURLWithPath: "/tmp"), runner: runner)
      do {
        _ = try await executor.execute(input(.xRead, extraConfig: config), gateway: .xRead, context: AdapterExecutionContext())
        XCTFail("expected invalid configuration")
      } catch is AdapterExecutionError {}
      let count = await runner.calls.count
      XCTAssertEqual(count, 0)
    }
  }

  func testFailedAndMalformedGatewayResponsesNeverSucceed() async throws {
    let results: [LocalProcessResult] = [
      .init(stdout: "{}", stderr: "secret-provider-token", terminationStatus: 1),
      .init(stdout: "not JSON", stderr: "", terminationStatus: 0),
      .init(stdout: "{}\n{}", stderr: "", terminationStatus: 0),
      .init(stdout: "{}", stderr: "", terminationStatus: 0),
      .init(stdout: #"{"ok":false,"error":{}}"#, stderr: "", terminationStatus: 0),
      .init(stdout: #"{"status":"error"}"#, stderr: "", terminationStatus: 0),
      .init(stdout: #"{"data":{"errors":[{"message":"denied"}]}}"#, stderr: "", terminationStatus: 0)
    ]
    for result in results {
      let runner = GatewayContainerRecordingRunner(result: result)
      do {
        _ = try await ContainerGatewayAddonExecutor(environment: ["RIELA_CONTAINER_RUNTIME": "docker"],
          workingDirectory: URL(fileURLWithPath: "/tmp"), runner: runner
        ).execute(input(.xRead), gateway: .xRead, context: AdapterExecutionContext())
        XCTFail("expected gateway failure")
      } catch let error as AdapterExecutionError {
        XCTAssertFalse(error.message.contains("secret-provider-token"))
      }
    }
  }

  func testProviderFailureRetainsOnlyFiniteDiagnostics() async throws {
    let failure = #"{"ok":false,"error":{"code":"AUTH_INVALID","classification":"auth","httpStatus":401,"details":"secret-provider-token","traceId":"private-id","summary":"private-post"}}"#
    for result in [LocalProcessResult(stdout: "", stderr: failure, terminationStatus: 4),
                   LocalProcessResult(stdout: failure, stderr: "", terminationStatus: 0)] {
      let runner = GatewayContainerRecordingRunner(result: result)
      do {
        _ = try await ContainerGatewayAddonExecutor(environment: ["RIELA_CONTAINER_RUNTIME": "docker"],
          workingDirectory: URL(fileURLWithPath: "/tmp"), runner: runner
        ).execute(input(.xRead), gateway: .xRead, context: AdapterExecutionContext())
        XCTFail("expected gateway failure")
      } catch let error as AdapterExecutionError {
        XCTAssertTrue(error.message.contains("code=AUTH_INVALID, classification=auth, httpStatus=401"))
        for privateValue in ["secret-provider-token", "private-id", "private-post"] {
          XCTAssertFalse(error.message.contains(privateValue))
        }
      }
    }
    XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: #"{"error":{"code":"secret-code","classification":"auth","httpStatus":401}}"#), "")
    XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: #"{"error":{"code":"AUTH_INVALID","classification":"secret-class","httpStatus":"secret-status"}}"#), " (code=AUTH_INVALID)")
    XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: #"{"error":{"code":"AUTH_INVALID","httpStatus":900}}"#), " (code=AUTH_INVALID)")
    XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: failure + String(repeating: " ", count: 65_537)), "")
    XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: "prefix " + failure), "")
  }

  func testProviderProblemDiagnosticsRejectArbitraryTextURLsAndNonintegerCodes() {
    let safe = #"""
    {"error":{"code":"PERMISSION_DENIED","httpStatus":403,"providerProblem":"client-forbidden",
      "providerReason":"client-not-enrolled","providerErrorCode":453,"details":"secret-token",
      "message":"private-post","resource_id":"private-id"}}
    """#
    XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: safe),
      " (code=PERMISSION_DENIED, httpStatus=403, providerProblem=client-forbidden, providerReason=client-not-enrolled, providerErrorCode=453)")
    for value in [#""https://api.x.com/2/problems/client-forbidden?secret""#, #""secret-token""#] {
      let unsafe = "{\"error\":{\"code\":\"PERMISSION_DENIED\",\"providerProblem\":\(value),\"providerReason\":\(value)}}"
      XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: unsafe), " (code=PERMISSION_DENIED)")
    }
    for value in ["true", "-1", "100000", "1.5", #""453""#] {
      let unsafe = "{\"error\":{\"code\":\"PERMISSION_DENIED\",\"providerErrorCode\":\(value)}}"
      XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: unsafe), " (code=PERMISSION_DENIED)")
    }
  }

  func testGmailFailureCodesCrossBoundaryWithoutProviderDetails() {
    for code in ["UNEXPECTED_ERROR", "AUTH_REQUIRED", "PROVIDER_API_ERROR", "PROVIDER_RATE_LIMITED", "CONFIG_INVALID"] {
      let failure = "{\"error\":{\"code\":\"\(code)\",\"message\":\"secret-token\",\"details\":{\"accountId\":\"private-id\"}}}"
      XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: "", stderr: failure), " (code=\(code))")
    }
  }

  func testGmailGraphQLAndCLIEnvelopesPreserveOnlyBoundedNumbers() {
    let graphql = #"{"data":null,"errors":[{"code":"PROVIDER_API_ERROR","message":"secret-token","path":["private-id"],"httpStatus":403,"providerErrorCode":403}]}"#
    XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: graphql),
      " (code=PROVIDER_API_ERROR, httpStatus=403, providerErrorCode=403)")
    let typed = #"{"errors":[{"code":"PROVIDER_API_ERROR","extensions":{"httpStatus":403,"providerErrorCode":403,"token":"secret-token"}}]}"#
    XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: typed),
      " (code=PROVIDER_API_ERROR, httpStatus=403, providerErrorCode=403)")
    let cli = #"{"error":{"code":"PROVIDER_API_ERROR","details":{"httpStatus":"403","providerErrorCode":"403","token":"secret-token"}}}"#
    XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: "", stderr: cli),
      " (code=PROVIDER_API_ERROR, httpStatus=403, providerErrorCode=403)")
    for invalid in ["-1", "100000", "1.5", " 403", "+403", "403secret", "", "１２３"] {
      let value = "{\"errors\":[{\"code\":\"PROVIDER_API_ERROR\",\"details\":{\"httpStatus\":\"\(invalid)\",\"providerErrorCode\":\"\(invalid)\"}}]}"
      XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: value), " (code=PROVIDER_API_ERROR)")
    }
  }

  func testClosedGmailBodyAndTransportReasonsCrossContainerBoundary() throws {
    let body = ["messageEnvelope", "bodyDescriptor", "externalBodyDescriptor", "externalBodyResponse",
      "treeLimit", "filename", "mimeType", "partIdentity", "children", "missingData", "decodedSize",
      "headers", "duplicateContentType", "headerValue", "mimeMismatch", "duplicateCharset", "charsetQuotes", "charsetValue", "invalidBase64"]
    let transport = ["timeout", "missingResponse", "cancelled", "dns", "connect", "connectionLost", "tls", "offline", "transport"]
    for (field, prefix, reasons) in [("gmailBodyReason", "Invalid message body response", body),
                                    ("gmailReadReason", "Bounded Gmail read failed", transport)] {
      for reason in reasons {
        let failure = "{\"errors\":[{\"code\":\"PROVIDER_API_ERROR\",\"message\":\"\(prefix) [\(field)=\(reason)]\",\"details\":{\"body\":\"PRIVATE_BODY\",\"accountId\":\"PRIVATE_ID\"}}]}"
        XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: failure),
          " (code=PROVIDER_API_ERROR, \(field)=\(reason))")
        XCTAssertFalse(GatewayFailureDiagnostics.suffix(stdout: failure).contains("PRIVATE"))
      }
      for message in ["\(prefix) [\(field)=PRIVATE_BODY]", "PRIVATE_BODY \(prefix) [\(field)=timeout]",
                      "\(prefix) [\(field)=timeout] PRIVATE_BODY", "\(prefix) [\(field)=timeout]\nPRIVATE_BODY"] {
        let error: JSONObject = ["code": .string("PROVIDER_API_ERROR"), "message": .string(message)]
        let data = try JSONEncoder().encode(["error": JSONValue.object(error)])
        XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: try XCTUnwrap(String(data: data, encoding: .utf8))), " (code=PROVIDER_API_ERROR)")
      }
    }
    let wrongCode = #"{"error":{"code":"AUTH_INVALID","message":"Invalid message body response [gmailBodyReason=headerValue]"}}"#
    XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: wrongCode), " (code=AUTH_INVALID)")
    let privateMessage = #"{"error":{"code":"PROVIDER_API_ERROR","message":"PRIVATE_BODY","details":{"gmailBodyReason":"headerValue"}}}"#
    XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: privateMessage), " (code=PROVIDER_API_ERROR)")
  }

  func testGmailDecodedSizeDiagnosticsRetainOnlyCanonicalBoundedCounts() throws {
    func suffix(_ message: String) throws -> String {
      let value: JSONObject = ["error": .object(["code": .string("PROVIDER_API_ERROR"), "message": .string(message)])]
      return GatewayFailureDiagnostics.suffix(stdout: try XCTUnwrap(String(data: JSONEncoder().encode(value), encoding: .utf8)))
    }
    for (declared, decoded) in [(0, 1), (8_388_608, 0), (123, 124)] {
      XCTAssertEqual(try suffix("Invalid message body response [gmailBodyReason=decodedSize declaredByteCount=\(declared) decodedByteCount=\(decoded)]"),
        " (code=PROVIDER_API_ERROR, gmailBodyReason=decodedSize, gmailDeclaredByteCount=\(declared), gmailDecodedByteCount=\(decoded))")
    }
    for number in ["", "-1", "+1", "01", "8388609", "99999999", "1.0", "1 PRIVATE_BODY", " 1", "1\n"] {
      for message in ["Invalid message body response [gmailBodyReason=decodedSize declaredByteCount=\(number) decodedByteCount=1]",
                      "Invalid message body response [gmailBodyReason=decodedSize declaredByteCount=1 decodedByteCount=\(number)]"] {
        XCTAssertEqual(try suffix(message), " (code=PROVIDER_API_ERROR)")
      }
    }
    for message in ["Invalid message body response [gmailBodyReason=decodedSize declaredByteCount=1]",
                    "Invalid message body response [gmailBodyReason=PRIVATE_BODY declaredByteCount=1 decodedByteCount=2]",
                    "Invalid message body response [gmailBodyReason=decodedSize declaredByteCount=1 decodedByteCount=2] PRIVATE_BODY"] {
      XCTAssertEqual(try suffix(message), " (code=PROVIDER_API_ERROR)")
    }
  }

  private func input(_ gateway: ContainerGatewayAddon, env: JSONObject? = nil, extraConfig: JSONObject = [:]) -> WorkflowAddonExecutionInput {
    var config: JSONObject = ["queryTemplate": .string("query { posts(limit: {{limit}}) }")]
    config.merge(extraConfig) { _, new in new }
    return WorkflowAddonExecutionInput(workflowId: "test", stepId: "fetch", nodeId: "fetch",
      addon: WorkflowNodeAddonRef(name: gateway.rawValue, version: "1", config: config, env: env), variables: ["limit": .integer(3)])
  }
}

private actor GatewayContainerRecordingRunner: LocalProcessRunning {
  var calls: [LocalProcessConfiguration] = []
  let result: LocalProcessResult

  init(result: LocalProcessResult) { self.result = result }

  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    calls.append(configuration)
    return result
  }
}
