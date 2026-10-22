import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class XGatewaySDKAddonTests: XCTestCase {
  func testEmbeddedReaderUsesOnlyBoundCredentialsAndReturnsGraphQLData() async throws {
    let gateway = RecordingGatewayGraphQLRunner(response: #"{"data":{"accountMe":{"id":"42"}}}"#)
    let output = try await BuiltinWorkflowAddonResolver(environment: [
      "SYNTHETIC_X_TOKEN": "token-canary", "UNRELATED_PRIVATE": "must-not-forward"
    ], localGatewayGraphQLRunner: gateway.runner).execute(.init(workflowId: "fixture", stepId: "read", nodeId: "read",
      addon: .init(name: "riela/x-gateway-reader", version: "1",
        config: ["queryTemplate": .string("query { accountMe { {{field}} } }")],
        env: ["X_GW_TOKEN": .object(["fromEnv": .string("SYNTHETIC_X_TOKEN")])]),
      variables: ["field": .string("id")], resolvedInputPayload: [:]), context: .init())
    let call = try XCTUnwrap(gateway.lastCall())
    XCTAssertEqual(call.tier, "x-gateway-reader")
    XCTAssertEqual(call.document, "query { accountMe { id } }")
    XCTAssertNil(call.variablesJSON)
    XCTAssertEqual(call.environment["X_GW_TOKEN"], "token-canary")
    XCTAssertNil(call.environment["UNRELATED_PRIVATE"])
    XCTAssertEqual(output.payload["data"], .object(["accountMe": .object(["id": .string("42")])]))
    XCTAssertFalse(output.promptText.contains("token-canary"))
  }

  func testReaderRefusesMutationAndExpiredDeadlineBeforeCallingProvider() throws {
    XCTAssertThrowsError(try xGatewayReaderQuery(document: "mutation { deletePost(id: \"1\") { id } }",
      environment: [:], deadline: nil)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
    XCTAssertThrowsError(try xGatewayReaderQuery(document: "query { accountMe { id } }",
      environment: [:], deadline: Date().addingTimeInterval(-1))) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .timeout)
    }
  }

  func testReaderRefusesEnvironmentInjectionBeforeSDKInvocation() async throws {
    let gateway = RecordingGatewayGraphQLRunner()
    do {
      _ = try await BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: gateway.runner)
        .execute(.init(workflowId: "fixture", stepId: "read", nodeId: "read",
          addon: .init(name: "riela/x-gateway-reader", version: "1",
            config: ["queryTemplate": .string("query { accountMe { id } }")],
            env: ["PATH": .string("/untrusted")]), variables: [:], resolvedInputPayload: [:]), context: .init())
      XCTFail("environment injection must fail")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked) }
    XCTAssertNil(gateway.lastCall())
  }
}
