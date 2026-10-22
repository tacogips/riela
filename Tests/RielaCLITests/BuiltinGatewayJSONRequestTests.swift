import Foundation
import GatewaySDKKit
import RielaCore
import XCTest
@testable import RielaCLI

final class BuiltinGatewayJSONRequestTests: XCTestCase {
  func testCatalogRequestsReachEachPinnedGatewayWithoutQueryTemplates() async throws {
    var descriptors = [
      ("riela/gmail-gateway-reader", BuiltinGmailGatewayCLIAddon.reader.descriptor),
      ("riela/wrike-gateway-read", BuiltinWrikeGatewayAddon.read.descriptor)
    ]
    #if os(macOS)
    descriptors += [
      ("riela/google-analytics-gateway-read", BuiltinGoogleAnalyticsGatewayAddon.read.descriptor),
      ("riela/notion-gateway-read", BuiltinNotionGatewayAddon.read.descriptor)
    ]
    #endif
    for (name, descriptor) in descriptors {
      let catalog = try XCTUnwrap(descriptor.catalog)()
      let operation = try XCTUnwrap(catalog.operations.first {
        $0.kind == .query && $0.arguments.allSatisfy { !$0.isRequired }
      })
      let gateway = RecordingGatewayGraphQLRunner(response: #"{"data":{}}"#)
      _ = try await BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: gateway.runner)
        .execute(input(name, config: ["operation": .string(operation.name), "arguments": .object([:])]), context: .init())
      let call = try XCTUnwrap(gateway.lastCall())
      XCTAssertEqual(call.tier, descriptor.tier)
      XCTAssertEqual(gateway.allCalls().count, 1)
      XCTAssertTrue(call.document.contains(operation.name))
      XCTAssertEqual(call.variablesJSON, "{}")
    }
  }

  func testArgumentTemplatesRenderOnceIntoTypedVariables() throws {
    let source = "\" } mutation { destroyAll } # {{secret}}"
    let request = try BuiltinGatewayJSONRequest.request(config: [
      "operation": .string("threads"),
      "arguments": .object(["input": .object(["accountId": .string("{{workflowInput.account}}"), "first": .integer(5)])])
    ], variables: ["workflowInput": .object(["account": .string(source)])], addonName: "fixture")
    XCTAssertEqual(request.variables["input"], .object(["accountId": .string(source), "first": .int(5)]))
    let catalog = try XCTUnwrap(BuiltinGmailGatewayCLIAddon.reader.descriptor.catalog)()
    let built = try GatewayDocumentBuilder(catalog: catalog).build(request)
    XCTAssertFalse(built.document.contains(source))
    XCTAssertEqual(built.variables["input"], request.variables["input"])
  }

  func testInvalidInputsAndEscapingSelectionsNeverCallProvider() async throws {
    let configs: [JSONObject] = [
      ["operation": .string("accounts"), "queryTemplate": .string("{ accounts { id } }")],
      ["operation": .string("{{workflowInput.operation}}")],
      ["operation": .string("sendMessage"), "arguments": .object([:])],
      ["operation": .string("accounts"), "selection": .string("{ id } anotherRoot { id }")],
      ["operation": .string("accounts"), "selection": .string("{ id } } mutation Injected { sendMessage { id }")],
      ["operation": .string("accounts"), "selection": .string("{ id } } fragment Injected on MailAccount { id")],
      ["operation": .string("accounts"), "selection": .array([.string("id } injected")])],
      ["operation": .string("accounts"), "arguments": .object(["unknown": .string("private")])]
    ]
    for config in configs {
      let gateway = RecordingGatewayGraphQLRunner()
      do {
        _ = try await BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: gateway.runner)
          .execute(input("riela/gmail-gateway-reader", config: config), context: .init())
        XCTFail("invalid request reached the gateway")
      } catch {
        XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      }
      XCTAssertTrue(gateway.allCalls().isEmpty)
    }
  }

  private func input(_ name: String, config: JSONObject) -> WorkflowAddonExecutionInput {
    .init(workflowId: "json-request-test", stepId: "read", nodeId: "read",
          addon: .init(name: name, version: "1", config: config), variables: [:], resolvedInputPayload: [:])
  }
}
