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
    try """
    #!/bin/sh
    set -eu
    [ "$1" = graphql ]
    [ "$2" = query ]
    [ "$3" = 'query { posts(limit: 3) }' ]
    [ "$4" = --json ]
    [ "$TOKEN" = explicitly-bound ]
    [ -z "${UNRELATED_SECRET:-}" ]
    printf '%s\\n' '{"ok":true,"data":{"data":{"posts":[]}}}'
    """.write(to: reader, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: reader.path)
    var selectedEnvironment = environment
    selectedEnvironment["RIELA_CONTAINER_RUNTIME"] = "container"
    selectedEnvironment["SOURCE_TOKEN"] = "explicitly-bound"
    selectedEnvironment["UNRELATED_SECRET"] = "must-not-forward"
    let output = try await BuiltinWorkflowAddonResolver(environment: selectedEnvironment, workingDirectory: root).execute(
      input(.xRead, env: ["TOKEN": .object(["fromEnv": .string("SOURCE_TOKEN")])], extraConfig: [
        "image": .string("swift:6.2-noble"), "networkPolicy": .string("denied"),
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
      ).execute(input(gateway, env: ["TOKEN": .object(["fromEnv": .string("SOURCE_TOKEN")])]),
        context: AdapterExecutionContext())
      let calls = await runner.calls
      let call = try XCTUnwrap(calls.first)
      XCTAssertEqual(calls.count, 1)
      XCTAssertEqual(call.executableURL.path, "/usr/local/bin/container")
      XCTAssertTrue(call.arguments.contains("TOKEN=secret"))
      XCTAssertFalse(call.arguments.contains("UNRELATED=private"))
      XCTAssertTrue(call.arguments.contains("--read-only"))
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
