import Foundation
import GatewaySDKKit
#if canImport(AppleGatewayCore)
import AppleGatewayCore
#endif
#if canImport(GoogleDocumentsGatewayCore)
import GoogleDocumentsGatewayCore
#endif
import RielaCore
import XCTest
@testable import RielaCLI

final class CatalogWorkflowGatewayValidationTests: XCTestCase {
  func testCatalogLiteralAndTemplatedArgumentChecksMatchRuntimeBuilder() throws {
    var descriptors: [(String, LocalGatewayGraphQLDescriptor)] = [
      ("riela/wrike-gateway-read", BuiltinWrikeGatewayAddon.read.descriptor),
      ("riela/gmail-gateway-reader", BuiltinGmailGatewayCLIAddon.reader.descriptor)
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
      let base: JSONObject = ["operation": .string(operation.name), "arguments": .object([:])]
      XCTAssertTrue(runtimeAccepts(base, catalog: catalog, addonName: name), name)
      XCTAssertTrue(validationErrors(name, config: base).isEmpty, name)

      let unknown: JSONObject = ["operation": .string(operation.name), "arguments": .object(["unexpected": .string("x")])]
      XCTAssertFalse(runtimeAccepts(unknown, catalog: catalog, addonName: name), name)
      XCTAssertTrue(validationErrors(name, config: unknown).contains {
        $0.path.hasSuffix(".addon.config") && $0.message.contains("does not match its gateway tier catalog")
      }, name)

      let templatedUnknown: JSONObject = [
        "operation": .string(operation.name),
        "arguments": .object(["{{workflowInput.key}}": .string("value")])
      ]
      XCTAssertFalse(validationErrors(name, config: templatedUnknown).isEmpty, name)
      XCTAssertFalse(runtimeAccepts(templatedUnknown, catalog: catalog, addonName: name), name)

      if let argument = operation.arguments.first,
         let sample = sampleValue(for: argument.type, catalog: catalog) {
        let templated: JSONObject = [
          "operation": .string(operation.name),
          "arguments": .object([argument.name: .string("{{workflowInput.value}}")])
        ]
        XCTAssertTrue(validationErrors(name, config: templated).isEmpty, name)
        let values: JSONObject = ["workflowInput": .object(["value": sample])]
        XCTAssertTrue(runtimeAccepts(templated, variables: values, catalog: catalog, addonName: name), name)
      }

      let exactPlaceholder: JSONObject = [
        "operation": .string(operation.name), "arguments": .string("{{workflowInput.arguments}}")
      ]
      XCTAssertTrue(validationErrors(name, config: exactPlaceholder).isEmpty, name)
    }
  }

  #if canImport(GoogleDocumentsGatewayCore)
  func testDocumentsLiteralAndTemplatedArgumentChecksMatchRuntime() throws {
    let name = "riela/google-docs-gateway-read"
    let role = GatewayRole(service: .docs, accessMode: .read)
    let catalog = GoogleDocumentsGatewaySDK(role: role).catalog
    let forbidden = Set(["auth login", "auth revoke"])
    let operation = try XCTUnwrap(catalog.operations.first { candidate in
      !forbidden.contains(candidate.name) && candidate.arguments.allSatisfy { argument in
        !argument.isRequired || sampleValue(for: argument.type, catalog: catalog) != nil
      }
    })
    var arguments: JSONObject = [:]
    for argument in operation.arguments where argument.isRequired {
      if let value = sampleValue(for: argument.type, catalog: catalog) {
        arguments[argument.name] = value
      }
    }
    let base: JSONObject = ["operation": .string(operation.name), "arguments": .object(arguments)]

    XCTAssertTrue(validationErrors(name, config: base).isEmpty, "\(name): \(operation.name)")
    XCTAssertNoThrow(
      try GoogleDocumentsGatewayAddonEngine.operationArgv(
        config: base, variables: [:], addonName: name, role: role
      ),
      "\(name): \(operation.name)"
    )

    let unknown: JSONObject = [
      "operation": .string(operation.name), "arguments": .object(["unexpected": .string("x")])
    ]
    XCTAssertTrue(validationErrors(name, config: unknown).contains {
      $0.path.hasSuffix(".addon.config") && $0.message.contains("does not match its gateway tier catalog")
    }, "\(name): \(operation.name)")
    XCTAssertThrowsError(
      try GoogleDocumentsGatewayAddonEngine.operationArgv(
        config: unknown, variables: [:], addonName: name, role: role
      ),
      "\(name): \(operation.name)"
    )

    let templatedUnknown: JSONObject = [
      "operation": .string(operation.name),
      "arguments": .object(["unexpected": .string("{{workflowInput.v}}")])
    ]
    XCTAssertTrue(validationErrors(name, config: templatedUnknown).contains {
      $0.path == "workflow.nodes[0].addon.config.arguments.unexpected"
        && $0.message.contains("is not an argument of operation")
    }, "\(name): \(operation.name)")

    let exactPlaceholder: JSONObject = [
      "operation": .string(operation.name), "arguments": .string("{{workflowInput.arguments}}")
    ]
    XCTAssertTrue(validationErrors(name, config: exactPlaceholder).isEmpty, "\(name): \(operation.name)")
  }
  #endif

