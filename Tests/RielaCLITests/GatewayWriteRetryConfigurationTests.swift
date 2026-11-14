import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class GatewayWriteRetryConfigurationTests: XCTestCase {
  private func input(_ value: JSONValue?) -> WorkflowAddonExecutionInput {
    var config: JSONObject = [:]
    config["writeRetry"] = value
    return .init(workflowId: "workflow", stepId: "write", nodeId: "write",
      addon: .init(name: "riela/apple-gateway-graphql", config: config), resolvedInputPayload: [:])
  }

  func testExplicitPolicyForwardsBoundedValuesAndDefaultFields() throws {
    XCTAssertEqual(try gatewayWriteRetryEnvironment(input(nil), prefix: "APPLE_GATEWAY_"), [:])
    XCTAssertEqual(try gatewayWriteRetryEnvironment(input(.object([:])), prefix: "APPLE_GATEWAY_"), [
      "APPLE_GATEWAY_WRITE_RETRY_INITIAL_WAIT_SECONDS": "2", "APPLE_GATEWAY_WRITE_RETRY_MAX_RETRIES": "3"
    ])
    XCTAssertEqual(try gatewayWriteRetryEnvironment(input(.object([
      "initialWaitSeconds": .integer(60), "maxRetries": .integer(0)
    ])), prefix: "GMAIL_GATEWAY_"), [
      "GMAIL_GATEWAY_WRITE_RETRY_INITIAL_WAIT_SECONDS": "60", "GMAIL_GATEWAY_WRITE_RETRY_MAX_RETRIES": "0"
    ])
  }

  func testInvalidPolicyNeverReachesGateway() throws {
    for invalid in [JSONValue.bool(true), .object(["unknown": .integer(1)]),
      .object(["initialWaitSeconds": .integer(0)]), .object(["initialWaitSeconds": .integer(61)]),
      .object(["initialWaitSeconds": .number(1.5)]), .object(["maxRetries": .integer(-1)]),
      .object(["maxRetries": .integer(6)]), .object(["maxRetries": .string("3")])] {
      XCTAssertThrowsError(try gatewayWriteRetryEnvironment(input(invalid), prefix: "APPLE_GATEWAY_"))
    }
  }

  func testInvokerUsesExplicitPolicyAndRejectsExpiredDeadlineBeforeCallingRunner() throws {
    let policy = try gatewayWriteRetryEnvironment(input(.object(["maxRetries": .integer(1)])), prefix: "APPLE_GATEWAY_")
    let invoker = AppleGatewayInvoker(runtimeEnvironment: ["APPLE_GATEWAY_WRITE_RETRY_MAX_RETRIES": "5"],
      extraEnvironment: policy, runnerOverride: { _, environment, _ in
        XCTAssertEqual(environment["APPLE_GATEWAY_WRITE_RETRY_MAX_RETRIES"], "1")
        return .init(stdout: "{}", stderr: "", terminationStatus: 0)
      })
    _ = try invoker.run(arguments: [], deadline: nil)
    let expired = AppleGatewayInvoker(runtimeEnvironment: [:], extraEnvironment: policy, runnerOverride: { _, _, _ in
      XCTFail("expired operation dispatched")
      return .init(stdout: "{}", stderr: "", terminationStatus: 0)
    })
    XCTAssertThrowsError(try expired.run(arguments: [], deadline: Date(timeIntervalSinceNow: -1)))
  }
}
