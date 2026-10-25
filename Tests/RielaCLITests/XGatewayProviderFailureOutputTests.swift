import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

final class XGatewayProviderFailureOutputTests: XCTestCase {
  func testClassificationUsesClosedFirstMatchTable() {
    let rows: [(JSONObject, XGatewayFailureCategory)] = [
      (["providerProblem": .string("spend-cap-reached"), "httpStatus": .integer(403)], .spendCapReached),
      (["code": .string("RATE_LIMITED")], .rateLimited),
      (["code": .string("AUTH_EXPIRED")], .auth),
      (["code": .string("PERMISSION_DENIED")], .permission),
      (["code": .string("VALIDATION_ERROR")], .invalidRequest),
      (["code": .string("RESOURCE_NOT_FOUND")], .notFound),
      (["code": .string("UPSTREAM_FAILURE"), "httpStatus": .integer(503)], .transient),
      (["code": .string("INTERNAL_ERROR")], .unknown),
      (["code": .string("UPSTREAM_FAILURE"), "httpStatus": .integer(429)], .rateLimited),
      (["code": .string("UPSTREAM_FAILURE"), "httpStatus": .integer(400)], .invalidRequest),
      (["code": .string("NETWORK_FAILURE")], .transient)
    ]
    for (diagnostics, expected) in rows {
      XCTAssertEqual(XGatewayFailureCategory.classify(diagnostics), expected)
      XCTAssertEqual(expected.retryable, expected == .rateLimited || expected == .transient)
    }
  }

