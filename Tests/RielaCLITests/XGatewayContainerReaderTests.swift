import Foundation
import RielaAdapters
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

/// Container X reader parity with the embedded reader: caches, retry/timeout
/// transport flags and the credential-only environment allowlist.
final class XGatewayContainerReaderTests: XCTestCase {
  private static let usage = #"{"version":1,"basis":"upstream-response","billingStatus":"not-reported","httpResponses":1,"#
    + #""successfulResponses":1,"unclassifiedResources":0,"resources":[{"kind":"post","#
    + #""idHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","utcDay":"2026-10-24"}]}"#

  func testUsageAndUserCachesRunThroughTheContainerReader() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("x-container-caches")
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheRoot = root.appendingPathComponent("cache").path
    _ = try XGatewayUserCacheExchange(environment: ["RIELA_CACHE_ROOT": cacheRoot]).consume(
      #"{"ok":true,"data":{"data":{},"extensions":{"userMemory":[{"id":"7","username":"user_7"}]}}}"#)
    let runner = XGatewayContainerRecordingRunner(result: .init(stdout:
      #"{"ok":true,"data":{"data":{"posts":[{"id":"1","author":{"id":"8"}}]},"extensions":{"userMemory":[{"id":"8","username":"bob"}],"resourceUsage":"#
      + Self.usage + "}}}", stderr: "", terminationStatus: 0))
    let executor = ContainerGatewayAddonExecutor(environment: [
      "RIELA_CONTAINER_RUNTIME": "docker", "RIELA_CACHE_ROOT": cacheRoot, "SOURCE": "token-canary"
    ], workingDirectory: root, runner: runner)
    let output = try await executor.execute(input(env: ["X_GW_TOKEN": .object(["fromEnv": .string("SOURCE")])],
      config: ["userCache": .bool(true), "usageCache": .bool(true)]), gateway: .xRead,
      context: .init(deadline: Date().addingTimeInterval(60)))
    let calls = await runner.calls
    let call = try XCTUnwrap(calls.first)
    XCTAssertEqual(call.environment["X_GW_USER_MEMORY_PARTS"], "1")
    XCTAssertTrue(try XCTUnwrap(call.environment["X_GW_USER_MEMORY_JSON_0"]).contains("user_7"))
    XCTAssertEqual(call.environment["X_GW_TOKEN"], "token-canary")
    let retry = try XCTUnwrap(call.arguments.firstIndex(of: "--retry"))
    XCTAssertEqual(call.arguments[retry + 1], "0")
    let timeout = try XCTUnwrap(call.arguments.firstIndex(of: "--timeout-ms"))
    XCTAssertLessThanOrEqual(try XCTUnwrap(Int(call.arguments[timeout + 1])), XGatewayReaderSDK.maximumRequestTimeoutMilliseconds)

    guard case let .object(namespace)? = output.payload["xGateway"],
          case let .object(runtime)? = namespace["runtime"] else { return XCTFail("missing reader payload") }
    XCTAssertEqual(runtime["usageCacheStatus"], .string("stored"))
    XCTAssertEqual(runtime["userCacheStatus"], .string("ok"))
    XCTAssertFalse(try JSONValue.object(output.payload).compactJSONString().contains("userMemory"))
    let users = XGatewayUserCacheExchange(environment: ["RIELA_CACHE_ROOT": cacheRoot])
    XCTAssertEqual(Set(try users.store.keys(cacheId: XGatewayUserCacheExchange.cacheId,
      scope: XGatewayUserCacheExchange.scope)), ["7", "8"])
    let usage = try XGatewayUsageCacheExchange(scope: nil, environment: ["RIELA_CACHE_ROOT": cacheRoot])
    XCTAssertEqual(try usage.store.keys(cacheId: XGatewayUsageCacheExchange.cacheId,
      scope: XGatewayUsageCacheExchange.scope).count, 1)
  }