  #if canImport(AppleGatewayCore)
  func testAppleFullLiteralChecksMatchRuntimeAndInputsAreSilent() throws {
    let name = "riela/apple-gateway-graphql"
    let catalog = AppleGatewaySDK(role: .full).catalog
    let operation = try XCTUnwrap(catalog.operations.first {
      $0.kind == .query && $0.arguments.allSatisfy { !$0.isRequired }
    })
    let base: JSONObject = ["operation": .string(operation.name), "arguments": .object([:])]

    XCTAssertTrue(validationErrors(name, config: base).isEmpty, "\(name): \(operation.name)")
    XCTAssertTrue(runtimeAcceptsRendered(base, catalog: catalog, addonName: name), "\(name): \(operation.name)")

    let unknown: JSONObject = [
      "operation": .string(operation.name), "arguments": .object(["unexpected": .string("x")])
    ]
    XCTAssertTrue(validationErrors(name, config: unknown).contains {
      $0.path.hasSuffix(".addon.config") && $0.message.contains("does not match its gateway tier catalog")
    }, "\(name): \(operation.name)")
    XCTAssertFalse(runtimeAcceptsRendered(unknown, catalog: catalog, addonName: name), "\(name): \(operation.name)")

    let addon = WorkflowNodeAddonRef(name: name, config: base, inputs: ["document": .string("provided")])
    XCTAssertEqual(BuiltinGatewayRequestChecks.issues(addon), [], "\(name): \(operation.name)")
  }
  #endif

  func testLeafAndCatalogArgumentIssueOrdering() throws {
    let addon = WorkflowNodeAddonRef(name: "fixture", config: [
      "postprocess": .array([]), "operation": .string("lookup")
    ])
    XCTAssertNil(BuiltinGatewayRequestChecks.leafConfig(addon)["postprocess"])
    let catalog = GatewaySchemaCatalog(provider: "fixture", tier: "reader", operations: [
      GatewayOperation(name: "lookup", kind: .query, tier: "reader", arguments: [
        GatewayArgument(name: "required", type: .nonNull(.named("String")), isRequired: true),
        GatewayArgument(name: "optional", type: .named("String"))
      ])
    ])
    let issues = BuiltinGatewayRequestChecks.catalogArgumentNameIssues(
      ["zeta": .string("x"), "alpha": .string("x")], operation: "lookup", catalog: catalog
    )
    XCTAssertEqual(issues.map(\.relativePath), ["arguments.alpha", "arguments.zeta", "arguments"])
    XCTAssertEqual(BuiltinGatewayRequestChecks.catalogArgumentNameIssues([:], operation: "missing", catalog: catalog), [])
  }

  private func runtimeAccepts(
    _ config: JSONObject,
    variables: JSONObject = [:],
    catalog: GatewaySchemaCatalog,
    addonName: String
  ) -> Bool {
    (try? BuiltinGatewayJSONRequest.document(
      config: config, variables: variables, catalog: catalog, addonName: addonName
    )) != nil
  }

  private func runtimeAcceptsRendered(
    _ config: JSONObject,
    catalog: GatewaySchemaCatalog,
    addonName: String
  ) -> Bool {
    (try? BuiltinGatewayJSONRequest.document(
      config: config,
      variables: [:],
      catalog: catalog,
      addonName: addonName,
      argumentsAlreadyRendered: true
    )) != nil
  }

  private func sampleValue(for type: GatewayTypeRef, catalog: GatewaySchemaCatalog) -> JSONValue? {
    switch type {
    case let .nonNull(inner):
      return sampleValue(for: inner, catalog: catalog)
    case .list:
      return JSONValue.array([])
    case let .named(name):
      switch name {
      case "String", "ID": return JSONValue.string("resolved")
      case "Boolean": return JSONValue.bool(true)
      case "Int": return JSONValue.integer(1)
      case "Float": return JSONValue.number(1)
      default:
        guard let definition = catalog.namedType(name) else { return nil }
        if case let .enumeration(values) = definition.kind, let value = values.first {
          return JSONValue.string(value)
        }
        if case let .inputObject(fields) = definition.kind {
          var values: JSONObject = [:]
          for field in fields where field.isRequired {
            guard let value = sampleValue(for: field.type, catalog: catalog) else { return nil }
            values[field.name] = value
          }
          return JSONValue.object(values)
        }
        return nil
      }
    }
  }

  private func validationErrors(
    _ name: String,
    config: JSONObject,
    inputs: JSONObject? = nil
  ) -> [WorkflowValidationDiagnostic] {
    let addon = WorkflowNodeAddonRef(name: name, config: config, inputs: inputs)
    let workflow = WorkflowDefinition(
      workflowId: "catalog-request-parity",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1000, maxLoopIterations: 1),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", addon: addon)],
      steps: [WorkflowStepRef(id: "step", nodeId: "node")],
      nodes: [WorkflowNodeRef(id: "step", addon: addon)]
    )
    return DefaultWorkflowValidator(context: .production()).validate(workflow).filter { $0.severity == .error }
  }
}
