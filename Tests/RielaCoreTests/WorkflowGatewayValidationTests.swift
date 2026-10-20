import XCTest
@testable import RielaCore

final class WorkflowGatewayValidationTests: XCTestCase {
  private func errors(
    _ name: String,
    config: JSONObject,
    inputs: JSONObject? = nil,
    env: JSONObject? = nil,
    context: WorkflowValidationContext = .init()
  ) -> [WorkflowValidationDiagnostic] {
    let addon = WorkflowNodeAddonRef(name: name, config: config, env: env, inputs: inputs)
    let workflow = WorkflowDefinition(
      workflowId: "gateway-validation",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1000, maxLoopIterations: 1),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", addon: addon)],
      steps: [WorkflowStepRef(id: "step", nodeId: "node")],
      nodes: [WorkflowNodeRef(id: "step", addon: addon)]
    )
    return DefaultWorkflowValidator(context: context).validate(workflow).filter { $0.severity == .error }
  }

  func testGraphQLModesAndTypedArguments() {
    let addon = "riela/wrike-gateway-read"
    XCTAssertTrue(errors(addon, config: ["queryTemplate": .string("{ tasks { id } }")]).isEmpty)
    XCTAssertTrue(errors(addon, config: ["operation": .string("tasks"), "arguments": .object([
      "flag": .bool(true), "count": .integer(3), "nested": .array([.null, .object(["x": .string("y")])])
    ])]).isEmpty)
    for invalid: JSONObject in [
      [:],
      ["queryTemplate": .null],
      ["operation": .null, "arguments": .object([:])],
      ["operation": .string("tasks")],
      ["operation": .string("{{input.operation}}"), "arguments": .object([:])],
      ["operation": .string("tasks"), "arguments": .array([])],
      ["queryTemplate": .string("query"), "operation": .string("tasks"), "arguments": .object([:])],
      ["queryTemplate": .string("query"), "selection": .array([])],
      ["queryTemplate": .string("query"), "variablesTemplate": .null]
    ] {
      XCTAssertFalse(errors(addon, config: invalid).isEmpty, "\(invalid)")
    }
  }

  func testSelectionAndDocumentModes() {
    let graphql = "riela/gmail-gateway-draft"
    let base: JSONObject = ["operation": .string("draft"), "arguments": .object([:])]
    XCTAssertTrue(errors(graphql, config: base.merging(["selection": .string(" { id }")]) { _, rhs in rhs }).isEmpty)
    XCTAssertTrue(errors(graphql, config: base.merging(["selection": .array([.string("draft.id")])]) { _, rhs in rhs }).isEmpty)
    for selection: JSONValue in [.null, .string("id"), .array([]), .array([.string("draft..id")]), .array([.integer(1)])] {
      XCTAssertFalse(errors(graphql, config: base.merging(["selection": selection]) { _, rhs in rhs }).isEmpty)
    }
    let docs = "riela/google-docs-gateway-read"
    XCTAssertTrue(errors(docs, config: ["command": .string("documents get")]).isEmpty)
    XCTAssertTrue(errors(docs, config: ["command": .string("documents get"), "argsTemplate": .object(["id": .string("123")])]).isEmpty)
    XCTAssertFalse(errors(docs, config: ["command": .string("documents get"), "argsTemplate": .array([])]).isEmpty)
    XCTAssertTrue(errors(docs, config: base).isEmpty)
    XCTAssertFalse(errors(docs, config: base.merging(["selection": .array([])]) { _, rhs in rhs }).isEmpty)
  }

  func testCatalogChecksAndDefaultInitializer() {
    let addon = "riela/wrike-gateway-read"
    let config: JSONObject = ["operation": .string("taskz"), "arguments": .object([:])]
    XCTAssertTrue(errors(addon, config: config).isEmpty)
    let context = WorkflowValidationContext { provider, tier in
      WorkflowGatewayCatalogProjection(provider: provider, tier: tier,
                                       operationNames: ["tasks", "task", "users", "taskList"])
    }
    let diagnostics = errors(addon, config: config, context: context)
    XCTAssertEqual(diagnostics.count, 1)
    XCTAssertTrue(diagnostics[0].message.contains("taskz"))
    XCTAssertTrue(diagnostics[0].message.contains("task"))
  }

  func testSchemaVocabularyAndOptions() {
    for provider in WorkflowGatewayProvider.allCases {
      for tier in provider.tiers {
        XCTAssertTrue(errors("riela/gateway-schema", config: ["gateway": .string(provider.rawValue),
          "tier": .string(tier), "kinds": .array([.string("inputObject"), .string("scalar")]),
          "includeReferencedTypes": .bool(true), "limit": .integer(2), "pattern": .string("draft")]).isEmpty)
      }
    }
    let base: JSONObject = ["gateway": .string("gmail-gateway"), "tier": .string("draft")]
    for invalid: JSONObject in [
      ["gateway": .string("unknown"), "tier": .string("draft")],
      ["gateway": .string("gmail-gateway"), "tier": .string("writer")],
      base.merging(["kinds": .array([.string("unknown")])]) { _, rhs in rhs },
      base.merging(["includeReferencedTypes": .string("true")]) { _, rhs in rhs },
      base.merging(["limit": .integer(0)]) { _, rhs in rhs },
      base.merging(["pattern": .null]) { _, rhs in rhs }
    ] {
      XCTAssertFalse(errors("riela/gateway-schema", config: invalid).isEmpty)
    }
  }

  func testAppleEffectiveInputsAndPolicy() {
    let apple = "riela/apple-gateway-graphql"
    XCTAssertTrue(errors(apple, config: ["query": .string("old")], inputs: ["query": .string("{{input.query}}")]).isEmpty)
    XCTAssertTrue(errors(apple, config: ["query": .null], inputs: ["query": .string("{{input.query}}")]).isEmpty)
    XCTAssertTrue(errors(apple, config: [:], inputs: ["queryFile": .string("{{input.file}}")]).isEmpty)
    XCTAssertTrue(errors(apple, config: ["queryFile": .string("query.graphql"), "query": .null,
                                       "variablesFile": .string("vars.json"), "variables": .null]).isEmpty)
    XCTAssertTrue(errors(apple, config: ["query": .string("{ viewer { id } }"),
                                       "variables": .object(["limit": .integer(3)])]).isEmpty)
    XCTAssertTrue(errors(apple, config: ["query": .string("{ viewer { id } }")],
                              inputs: ["variables": .object(["enabled": .bool(true)])]).isEmpty)
    XCTAssertFalse(errors(apple, config: ["query": .string("q"), "variables": .integer(3)]).isEmpty)
    XCTAssertTrue(errors(apple, config: ["operation": .string("read"), "arguments": .object([:])]).isEmpty)
    XCTAssertFalse(errors(apple, config: ["operation": .string("read"), "arguments": .object([:]),
                                      "variablesFile": .string("vars.json")]).isEmpty)
    XCTAssertFalse(errors(apple, config: ["query": .string("q"), "binaryPath": .string("/bin/true")]).isEmpty)
    XCTAssertFalse(errors(apple, config: ["query": .string("q")], env: ["TOKEN": .string("x")]).isEmpty)
    XCTAssertFalse(errors("riela/apple-gateway-schema", config: ["limit": .integer(0)]).isEmpty)
  }
}