  func testFailedContainerReadStillRecordsUsageAndUnsupportedImageKeepsData() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("x-container-usage-failure")
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = ["RIELA_CONTAINER_RUNTIME": "docker", "RIELA_CACHE_ROOT": root.path, "SOURCE": "token"]
    let failure = #"{"ok":false,"error":{"code":"RATE_LIMITED","httpStatus":429,"resourceUsage":"# + Self.usage + "}}"
    do {
      _ = try await ContainerGatewayAddonExecutor(environment: environment, workingDirectory: root,
        runner: XGatewayContainerRecordingRunner(result: .init(stdout: "", stderr: failure, terminationStatus: 4)))
        .execute(input(env: ["X_GW_TOKEN": .object(["fromEnv": .string("SOURCE")])], config: ["usageCache": .bool(true)]),
          gateway: .xRead, context: .init())
      XCTFail("expected provider failure")
    } catch let error as AdapterExecutionError {
      XCTAssertTrue(error.message.contains("usageCacheStatus=stored"))
      XCTAssertTrue(error.message.contains("code=RATE_LIMITED, httpStatus=429"))
    }
    let output = try await ContainerGatewayAddonExecutor(environment: environment, workingDirectory: root,
      runner: XGatewayContainerRecordingRunner(result: .init(stdout: #"{"ok":true,"data":{"data":{"posts":[]}}}"#,
        stderr: "", terminationStatus: 0)))
      .execute(input(config: ["userCache": .bool(true)]), gateway: .xRead, context: .init())
    guard case let .object(namespace)? = output.payload["xGateway"], case let .object(runtime)? = namespace["runtime"],
          case let .object(data)? = namespace["data"] else { return XCTFail("missing reader payload") }
    XCTAssertEqual(runtime["userCacheStatus"], .string("unsupported"))
    XCTAssertEqual(data["data"], .object(["posts": .array([])]))
  }

  func testContainerXReaderAcceptsOnlyEmbeddedCredentialTargets() async throws {
    for name in ["X_GW_RETRY", "X_GW_TIMEOUT_MS", "X_GW_MEDIA_ROOT_DIR", "X_GW_OUTPUT", "X_GW_USER_MEMORY_PARTS",
                 "GMAIL_GATEWAY_CONFIG"] {
      let runner = XGatewayContainerRecordingRunner(result: .init(stdout: #"{"data":{}}"#, stderr: "", terminationStatus: 0))
      do {
        _ = try await ContainerGatewayAddonExecutor(environment: ["RIELA_CONTAINER_RUNTIME": "docker", "SOURCE": "1"],
          workingDirectory: URL(fileURLWithPath: "/tmp"), runner: runner)
          .execute(input(env: [name: .object(["fromEnv": .string("SOURCE")])]), gateway: .xRead, context: .init())
        XCTFail("\(name) must not be bindable for the X reader")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .policyBlocked)
      }
      let count = await runner.calls.count
      XCTAssertEqual(count, 0)
    }
    for name in xGatewayReaderCredentialEnvironment {
      XCTAssertTrue(ContainerGatewayAddon.xRead.allowsEnvironmentTarget(name))
    }
    XCTAssertTrue(ContainerGatewayAddon.gmailRead.allowsEnvironmentTarget("GMAIL_GATEWAY_CONFIG"))
  }

  private func input(env: JSONObject? = nil, config: JSONObject = [:]) -> WorkflowAddonExecutionInput {
    WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: ContainerGatewayAddon.xRead.rawValue, version: "1",
        config: ["queryTemplate": .string("query { posts(limit: 3) { id } }")].merging(config) { _, new in new },
        env: env))
  }
}

private actor XGatewayContainerRecordingRunner: LocalProcessRunning {
  var calls: [LocalProcessConfiguration] = []
  let result: LocalProcessResult

  init(result: LocalProcessResult) { self.result = result }

  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    calls.append(configuration)
    return result
  }
}
