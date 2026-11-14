import Foundation
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

/// Drives the embedded X reader through the real descriptor `run` path (no
/// `localGatewayGraphQLRunner`), replacing only the linked SDK call.
final class XGatewayEmbeddedReaderRuntimeTests: XCTestCase {
  private static let usage = #"{"version":1,"basis":"upstream-response","billingStatus":"not-reported","httpResponses":2,"#
    + #""successfulResponses":2,"unclassifiedResources":0,"resources":["#
    + #"{"kind":"post","idHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","utcDay":"2026-10-24"},"#
    + #"{"kind":"user","idHash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","utcDay":"2026-10-24"}]}"#

  func testRealRunPathBindsCredentialsStripsUserMemoryAndStoresUsage() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("x-embedded-run-path")
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheRoot = root.appendingPathComponent("cache").path
    _ = try XGatewayUserCacheExchange(environment: ["RIELA_CACHE_ROOT": cacheRoot]).consume(
      #"{"ok":true,"data":{"data":{},"extensions":{"userMemory":[{"id":"7","username":"user_7","name":"Seven"}]}}}"#)
    let stub = XGatewaySDKStub(stdout: #"{"ok":true,"data":{"data":{"homeTimeline":{"posts":[{"id":"1","author":{"id":"8","username":"bob"}}]}},"#
      + #""extensions":{"userMemory":[{"id":"8","username":"bob","name":"Bob"}],"resourceUsage":"# + Self.usage + "}}}")
    let output = try await XGatewayReaderSDK.$invocationOverride.withValue(stub.invocation) {
      try await BuiltinWorkflowAddonResolver(environment: [
        "SYNTHETIC_X_TOKEN": "token-canary", "UNRELATED_PRIVATE": "must-not-forward", "RIELA_CACHE_ROOT": cacheRoot
      ]).execute(.init(workflowId: "fixture", stepId: "read", nodeId: "read",
        addon: .init(name: "riela/x-gateway-reader", version: "1", config: [
          "queryTemplate": .string("query { homeTimeline(maxResults: 5) { posts { id author { id username } } } }"),
          "userCache": .bool(true), "usageCache": .bool(true)
        ], env: ["X_GW_TOKEN": .object(["fromEnv": .string("SYNTHETIC_X_TOKEN")])]),
        variables: [:], resolvedInputPayload: [:]), context: .init(deadline: Date().addingTimeInterval(60)))
    }
    let call = try XCTUnwrap(stub.calls.first)
    XCTAssertEqual(stub.calls.count, 1)
    XCTAssertEqual(Array(call.arguments.prefix(5)), ["graphql", "query",
      "query { homeTimeline(maxResults: 5) { posts { id author { id username } } } }", "--json", "--retry"])
    XCTAssertEqual(call.arguments[5], "0")
    XCTAssertEqual(call.arguments[6], "--timeout-ms")
    XCTAssertLessThanOrEqual(try XCTUnwrap(Int(call.arguments[7])), XGatewayReaderSDK.maximumRequestTimeoutMilliseconds)
    XCTAssertEqual(call.environment["X_GW_TOKEN"], "token-canary")
    XCTAssertNil(call.environment["UNRELATED_PRIVATE"])
    XCTAssertNil(call.environment["SYNTHETIC_X_TOKEN"])
    XCTAssertEqual(call.environment["X_GW_USER_MEMORY_PARTS"], "1")
    XCTAssertTrue(try XCTUnwrap(call.environment["X_GW_USER_MEMORY_JSON_0"]).contains("user_7"))

    let encoded = try JSONValue.object(output.payload).compactJSONString()
    XCTAssertFalse(encoded.contains("userMemory"))
    XCTAssertFalse(encoded.contains("token-canary"))
    guard case let .object(data)? = output.payload["data"], data["homeTimeline"] != nil,
          case let .object(namespace)? = output.payload["xGateway"],
          case let .object(observations)? = namespace["observations"] else { return XCTFail("missing reader payload") }
    XCTAssertEqual(observations["userCacheStatus"], .string("ok"))
    XCTAssertEqual(observations["usageCacheStatus"], .string("stored"))
    guard case let .object(resourceUsage)? = observations["resourceUsage"],
          case let .array(resources)? = resourceUsage["resources"] else { return XCTFail("missing usage observation") }
    XCTAssertEqual(resources.count, 2)

    let usage = try XGatewayUsageCacheExchange(scope: nil, environment: ["RIELA_CACHE_ROOT": cacheRoot])
    let keys = try usage.store.keys(cacheId: XGatewayUsageCacheExchange.cacheId, scope: XGatewayUsageCacheExchange.scope)
    XCTAssertEqual(keys.count, 1)
    let row = try XCTUnwrap(usage.store.get(cacheId: XGatewayUsageCacheExchange.cacheId,
      scope: XGatewayUsageCacheExchange.scope, keys: keys).results.first?.entry?.payload)
    guard case let .object(entry) = jsonValue(from: row) else { return XCTFail("usage row is not an object") }
    XCTAssertEqual(entry["telemetryStatus"], .string("stored"))
    XCTAssertEqual(entry["scopeKind"], .string("credential"))

    let users = XGatewayUserCacheExchange(environment: ["RIELA_CACHE_ROOT": cacheRoot])
    XCTAssertEqual(Set(try users.store.keys(cacheId: XGatewayUserCacheExchange.cacheId,
      scope: XGatewayUserCacheExchange.scope)), ["7", "8"])
  }

  func testDeadlineReturnsWhileSDKBlocksAndCooperativePoolStaysFree() async throws {
    let release = DispatchSemaphore(value: 0)
    let entered = XGatewayCounter()
    let invocation: XGatewayReaderSDKInvocation = { _, _ in
      entered.increment()
      _ = release.wait(timeout: .now() + 20)
      return XGatewayReaderSDKResult(exitCode: 0, stdout: #"{"ok":true,"data":{"data":{}}}"#, stderr: "")
    }
    let parallel = max(8, ProcessInfo.processInfo.activeProcessorCount * 2)
    defer { for _ in 0..<parallel { release.signal() } }
    let started = Date()
    try await XGatewayReaderSDK.$invocationOverride.withValue(invocation) {
      try await withThrowingTaskGroup(of: TimeInterval.self) { group in
        for _ in 0..<parallel {
          group.addTask {
            let callStart = Date()
            do {
              _ = try await BuiltinWorkflowAddonResolver(environment: [:]).execute(.init(workflowId: "fixture",
                stepId: "read", nodeId: "read", addon: .init(name: "riela/x-gateway-reader",
                  config: ["queryTemplate": .string("query { accountMe { id } }")])),
                context: .init(deadline: Date().addingTimeInterval(1)))
              XCTFail("a blocked SDK call must time out")
            } catch {
              XCTAssertEqual((error as? AdapterExecutionError)?.code, .timeout)
            }
            return Date().timeIntervalSince(callStart)
          }
        }
        // Every blocked SDK call holds its own thread, so unrelated async work
        // still makes progress while all of them are in flight.
        while entered.value < parallel, Date().timeIntervalSince(started) < 5 {
          try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(entered.value, parallel)
        let progressStart = Date()
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertLessThan(Date().timeIntervalSince(progressStart), 0.9)
        for try await elapsed in group {
          XCTAssertLessThan(elapsed, 2.5, "the deadline error must not wait for the blocked SDK call")
        }
      }
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 4)
  }

  func testMediaRootDirIsRejectedBeforeSDKButLiteralTextIsNot() async throws {
    let stub = XGatewaySDKStub(stdout: #"{"ok":true,"data":{"data":{"searchPosts":{"posts":[]}}}}"#)
    for document in [
      #"query { searchPosts(query: "swift", mediaRootDir: "/tmp/escape") { posts { id } } }"#,
      #"query { searchPosts(query: "swift", downloadMedia: true, mediaRootDir: "media") { posts { id } } }"#
    ] {
      do {
        _ = try await XGatewayReaderSDK.$invocationOverride.withValue(stub.invocation) {
          try await execute(document)
        }
        XCTFail("mediaRootDir must be rejected")
      } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked) }
    }
    XCTAssertTrue(stub.calls.isEmpty)
    for document in [
      #"query { searchPosts(query: "mediaRootDir", downloadMedia: false) { posts { id } } }"#,
      "query { searchPosts(query: \"\"\"say \\\"\"\" mediaRootDir\"\"\") { posts { id } } # mediaRootDir\n}"
    ] {
      _ = try await XGatewayReaderSDK.$invocationOverride.withValue(stub.invocation) { try await execute(document) }
    }
    XCTAssertEqual(stub.calls.count, 2)
    XCTAssertThrowsError(try xGatewayRejectHostMediaArguments("query { posts(ids: [\"1\"], mediaRootDir: \"/\") { posts { id } } }"))
  }

  func testUnsupportedImageKeepsPaidDataAndSurfacesUserCacheStatus() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("x-embedded-unsupported-user-cache")
    defer { try? FileManager.default.removeItem(at: root) }
    let stub = XGatewaySDKStub(stdout: #"{"ok":true,"data":{"data":{"accountMe":{"id":"42"}}}}"#)
    let output = try await XGatewayReaderSDK.$invocationOverride.withValue(stub.invocation) {
      try await BuiltinWorkflowAddonResolver(environment: ["RIELA_CACHE_ROOT": root.path]).execute(.init(
        workflowId: "fixture", stepId: "read", nodeId: "read", addon: .init(name: "riela/x-gateway-reader",
          config: ["queryTemplate": .string("query { accountMe { id } }"), "userCache": .bool(true)])),
        context: .init())
    }
    XCTAssertEqual(output.payload["data"], .object(["accountMe": .object(["id": .string("42")])]))
    guard case let .object(namespace)? = output.payload["xGateway"],
          case let .object(observations)? = namespace["observations"] else { return XCTFail("missing observations") }
    XCTAssertEqual(observations["userCacheStatus"], .string("unsupported"))
  }

  func testReaderArgumentsBoundEachRequestByTheRemainingDeadline() {
    let now = Date()
    XCTAssertEqual(XGatewayReaderSDK.arguments(document: "q", deadline: nil, now: now),
      ["graphql", "query", "q", "--json", "--retry", "0", "--timeout-ms", "30000"])
    XCTAssertEqual(XGatewayReaderSDK.arguments(document: "q", deadline: now.addingTimeInterval(2.5), now: now).last, "2500")
    XCTAssertEqual(XGatewayReaderSDK.arguments(document: "q", deadline: now.addingTimeInterval(600), now: now).last, "30000")
    XCTAssertEqual(XGatewayReaderSDK.arguments(document: "q", deadline: now.addingTimeInterval(-1), now: now).last, "1")
  }

  private func execute(_ document: String) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(environment: [:]).execute(.init(workflowId: "fixture", stepId: "read",
      nodeId: "read", addon: .init(name: "riela/x-gateway-reader", config: ["queryTemplate": .string(document)])),
      context: .init())
  }
}

final class XGatewaySDKStub: @unchecked Sendable {
  struct Call {
    var arguments: [String]
    var environment: [String: String]
  }

  private let lock = NSLock()
  private var recorded: [Call] = []
  private let result: XGatewayReaderSDKResult

  init(stdout: String, stderr: String = "", exitCode: Int32 = 0) {
    result = XGatewayReaderSDKResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
  }

  var calls: [Call] { lock.withLock { recorded } }

  var invocation: XGatewayReaderSDKInvocation {
    { [self] arguments, environment in
      lock.withLock { recorded.append(Call(arguments: arguments, environment: environment)) }
      return result
    }
  }
}

final class XGatewayCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}
