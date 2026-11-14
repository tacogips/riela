import Foundation
import GatewaySDKKit
import RielaAddonSupport
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

  func testWholeArgumentObjectKeepsTypesAndDoesNotRenderSourceAgain() throws {
    let arguments: JSONObject = ["input": .object(["first": .integer(5), "query": .string("{{secret}}")])]
    let request = try BuiltinGatewayJSONRequest.request(config: [
      "operation": .string("threads"), "arguments": .string("{{input.arguments}}")
    ], variables: ["input": .object(["arguments": .object(arguments)]), "secret": .string("must not expand")], addonName: "fixture")
    XCTAssertEqual(request.variables["input"], .object(["first": .int(5), "query": .string("{{secret}}")]))
    for invalid: JSONValue in [.array([]), .null, .string("{}"), .bool(false)] {
      XCTAssertThrowsError(try BuiltinGatewayJSONRequest.request(config: [
        "operation": .string("threads"), "arguments": .string("{{input.arguments}}")
      ], variables: ["input": .object(["arguments": invalid])], addonName: "fixture"))
    }
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

  /// `riela workflow validate` (production context) and the runtime request
  /// builder must agree on the request shape, including a missing `arguments`.
  func testValidationAndRuntimeAgreeOnRequestShapes() async throws {
    let descriptors = [
      ("riela/gmail-gateway-reader", BuiltinGmailGatewayCLIAddon.reader.descriptor),
      ("riela/wrike-gateway-read", BuiltinWrikeGatewayAddon.read.descriptor)
    ]
    let context = WorkflowValidationContext.production()
    for (name, descriptor) in descriptors {
      let catalog = try XCTUnwrap(descriptor.catalog)()
      let operation = try XCTUnwrap(catalog.operations.first {
        $0.kind == .query && $0.arguments.allSatisfy { !$0.isRequired }
      }).name
      let table: [(JSONObject, Bool)] = [
        (["operation": .string(operation)], true),
        (["operation": .string(operation), "arguments": .object([:])], true),
        (["operation": .string(operation), "arguments": .array([])], false),
        (["operation": .string(operation), "arguments": .null], false),
        (["operation": .string("{{workflowInput.operation}}")], false),
        (["operation": .string("noSuchOperation")], false),
        (["operation": .string(operation), "select": .object([:])], false),
        (["operation": .string(operation), "queryTemplate": .string("{ x }")], false),
        (["operation": .string(operation), "selection": .array([])], false),
        (["operation": .string(operation), "selection": .array([.string("a..b")])], false),
        (["operation": .string(operation), "selection": .string("id")], false)
      ]
      // A whole reference is valid authored wiring; a missing runtime object
      // must still fail before transport. Keep those two checks independent.
      let cases = table.map { ($0.0, $0.1, $0.1) } + [
        (["operation": JSONValue.string(operation), "arguments": .string("{{workflowInput.arguments}}")], true, false)
      ]
      for (config, validationExpected, runtimeExpected) in cases {
        let validationAccepts = validationErrors(name, config: config, context: context).isEmpty
        let gateway = RecordingGatewayGraphQLRunner(response: #"{"data":{}}"#)
        var runtimeAccepts = false
        do {
          _ = try await BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: gateway.runner)
            .execute(input(name, config: config), context: .init())
          runtimeAccepts = gateway.allCalls().count == 1
        } catch {
          XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked, "\(name) \(config)")
          XCTAssertTrue(gateway.allCalls().isEmpty)
        }
        XCTAssertEqual(validationAccepts, validationExpected, "validation \(name) \(config)")
        XCTAssertEqual(runtimeAccepts, runtimeExpected, "runtime \(name) \(config)")
      }
    }
  }

  /// The X SDL codec renders arguments and field-path selections through the
  /// shared request contract and reports the same `policyBlocked` code.
  func testXCodecUsesSharedArgumentsSelectionAndErrorCode() throws {
    func document(_ config: JSONObject) throws -> String? {
      try builtinGatewayXJSONDocument(input("riela/x-gateway-reader", config: config))
    }
    let base: JSONObject = ["operation": .string("homeTimeline"), "selection": .array([.string("posts.id")])]
    XCTAssertEqual(try document(base), "query { homeTimeline { posts { id } } }")
    XCTAssertEqual(try document(base.merging(["arguments": .object(["maxResults": .number(25.0), "ratio": .number(0.5)])]) { _, rhs in rhs }),
                   "query { homeTimeline(maxResults: 25, ratio: 0.5) { posts { id } } }")
    let oversized = JSONValue.string(String(repeating: "a", count: GatewayJSONLimits.maximumEncodedBytes))
    let invalid: [JSONObject] = [
      base.merging(["arguments": .array([])]) { _, rhs in rhs },
      base.merging(["arguments": .string("maxResults: 25")]) { _, rhs in rhs },
      base.merging(["arguments": .object(["query": oversized])]) { _, rhs in rhs },
      base.merging(["arguments": .object(["maxResults": .number(.infinity)])]) { _, rhs in rhs },
      base.merging(["selection": .array([])]) { _, rhs in rhs },
      base.merging(["selection": .array([.string("posts..id")])]) { _, rhs in rhs },
      base.merging(["selection": .array([.string("posts.{{x}}")])]) { _, rhs in rhs },
      ["operation": .string("homeTimeline")],
      ["operation": .string("homeTimeline { id }"), "selection": .array([.string("id")])]
    ]
    for config in invalid {
      XCTAssertThrowsError(try document(config), "\(config)") { error in
        XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked, "\(config)")
      }
    }
    XCTAssertNil(try document(["queryTemplate": .string("query { accountMe { id } }")]))
  }

  private func validationErrors(
    _ name: String, config: JSONObject, context: WorkflowValidationContext
  ) -> [WorkflowValidationDiagnostic] {
    let addon = WorkflowNodeAddonRef(name: name, config: config)
    let workflow = WorkflowDefinition(
      workflowId: "gateway-request-parity",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", addon: addon)],
      steps: [WorkflowStepRef(id: "step", nodeId: "node")],
      nodes: [WorkflowNodeRef(id: "step", addon: addon)]
    )
    return DefaultWorkflowValidator(context: context).validate(workflow).filter { $0.severity == .error }
  }

  private func input(_ name: String, config: JSONObject) -> WorkflowAddonExecutionInput {
    .init(workflowId: "json-request-test", stepId: "read", nodeId: "read",
          addon: .init(name: name, version: "1", config: config), variables: [:], resolvedInputPayload: [:])
  }
}