  func testEmbeddedOutputAndFailModesPreservePinnedProviderFailure() async throws {
    let failure = #"{"ok":false,"error":{"code":"PERMISSION_DENIED","httpStatus":403,"providerProblem":"spend-cap-reached"}}"#
    let stub = XGatewayReaderSDKResult(exitCode: 1, stdout: failure, stderr: "")
    let invocation: XGatewayReaderSDKInvocation = { _, _ in stub }
    let input = { (mode: String?) in
      WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "read", nodeId: "read",
        addon: .init(name: "riela/x-gateway-reader", config: [
          "queryTemplate": .string("query { accountMe { id } }")
        ].merging(mode.map { ["providerFailure": .string($0)] } ?? [:]) { _, new in new }))
    }
    let expectedMessage = "X reader SDK query failed (code=PERMISSION_DENIED, httpStatus=403, providerProblem=spend-cap-reached)"
    for mode in [nil, "fail"] {
      do {
        _ = try await XGatewayReaderSDK.$invocationOverride.withValue(invocation) {
          try await BuiltinWorkflowAddonResolver(environment: [:]).execute(input(mode), context: .init())
        }
        XCTFail("fail mode must throw")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .providerError)
        XCTAssertEqual(error.message, expectedMessage)
      }
    }
    let output = try await XGatewayReaderSDK.$invocationOverride.withValue(invocation) {
      try await BuiltinWorkflowAddonResolver(environment: [:]).execute(input("output"), context: .init())
    }
    XCTAssertEqual(output.payload["status"], .string("provider-failed"))
    XCTAssertEqual(output.when, ["providerFailed": true, "providerRetryable": false, "spendCapReached": true, "rateLimited": false])
    guard case let .object(namespace)? = output.payload["xGateway"],
          case let .object(failure)? = namespace["failure"] else { return XCTFail("failure metadata missing") }
    XCTAssertEqual(failure["category"], .string("spend-cap-reached"))
    XCTAssertEqual(failure["retryable"], .bool(false))
    XCTAssertEqual(failure["diagnostics"], .object([
      "code": .string("PERMISSION_DENIED"), "httpStatus": .integer(403),
      "providerProblem": .string("spend-cap-reached")
    ]))
  }

  func testRetryModeIsRejectedBeforeSDKInvocation() async {
    let calls = XGatewayFailureCallCounter()
    let invocation: XGatewayReaderSDKInvocation = { _, _ in
      calls.increment()
      return XGatewayReaderSDKResult(exitCode: 0, stdout: #"{"ok":true,"data":{"data":{"accountMe":{"id":"1"}}}}"#, stderr: "")
    }
    do {
      _ = try await XGatewayReaderSDK.$invocationOverride.withValue(invocation) {
        try await BuiltinWorkflowAddonResolver(environment: [:]).execute(.init(workflowId: "fixture", stepId: "read",
          nodeId: "read", addon: .init(name: "riela/x-gateway-reader", config: [
            "queryTemplate": .string("query { accountMe { id } }"), "providerFailure": .string("retry")
          ])), context: .init())
      }
      XCTFail("unsupported retry mode must fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
    } catch { XCTFail("unexpected error: \(error)") }
    XCTAssertEqual(calls.count, 0)
  }

  func testOutputModeSuccessFlagsAndExpiredDeadlineRemainNormal() async throws {
    let success: XGatewayReaderSDKInvocation = { _, _ in
      XGatewayReaderSDKResult(exitCode: 0, stdout: #"{"ok":true,"data":{"data":{"accountMe":{"id":"1"}}}}"#, stderr: "")
    }
    let successInput = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/x-gateway-reader", config: [
        "queryTemplate": .string("query { accountMe { id } }"), "providerFailure": .string("output"),
        "postprocess": .array([.object(["pick": .string("/data/accountMe")])])
      ]))
    let output = try await XGatewayReaderSDK.$invocationOverride.withValue(success) {
      try await BuiltinWorkflowAddonResolver(environment: [:]).execute(successInput, context: .init())
    }
    XCTAssertEqual(output.when["providerFailed"], false)
    XCTAssertEqual(output.when["providerRetryable"], false)
    XCTAssertEqual(output.when["spendCapReached"], false)
    XCTAssertEqual(output.when["rateLimited"], false)
    let shaped = try BuiltinPostprocessPlan(successInput).apply(to: output)
    XCTAssertEqual(shaped.when["postprocessPassed"], true)

    let calls = XGatewayFailureCallCounter()
    let invocation: XGatewayReaderSDKInvocation = { _, _ in
      calls.increment()
      return XGatewayReaderSDKResult(exitCode: 1, stdout: "", stderr: "")
    }
    do {
      _ = try await XGatewayReaderSDK.$invocationOverride.withValue(invocation) {
        try await BuiltinWorkflowAddonResolver(environment: [:]).execute(.init(workflowId: "fixture", stepId: "read",
          nodeId: "read", addon: .init(name: "riela/x-gateway-reader", config: [
            "queryTemplate": .string("query { accountMe { id } }"), "providerFailure": .string("output")
          ])), context: .init(deadline: Date().addingTimeInterval(-1)))
      }
      XCTFail("expired deadline must not become a provider output")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
    } catch { XCTFail("unexpected error: \(error)") }
    XCTAssertEqual(calls.count, 0)
  }

  func testOutputModePreservesPolicyInvalidOutputAndCancellationErrors() async throws {
    let policyInput = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/x-gateway-reader", config: [
        "queryTemplate": .string("mutation { deletePost(id: \"1\") { id } }"),
        "providerFailure": .string("output")
      ]))
    do {
      _ = try await BuiltinWorkflowAddonResolver(environment: [:]).execute(policyInput, context: .init())
      XCTFail("policy failure must not become a provider output")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
    }

    let invalidOutput: XGatewayReaderSDKInvocation = { _, _ in
      XGatewayReaderSDKResult(exitCode: 0, stdout: #"{"ok":true,"data":{}}"#, stderr: "")
    }
    let validInput = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/x-gateway-reader", config: [
        "queryTemplate": .string("query { accountMe { id } }"), "providerFailure": .string("output")
      ]))
    do {
      _ = try await XGatewayReaderSDK.$invocationOverride.withValue(invalidOutput) {
        try await BuiltinWorkflowAddonResolver(environment: [:]).execute(validInput, context: .init())
      }
      XCTFail("invalid output must not become a provider output")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidOutput)
    }

    let cancelledRunner: LocalGatewayGraphQLRunner = { _, _, _, _ in throw CancellationError() }
    do {
      _ = try await BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: cancelledRunner)
        .execute(validInput, context: .init())
      XCTFail("cancellation must remain thrown")
    } catch is CancellationError {
      // Expected: cancellation is not a provider diagnostic.
    }
  }

  func testContainerFailureOutputAndUndiagnosedFailure() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("x-container-failure-output")
    defer { try? FileManager.default.removeItem(at: root) }
    let input = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/x-gateway-read", config: [
        "queryTemplate": .string("query { posts { id } }"), "providerFailure": .string("output")
      ]))
    let stderr = #"{"ok":false,"error":{"code":"RATE_LIMITED","httpStatus":429}}"#
    let runner = XGatewayFailureContainerRunner(result: .init(stdout: "", stderr: stderr, terminationStatus: 4))
    let executor = ContainerGatewayAddonExecutor(environment: ["RIELA_CONTAINER_RUNTIME": "docker"],
      workingDirectory: root, runner: runner)
    let output = try await executor.execute(input, gateway: .xRead, context: .init())
    XCTAssertEqual(output.when["providerRetryable"], true)
    XCTAssertEqual(output.when["rateLimited"], true)
    XCTAssertEqual(output.payload["status"], .string("provider-failed"))
    guard case let .object(namespace)? = output.payload["xGateway"],
          case let .object(failure)? = namespace["failure"] else { return XCTFail("container failure metadata missing") }
    XCTAssertEqual(failure["category"], .string("rate-limited"))
    XCTAssertEqual(failure["retryable"], .bool(true))
    let callCount = await runner.callCount
    XCTAssertEqual(callCount, 1)

    let undiagnosed = XGatewayFailureContainerRunner(result: .init(stdout: "", stderr: "", terminationStatus: 125))
    do {
      _ = try await ContainerGatewayAddonExecutor(environment: ["RIELA_CONTAINER_RUNTIME": "docker"],
        workingDirectory: root, runner: undiagnosed).execute(input, gateway: .xRead, context: .init())
      XCTFail("undiagnosed container failure must throw")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
    }
  }

  func testPostprocessSkipsProviderFailureOutput() throws {
    let input = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/x-gateway-reader", config: [
        "postprocess": .array([.object(["pick": .string("/xGateway/data")])])
      ]))
    let plan = try BuiltinPostprocessPlan(input)
    let original = AdapterExecutionOutput(provider: "x-gateway", model: input.addon.name, promptText: "",
      completionPassed: true, when: ["providerFailed": true], payload: ["status": .string("provider-failed")])
    let output = plan.apply(to: original)
    XCTAssertEqual(output.payload["postprocess"], .object(["status": .string("skipped")]))
    XCTAssertNil(output.payload["processed"])
    XCTAssertEqual(output.when["postprocessPassed"], false)
    XCTAssertEqual(output.when["postprocessFailed"], false)
  }
}

private final class XGatewayFailureCallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = 0
  func increment() { lock.withLock { stored += 1 } }
  var count: Int { lock.withLock { stored } }
}

private actor XGatewayFailureContainerRunner: LocalProcessRunning {
  let result: LocalProcessResult
  private(set) var callCount = 0
  init(result: LocalProcessResult) { self.result = result }
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    callCount += 1
    return result
  }
}
