import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class XGatewayUsageTweetsTests: XCTestCase {
  private var input: WorkflowAddonExecutionInput {
    .init(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/x-gateway-reader", version: "1", config: [
        "operation": .string("apiUsage"),
        "arguments": .object(["days": .integer(1)]),
        "select": .object(["projectUsage": .bool(true)]),
        "postprocess": .array([.object(["pick": .string("/data/apiUsage")])])
      ]))
  }

  func testUsageOperationRunsThroughEmbeddedReader() async throws {
    XCTAssertTrue(try XCTUnwrap(XGatewayOperationCatalog.queryOperationNames).contains("apiUsage"))
    let stub = XGatewaySDKStub(stdout: #"{"ok":true,"data":{"data":{"apiUsage":{"projectUsage":5}}}}"#)
    let output = try await XGatewayReaderSDK.$invocationOverride.withValue(stub.invocation) {
      try await BuiltinWorkflowAddonResolver(environment: [:]).execute(input, context: .init())
    }
    let call = try XCTUnwrap(stub.calls.first)
    XCTAssertEqual(stub.calls.count, 1)
    XCTAssertTrue(call.arguments[2].contains("apiUsage(days: 1)"))
    XCTAssertTrue(call.arguments[2].contains("projectUsage"))
    XCTAssertEqual(output.payload["processed"], .object(["projectUsage": .integer(5)]))
  }

  func testOversizedUsageOutputIsRejected() async throws {
    let padding = String(repeating: "x", count: XGatewayUsageCacheExchange.maximumEnvelopeBytes)
    let stub = XGatewaySDKStub(stdout: #"{"ok":true,"data":{"data":{"apiUsage":{"projectUsage":"# + padding + #""}}}}"#)
    do {
      _ = try await XGatewayReaderSDK.$invocationOverride.withValue(stub.invocation) {
        try await BuiltinWorkflowAddonResolver(environment: [:]).execute(input, context: .init())
      }
      XCTFail("oversized SDK output must be rejected")
    } catch {
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .providerError)
    }
    XCTAssertEqual(stub.calls.count, 1)
  }
}
