import RielaCore
import XCTest
@testable import RielaCLI

final class DeferredContainerAddonTests: XCTestCase {
  func testGmailGatewayReadRemainsDeferred() async throws {
    try await assertDeferredResponse(for: "riela/gmail-gateway-read")
  }

  func testXGatewayReadRemainsDeferred() async throws {
    try await assertDeferredResponse(for: "riela/x-gateway-read")
  }

  private func assertDeferredResponse(for name: String) async throws {
    let gateway = RecordingGatewayGraphQLRunner(
      failure: AdapterExecutionError(.providerError, "deferred gateway runner was invoked")
    )
    let output = try await BuiltinWorkflowAddonResolver(
      environment: [:],
      localGatewayGraphQLRunner: gateway.runner
    ).execute(
      WorkflowAddonExecutionInput(
        workflowId: "deferred-gateway-test",
        stepId: "deferred-step",
        nodeId: "deferred-node",
        addon: WorkflowNodeAddonRef(name: name, version: "1", config: [:], inputs: [:]),
        variables: [:],
        resolvedInputPayload: [:]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.provider, "riela-builtin-addon")
    XCTAssertEqual(output.model, name)
    XCTAssertEqual(output.promptText, "")
    XCTAssertTrue(output.completionPassed)
    XCTAssertEqual(output.payload, [
      "status": .string("ok"),
      "addon": .string(name),
      "stepId": .string("deferred-step")
    ])
    XCTAssertTrue(gateway.allCalls().isEmpty, "deferred add-on must not call the gateway")
  }
}
